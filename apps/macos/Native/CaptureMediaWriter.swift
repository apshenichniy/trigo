import CryptoKit
import Foundation
import TrigoContracts

public enum CaptureError: Error, Equatable, Sendable {
  case invalidAudio
  case closed
  case durationLimit
  case corruptCheckpoint
  case existingRecording
}

public struct CapturedMediaObject: Codable, Equatable, Sendable {
  public let objectID: String
  public let index: Int
  public let byteLength: Int
  public let sha256: String
  public let startMs: Int
  public let endMs: Int
  public var filename: String { objectID + ".wav" }
}

public struct CapturedMedia: Codable, Equatable, Sendable {
  public var objects: [CapturedMediaObject]
  public var durationMs: Int
  public var microphoneIntervals: [CaptureInterval] = []
  public var applicationIntervals: [CaptureInterval] = []
}

public enum CaptureWritePoint { case afterPCMSync, afterObjectSync }

public struct CaptureRecovery: Sendable {
  public let media: CapturedMedia
  public let wasInterrupted: Bool
  public let rejectedTail: Bool
  public let interruptionReason: String?
}

private struct MediaCheckpoint: Codable {
  struct Fragment: Codable {
    let byteLength: Int
    let sha256: String
  }
  var version = 1
  var objects: [CapturedMediaObject] = []
  var activeID = UUID().uuidString.lowercased()
  var fragments: [Fragment] = []
  var finished = false
  var interruptionReason: String?
  var microphoneIntervals: [CaptureInterval] = []
  var applicationIntervals: [CaptureInterval] = []
}

/// Synchronous, single-owner writer. The capture queue owns all calls to this type.
public final class CaptureMediaWriter {
  private let directory: URL
  let profile: MediaProfile
  private var checkpoint = MediaCheckpoint()
  private var handle: FileHandle?
  private var closed = false
  private let interruption: (CaptureWritePoint) throws -> Void
  private let atomic = AtomicFileWriter(interruption: { _ in })

  public init(directory: URL, interruption: @escaping (CaptureWritePoint) throws -> Void = { _ in })
    throws
  {
    self.directory = directory
    self.interruption = interruption
    profile = try .selected()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    guard !FileManager.default.fileExists(atPath: checkpointURL.path) else {
      throw CaptureError.existingRecording
    }
    try save()
  }

  deinit { try? handle?.close() }

  private var checkpointURL: URL { directory.appendingPathComponent("media-checkpoint.json") }
  private var activeURL: URL { directory.appendingPathComponent(checkpoint.activeID + ".pcm") }
  private var activeBytes: Int { checkpoint.fragments.reduce(0) { $0 + $1.byteLength } }
  public var durationMs: Int {
    (checkpoint.objects.last?.endMs ?? 0) + activeBytes / profile.captureBytesPerMs
  }

  public func append(
    interleaved: [Int16], microphoneIntervals: [CaptureInterval]? = nil,
    applicationIntervals: [CaptureInterval]? = nil
  ) throws {
    guard !closed else { throw CaptureError.closed }
    // Integer-millisecond boundaries are also the canonical manifest boundaries.
    guard !interleaved.isEmpty, interleaved.count % profile.captureSamplesPerMs == 0 else {
      throw CaptureError.invalidAudio
    }
    guard interleaved.count / profile.captureSamplesPerMs <= profile.maxCallDurationMs - durationMs
    else {
      throw CaptureError.durationLimit
    }
    do {
      var offset = 0
      while offset < interleaved.count {
        // One-second syncs leave headroom for capture callback delivery and scheduling.
        let count = min(
          profile.captureSamplesPerSecond, interleaved.count - offset,
          (profile.captureObjectPCMBytes - activeBytes) / (profile.bitsPerSample / 8))
        let bytes = interleaved.withUnsafeBufferPointer {
          Data(
            buffer: UnsafeBufferPointer(start: $0.baseAddress!.advanced(by: offset), count: count))
        }
        if handle == nil {
          guard
            FileManager.default.createFile(
              atPath: activeURL.path, contents: nil,
              attributes: [.posixPermissions: 0o600])
          else {
            throw LocalPersistenceError.io("Could not create capture media")
          }
          handle = try FileHandle(forWritingTo: activeURL)
        }
        try handle?.write(contentsOf: bytes)
        try handle?.synchronize()
        try interruption(.afterPCMSync)
        let start = durationMs
        let end = start + count / profile.captureSamplesPerMs
        let mic = microphoneIntervals ?? [.init(startMs: start, endMs: end, state: .recorded)]
        let app = applicationIntervals ?? [.init(startMs: start, endMs: end, state: .recorded)]
        for span in clippedCaptureIntervals(mic, startMs: start, endMs: end) {
          mergeCaptureInterval(span, into: &checkpoint.microphoneIntervals)
        }
        for span in clippedCaptureIntervals(app, startMs: start, endMs: end) {
          mergeCaptureInterval(span, into: &checkpoint.applicationIntervals)
        }
        checkpoint.fragments.append(.init(byteLength: bytes.count, sha256: captureHash(bytes)))
        try save()
        if activeBytes == profile.captureObjectPCMBytes { try seal() }
        offset += count
      }
    } catch {
      closed = true
      try? handle?.close()
      handle = nil
      throw error
    }
  }

  public func finish(interruptionReason: String? = nil) throws -> CapturedMedia {
    try requireCaptureInterruptionReason(interruptionReason)
    guard !closed else { throw CaptureError.closed }
    closed = true
    try seal()
    checkpoint.finished = true
    checkpoint.interruptionReason = interruptionReason
    try save()
    return CapturedMedia(
      objects: checkpoint.objects, durationMs: durationMs,
      microphoneIntervals: checkpoint.microphoneIntervals,
      applicationIntervals: checkpoint.applicationIntervals)
  }

  private func save() throws {
    try atomic.write(try JSONEncoder().encode(checkpoint), to: checkpointURL, domain: .archive)
  }

  private func seal() throws {
    guard activeBytes > 0 else { return }
    try handle?.close()
    handle = nil
    let oldPCM = activeURL
    let pcm = try Data(contentsOf: oldPCM).prefix(activeBytes)
    let wave = waveHeader(pcmBytes: pcm.count, profile: profile) + pcm
    let object = CapturedMediaObject(
      objectID: checkpoint.activeID, index: checkpoint.objects.count,
      byteLength: wave.count, sha256: captureHash(wave),
      startMs: checkpoint.objects.last?.endMs ?? 0, endMs: durationMs)
    try atomic.write(wave, to: directory.appendingPathComponent(object.filename), domain: .archive)
    try interruption(.afterObjectSync)
    checkpoint.objects.append(object)
    checkpoint.activeID = UUID().uuidString.lowercased()
    checkpoint.fragments = []
    try save()
    // The checkpoint now references the independently decodable object, not this spool.
    try atomic.remove(oldPCM)
  }

  /// Reconstructs only a validated contiguous prefix. This API never opens a stream or resumes a writer.
  public static func recover(directory: URL) throws -> CaptureRecovery {
    let profile = try MediaProfile.selected()
    let checkpointURL = directory.appendingPathComponent("media-checkpoint.json")
    let stored = try JSONDecoder().decode(
      MediaCheckpoint.self, from: Data(contentsOf: checkpointURL))
    guard stored.version == 1, isCanonicalIdentifier(stored.activeID),
      stored.objects.count <= profile.maxObjectsPerCall,
      stored.fragments.count <= profile.objectDurationMs
    else { throw CaptureError.corruptCheckpoint }
    var objects: [CapturedMediaObject] = []
    var rejected = false
    for object in stored.objects {
      guard isCanonicalIdentifier(object.objectID), object.index == objects.count,
        object.startMs == (objects.last?.endMs ?? 0), object.endMs > object.startMs,
        object.endMs - object.startMs <= profile.objectDurationMs,
        object.endMs <= profile.maxCallDurationMs,
        object.byteLength == profile.waveHeaderBytes + (object.endMs - object.startMs)
          * profile.captureBytesPerMs,
        let bytes = try? Data(contentsOf: directory.appendingPathComponent(object.filename)),
        bytes.count == object.byteLength, captureHash(bytes) == object.sha256,
        bytes.prefix(profile.waveHeaderBytes)
          == waveHeader(pcmBytes: bytes.count - profile.waveHeaderBytes, profile: profile)
      else {
        rejected = true
        break
      }
      objects.append(object)
    }
    var pcm = Data()
    if !rejected && !stored.fragments.isEmpty {
      let file = try? FileHandle(
        forReadingFrom: directory.appendingPathComponent(stored.activeID + ".pcm"))
      defer { try? file?.close() }
      for fragment in stored.fragments {
        guard fragment.byteLength > 0, fragment.byteLength <= profile.captureBytesPerMs * 1000,
          fragment.byteLength % profile.captureBytesPerMs == 0,
          pcm.count + fragment.byteLength <= profile.captureObjectPCMBytes,
          let bytes = try file?.read(upToCount: fragment.byteLength),
          bytes.count == fragment.byteLength, captureHash(bytes) == fragment.sha256
        else {
          rejected = true
          break
        }
        pcm.append(bytes)
      }
      if !pcm.isEmpty {
        // A new identity avoids overwriting an orphan object from an interrupted seal.
        let id = UUID().uuidString.lowercased()
        let wave = waveHeader(pcmBytes: pcm.count, profile: profile) + pcm
        let start = objects.last?.endMs ?? 0
        guard start + pcm.count / profile.captureBytesPerMs <= profile.maxCallDurationMs else {
          throw CaptureError.corruptCheckpoint
        }
        let object = CapturedMediaObject(
          objectID: id, index: objects.count, byteLength: wave.count,
          sha256: captureHash(wave), startMs: start,
          endMs: start + pcm.count / profile.captureBytesPerMs)
        try AtomicFileWriter(interruption: { _ in }).write(
          wave, to: directory.appendingPathComponent(object.filename), domain: .archive)
        objects.append(object)
      }
    }
    let duration = objects.last?.endMs ?? 0
    return CaptureRecovery(
      media: CapturedMedia(
        objects: objects, durationMs: duration,
        microphoneIntervals: clippedCaptureIntervals(
          stored.microphoneIntervals, startMs: 0, endMs: duration),
        applicationIntervals: clippedCaptureIntervals(
          stored.applicationIntervals, startMs: 0, endMs: duration)),
      wasInterrupted: !stored.finished || rejected || stored.interruptionReason != nil,
      rejectedTail: rejected,
      interruptionReason: rejected
        ? "corrupt_media_tail"
        : stored.interruptionReason ?? (stored.finished ? nil : "process_terminated"))
  }
}

func captureHash(_ bytes: Data) -> String {
  SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

func waveHeader(pcmBytes: Int, profile: MediaProfile) -> Data {
  var header = Data("RIFF".utf8)
  header.appendLittleEndian(UInt32(36 + pcmBytes))
  header.append(Data("WAVEfmt ".utf8))
  header.appendLittleEndian(UInt32(16))
  header.appendLittleEndian(UInt16(1))
  header.appendLittleEndian(UInt16(profile.channels.count))
  header.appendLittleEndian(UInt32(profile.sampleRateHz))
  header.appendLittleEndian(UInt32(profile.captureBytesPerMs * 1000))
  header.appendLittleEndian(UInt16(profile.captureBytesPerFrame))
  header.appendLittleEndian(UInt16(profile.bitsPerSample))
  header.append(Data("data".utf8))
  header.appendLittleEndian(UInt32(pcmBytes))
  return header
}

extension Data {
  mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var little = value.littleEndian
    Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
  }
}
