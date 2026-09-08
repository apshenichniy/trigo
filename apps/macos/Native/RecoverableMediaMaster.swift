import CryptoKit
import Foundation

/// Single-owner synchronous proof boundary. The caller serializes capture/policy and repository work.
/// Each append supplies at most one second of already timeline-aligned PCM and complete source states.
/// This boundary additionally zeros all non-recorded contributions before any write or digest.
public final class RecoverableMediaMaster {
  public let directory: URL
  public let identity: MediaMasterIdentity
  public private(set) var cursor: MediaMasterCursor
  public private(set) var finalized: FinalizedMediaMaster?
  public private(set) var discardedTailBytes: Int64 = 0
  public var mediaURL: URL { directory.appendingPathComponent("master.caf") }
  private let media: FileHandle
  private let index: FileHandle
  private let io: MediaMasterIO
  private var chain: Data
  private var digest = SHA256()
  private var failed = false

  public convenience init(directory: URL, identity: MediaMasterIdentity) throws {
    try self.init(directory: directory, identity: identity, io: MediaMasterIO())
  }

  init(directory: URL, identity: MediaMasterIdentity, io: MediaMasterIO) throws {
    self.directory = directory
    self.identity = identity
    self.io = io
    let header = MediaMasterIndex.header(identity)
    chain = header.suffix(32)
    cursor = .init(
      identity: identity,
      frames: 0,
      stableBytes: 68,
      commitCount: 0,
      integritySHA256: chain.masterHex
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    media = try MediaMasterIO.create(directory.appendingPathComponent("master.caf"))
    index = try MediaMasterIO.create(directory.appendingPathComponent("master.index"))
    try io.writeAll(MediaMasterProfile.header, to: media)
    try media.synchronize()
    try io.writeAll(header, to: index)
    try index.synchronize()
    try MediaMasterIO.syncDirectory(directory)
    digest.update(data: MediaMasterProfile.header)
  }

  /// Validates every recorded PCM hash with a bounded scan. A repository witness prevents accepting
  /// an index shortened below already-published progress. Reopen preserves allocated identities.
  public convenience init(
    reopening directory: URL,
    expectedIdentity: MediaMasterIdentity,
    confirmed: MediaMasterCursor? = nil
  ) throws {
    try self.init(
      reopening: directory,
      expectedIdentity: expectedIdentity,
      confirmed: confirmed,
      io: MediaMasterIO()
    )
  }

  init(
    reopening directory: URL,
    expectedIdentity: MediaMasterIdentity,
    confirmed: MediaMasterCursor? = nil,
    io: MediaMasterIO
  ) throws {
    self.directory = directory
    self.io = io
    media = try FileHandle(forUpdating: directory.appendingPathComponent("master.caf"))
    index = try FileHandle(forUpdating: directory.appendingPathComponent("master.index"))
    let header = try index.readMasterBytes(upToCount: 128) ?? Data()
    identity = try MediaMasterIndex.identity(header)
    guard identity == expectedIdentity else { throw MediaMasterError.identityMismatch }
    chain = header.suffix(32)
    cursor = .init(
      identity: identity,
      frames: 0,
      stableBytes: 68,
      commitCount: 0,
      integritySHA256: chain.masterHex
    )
    guard try media.readMasterBytes(upToCount: 68) == MediaMasterProfile.header else {
      throw MediaMasterError.invalidHeader
    }
    digest.update(data: MediaMasterProfile.header)
    var witnessFound = confirmed == nil || confirmed == cursor
    while let record = try index.readMasterBytes(upToCount: MediaMasterProfile.indexRecordBytes),
      !record.isEmpty
    {
      if record.count < MediaMasterProfile.indexRecordBytes { break }
      let sequence = cursor.commitCount + 1
      if record.prefix(2088).masterSHA256 != record.suffix(32) {
        // A complete-sized torn write is still an uncommitted tail when an independently
        // verified repository witness precedes it. Never guess this for old/nonterminal
        // corruption, an unknown witness, or more than one append's unindexed PCM.
        let terminal = try (index.readMasterBytes(upToCount: 1) ?? Data()).isEmpty
        let tailBytes = Int64(try media.seekToEnd()) - cursor.stableBytes
        if let confirmed, witnessFound, sequence > confirmed.commitCount,
          finalized == nil, terminal, (0...64_000).contains(tailBytes)
        {
          break
        }
        throw MediaMasterError.corruptIndex(record: sequence)
      }
      guard finalized == nil, record.subdata(in: 56..<88) == chain
      else { throw MediaMasterError.corruptIndex(record: sequence) }
      let frames = record.integer(at: 8, as: Int64.self)
      let bytes = record.integer(at: 16, as: Int64.self)
      let hash = record.subdata(in: 24..<56)
      if record.prefix(8) == Data("FINAL001".utf8) {
        guard frames == cursor.frames, bytes == cursor.stableBytes,
          hash == Data(digest.finalize()),
          record.subdata(in: 88..<2088) == Data(repeating: 0, count: 2000)
        else { throw MediaMasterError.corruptIndex(record: sequence) }
        finalized = .init(cursor: cursor, sha256: hash.masterHex)
        continue
      }
      guard record.prefix(8) == Data("AUDIO001".utf8), frames > cursor.frames,
        frames <= MediaMasterProfile.maximumFrames, frames - cursor.frames <= 16000,
        frames % 16 == 0, bytes == 68 + frames * 4
      else { throw MediaMasterError.corruptIndex(record: sequence) }
      do {
        _ = try MediaMasterIndex.intervals(
          record,
          channel: 0,
          startMs: Int(cursor.frames / 16),
          countMs: Int((frames - cursor.frames) / 16)
        )
        _ = try MediaMasterIndex.intervals(
          record,
          channel: 1,
          startMs: Int(cursor.frames / 16),
          countMs: Int((frames - cursor.frames) / 16)
        )
      } catch { throw MediaMasterError.corruptIndex(record: sequence) }
      let pcm = try media.readMasterBytes(upToCount: Int(bytes - cursor.stableBytes)) ?? Data()
      guard pcm.count == bytes - cursor.stableBytes, pcm.masterSHA256 == hash else {
        throw MediaMasterError.committedAudioCorruption(record: sequence)
      }
      digest.update(data: pcm)
      chain = record.suffix(32)
      cursor = .init(
        identity: identity,
        frames: frames,
        stableBytes: bytes,
        commitCount: sequence,
        integritySHA256: chain.masterHex
      )
      if cursor == confirmed { witnessFound = true }
    }
    guard witnessFound else { throw MediaMasterError.confirmedCursorMissing }
    let length = try media.seekToEnd()
    discardedTailBytes = Int64(length) - cursor.stableBytes
    try media.truncate(atOffset: UInt64(cursor.stableBytes))
    try media.synchronize()
    let indexBytes =
      128 + (cursor.commitCount + (finalized == nil ? 0 : 1))
      * Int64(MediaMasterProfile.indexRecordBytes)
    try index.truncate(atOffset: UInt64(indexBytes))
    try index.synchronize()
    try media.seek(toOffset: UInt64(cursor.stableBytes))
    try index.seekToEnd()
  }

  @discardableResult
  public func append(
    interleaved: [Int16],
    microphoneIntervals: [CaptureInterval],
    applicationIntervals: [CaptureInterval]
  ) throws -> MediaMasterCommit {
    guard !failed, finalized == nil else { throw MediaMasterError.closed }
    let frames = interleaved.count / 2
    guard !interleaved.isEmpty, interleaved.count % 32 == 0, frames <= 16000,
      cursor.frames + Int64(frames) <= MediaMasterProfile.maximumFrames
    else { throw MediaMasterError.invalidInput }
    let milliseconds = frames / 16
    let startMs = Int(cursor.frames / 16)
    let mic = try MediaMasterIndex.states(
      microphoneIntervals,
      startMs: startMs,
      countMs: milliseconds,
      microphone: true
    )
    let app = try MediaMasterIndex.states(
      applicationIntervals,
      startMs: startMs,
      countMs: milliseconds,
      microphone: false
    )
    var samples = interleaved
    var states = Data()
    for ms in 0..<milliseconds {
      states.append(mic[ms])
      states.append(app[ms])
      for frame in (ms * 16)..<((ms + 1) * 16) {
        if mic[ms] != 1 { samples[frame * 2] = 0 }
        if app[ms] != 1 { samples[frame * 2 + 1] = 0 }
      }
    }
    let pcm = samples.withUnsafeBytes { Data($0) }
    let hash = pcm.masterSHA256
    let endFrame = cursor.frames + Int64(frames)
    let endByte = cursor.stableBytes + Int64(pcm.count)
    let record = MediaMasterIndex.record(
      final: false,
      frames: endFrame,
      bytes: endByte,
      hash: hash,
      previous: chain,
      states: states
    )
    do {
      try io.writeAll(pcm, to: media)
      try io.event(.beforeMediaSync)
      try media.synchronize()
      try io.event(.afterMediaSync)
      try io.writeAll(record, to: index)
      try io.event(.beforeIndexSync)
      try index.synchronize()
      try io.event(.afterIndexSync)
    } catch {
      failed = true
      throw error
    }
    let startFrame = cursor.frames
    digest.update(data: pcm)
    chain = record.suffix(32)
    cursor = .init(
      identity: identity,
      frames: endFrame,
      stableBytes: endByte,
      commitCount: cursor.commitCount + 1,
      integritySHA256: chain.masterHex
    )
    return .init(
      cursor: cursor,
      startFrame: startFrame,
      pcmSHA256: hash.masterHex,
      microphoneIntervals: microphoneIntervals,
      applicationIntervals: applicationIntervals
    )
  }

  /// The final whole-master digest is independent of the integrity chain and multipart ETags.
  /// Repeating this operation or reopening never rewrites the immutable CAF header or identity.
  public func finish() throws -> FinalizedMediaMaster {
    guard !failed else { throw MediaMasterError.closed }
    if let finalized { return finalized }
    let hash = Data(digest.finalize())
    let record = MediaMasterIndex.record(
      final: true,
      frames: cursor.frames,
      bytes: cursor.stableBytes,
      hash: hash,
      previous: chain
    )
    do {
      try io.writeAll(record, to: index)
      try io.event(.beforeFinalizationSync)
      try index.synchronize()
      try io.event(.afterFinalizationSync)
    } catch {
      failed = true
      throw error
    }
    let result = FinalizedMediaMaster(cursor: cursor, sha256: hash.masterHex)
    finalized = result
    return result
  }

  /// Only the verified durable prefix is readable, including the forever-immutable header.
  /// Requests remain bounded independently of checkpoints and ASR intervals.
  public func readStableBytes(in range: Range<Int64>) throws -> Data {
    try Self.readStableBytes(directory: directory, confirmed: cursor, in: range)
  }

  /// Read-only transport access uses an issued repository cursor, never reopening/truncating the writer.
  public static func readStableBytes(
    directory: URL,
    confirmed cursor: MediaMasterCursor,
    in range: Range<Int64>
  ) throws -> Data {
    guard range.lowerBound >= 0, range.upperBound <= cursor.stableBytes,
      range.count > 0, range.count <= MediaMasterProfile.maximumRequestBytes
    else { throw MediaMasterError.invalidInput }
    return try autoreleasepool {
      try requireSafePath(directory, directory: true)
      let mediaURL = directory.appendingPathComponent("master.caf")
      let indexURL = directory.appendingPathComponent("master.index")
      try requireSafePath(mediaURL, directory: false)
      try requireSafePath(indexURL, directory: false)
      let index = try FileHandle(forReadingFrom: indexURL)
      defer { try? index.close() }
      guard
        try MediaMasterIndex.identity(index.readMasterBytes(upToCount: 128) ?? Data())
          == cursor.identity
      else {
        throw MediaMasterError.identityMismatch
      }
      let reader = try FileHandle(forReadingFrom: mediaURL)
      defer { try? reader.close() }
      guard try reader.readMasterBytes(upToCount: 68) == MediaMasterProfile.header else {
        throw MediaMasterError.invalidHeader
      }
      try reader.seek(toOffset: UInt64(range.lowerBound))
      let data = try reader.readMasterBytes(upToCount: range.count) ?? Data()
      guard data.count == range.count else {
        throw MediaMasterError.committedAudioCorruption(record: 0)
      }
      return data
    }
  }

  /// Streams only intersecting records. The consumer must persist/process each callback rather than
  /// collect a whole call. Interval times stay call-relative; channels remain source roles.
  public func forEachCommit(
    intersecting frames: Range<Int64>,
    _ consume: (MediaMasterCommit) throws -> Void
  ) throws {
    guard frames.lowerBound >= 0, frames.upperBound <= cursor.frames else {
      throw MediaMasterError.invalidInput
    }
    let reader = try FileHandle(forReadingFrom: directory.appendingPathComponent("master.index"))
    defer { try? reader.close() }
    try reader.seek(toOffset: 128)
    var start: Int64 = 0
    for sequence in 1..<(cursor.commitCount + 1) {
      let record =
        try reader.readMasterBytes(upToCount: MediaMasterProfile.indexRecordBytes) ?? Data()
      guard record.count == MediaMasterProfile.indexRecordBytes,
        record.prefix(2088).masterSHA256 == record.suffix(32)
      else {
        throw MediaMasterError.corruptIndex(record: sequence)
      }
      let end = record.integer(at: 8, as: Int64.self)
      if end > frames.lowerBound && start < frames.upperBound {
        let countMs = Int((end - start) / 16)
        try consume(
          .init(
            cursor: .init(
              identity: identity,
              frames: end,
              stableBytes: record.integer(at: 16, as: Int64.self),
              commitCount: sequence,
              integritySHA256: record.suffix(32).masterHex
            ),
            startFrame: start,
            pcmSHA256: record.subdata(in: 24..<56).masterHex,
            microphoneIntervals: MediaMasterIndex.intervals(
              record,
              channel: 0,
              startMs: Int(start / 16),
              countMs: countMs
            ),
            applicationIntervals: MediaMasterIndex.intervals(
              record,
              channel: 1,
              startMs: Int(start / 16),
              countMs: countMs
            )
          )
        )
      }
      start = end
      if start >= frames.upperBound { break }
    }
  }

  /// Post-call frame-exact extraction with constant 64 KiB PCM working memory. Output metadata is
  /// delivered incrementally to the caller; no growing whole-call JSON document is constructed.
  public func extract(
    frames: Range<Int64>,
    to destination: URL,
    intervals: (MediaMasterSourceIntervals) throws -> Void = { _ in }
  ) throws -> MediaMasterExtraction {
    guard let final = finalized, frames.lowerBound >= 0, frames.upperBound <= cursor.frames,
      !frames.isEmpty, frames.lowerBound % 16 == 0, frames.upperBound % 16 == 0,
      destination.standardizedFileURL != mediaURL.standardizedFileURL
    else { throw MediaMasterError.invalidInput }
    let output = try MediaMasterIO.create(destination)
    defer { try? output.close() }
    var hash = SHA256()
    try io.writeAll(MediaMasterProfile.header, to: output)
    hash.update(data: MediaMasterProfile.header)
    var offset = 68 + frames.lowerBound * 4
    let end = 68 + frames.upperBound * 4
    let input = try FileHandle(forReadingFrom: mediaURL)
    defer { try? input.close() }
    try input.seek(toOffset: UInt64(offset))
    while offset < end {
      let next = min(end, offset + 64000)
      let bytes = try input.readMasterBytes(upToCount: Int(next - offset)) ?? Data()
      guard bytes.count == next - offset else {
        throw MediaMasterError.committedAudioCorruption(record: 0)
      }
      try io.writeAll(bytes, to: output)
      hash.update(data: bytes)
      offset = next
    }
    try output.synchronize()
    try forEachCommit(intersecting: frames) { commit in
      try intervals(
        .init(
          startFrame: max(frames.lowerBound, commit.startFrame),
          endFrame: min(frames.upperBound, commit.cursor.frames),
          microphoneIntervals: clippedCaptureIntervals(
            commit.microphoneIntervals,
            startMs: Int(frames.lowerBound / 16),
            endMs: Int(frames.upperBound / 16)
          ),
          applicationIntervals: clippedCaptureIntervals(
            commit.applicationIntervals,
            startMs: Int(frames.lowerBound / 16),
            endMs: Int(frames.upperBound / 16)
          )
        )
      )
    }
    return .init(
      master: final,
      startFrame: frames.lowerBound,
      endFrame: frames.upperBound,
      sha256: Data(hash.finalize()).masterHex,
      byteLength: 68 + Int64(frames.count) * 4
    )
  }
}
