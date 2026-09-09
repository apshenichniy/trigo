import CryptoKit
import Foundation
import TrigoContracts

/// One-time exchange staging file, never recovery authority. A crash can leave only
/// unreachable temporary bytes; canonical publication always points to complete SQLite chunks.
final class CaptureSnapshotStream {
  let directory: URL
  let url: URL
  private let handle: FileHandle
  private var buffer = Data()
  private var digest = SHA256()
  private(set) var byteCount = 0
  private let encoder: JSONEncoder

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "trigo-snapshot-\(UUID())"
    )
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    url = directory.appendingPathComponent("snapshot.json")
    handle = try MediaMasterIO.create(url)
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  }

  deinit {
    try? handle.close()
    try? FileManager.default.removeItem(at: directory)
  }

  func append(_ bytes: Data) throws {
    var offset = 0
    while offset < bytes.count {
      let end = min(bytes.count, offset + 256 * 1024 - buffer.count)
      buffer.append(bytes.subdata(in: offset..<end))
      offset = end
      if buffer.count == 256 * 1024 { try flush() }
    }
  }
  func token(_ text: String) throws { try append(Data(text.utf8)) }
  func value<Value: Encodable>(_ value: Value) throws { try append(encoder.encode(value)) }
  private func flush() throws {
    guard !buffer.isEmpty else { return }
    try handle.write(contentsOf: buffer)
    digest.update(data: buffer)
    byteCount += buffer.count
    buffer.removeAll(keepingCapacity: true)
  }
  func finish() throws -> String {
    try flush()
    try handle.synchronize()
    return Data(digest.finalize()).masterHex
  }

  /// Generated values own scalar encoding. Field ordering mirrors Contract.encode's sorted
  /// keys; conformance tests compare exact bytes, including required nulls and Unicode.
  func encode(
    _ call: CallDocument,
    intervals: (Int, (TrackInterval) throws -> Void) throws -> Void
  )
    throws
  {
    try token("{\"activeRevisionId\":")
    try value(call.activeRevisionId)
    try token(",\"archiveId\":")
    try value(call.archiveId)
    try token(",\"audioManifest\":")
    try value(call.audioManifest)
    try token(",\"callId\":")
    try value(call.callId)
    try token(",\"captureState\":")
    try value(call.captureState)
    try token(",\"documentVersion\":")
    try value(call.documentVersion)
    try token(",\"durationMs\":")
    try value(call.durationMs)
    try token(",\"endedAt\":")
    try value(call.endedAt)
    try token(",\"interruptionReason\":")
    try value(call.interruptionReason)
    try token(",\"revisions\":")
    try value(call.revisions)
    try token(",\"schemaVersion\":")
    try value(call.schemaVersion)
    try token(",\"source\":")
    try value(call.source)
    try token(",\"speakerGroups\":")
    try value(call.speakerGroups)
    try token(",\"speakerNames\":")
    try value(call.speakerNames)
    try token(",\"startedAt\":")
    try value(call.startedAt)
    try token(",\"tracks\":[")
    for (index, track) in call.tracks.enumerated() {
      if index > 0 { try token(",") }
      try token("{\"inputDevice\":")
      try value(track.inputDevice)
      try token(",\"intervals\":[")
      var first = true
      try intervals(index) { span in
        if !first { try self.token(",") }
        first = false
        try autoreleasepool { try self.value(span) }
      }
      try token("],\"mediaProfileId\":")
      try value(track.mediaProfileId)
      try token(",\"role\":")
      try value(track.role)
      try token(",\"trackId\":")
      try value(track.trackId)
      try token("}")
    }
    try token("]}")
  }
}

/// A single merged source interval plus at most one bounded commit are retained at a time.
struct CaptureIntervalCursor {
  let repository: LocalRepository
  let callID: String
  let cursor: MediaMasterCursor?
  let channel: Int
  private var sequence: Int64 = 1
  private var spans: [CaptureInterval] = []
  private var offset = 0
  private var pending: CaptureInterval?
  private var endMs = 0

  init(repository: LocalRepository, callID: String, cursor: MediaMasterCursor?, channel: Int) {
    self.repository = repository
    self.callID = callID
    self.cursor = cursor
    self.channel = channel
  }

  mutating func next() throws -> TrackInterval? {
    while let span = try rawNext() {
      guard span.startMs == endMs, span.endMs > span.startMs else {
        throw LocalPersistenceError.invalidMediaProgress
      }
      endMs = span.endMs
      if var previous = pending {
        guard previous.state == span.state else {
          pending = span
          return document(previous)
        }
        previous.endMs = span.endMs
        pending = previous
      } else {
        pending = span
      }
    }
    guard endMs == Int((cursor?.frames ?? 0) / 16) else {
      throw LocalPersistenceError.invalidMediaProgress
    }
    defer { pending = nil }
    return pending.map(document)
  }

  private mutating func rawNext() throws -> CaptureInterval? {
    if offset >= spans.count {
      guard sequence <= (cursor?.commitCount ?? 0) else { return nil }
      guard let commit = try repository.mediaCommit(callID: callID, sequence: sequence) else {
        throw LocalPersistenceError.invalidMediaProgress
      }
      spans = channel == 0 ? commit.microphoneIntervals : commit.applicationIntervals
      sequence += 1
      offset = 0
      guard !spans.isEmpty else { throw LocalPersistenceError.invalidMediaProgress }
    }
    defer { offset += 1 }
    return spans[offset]
  }
  private func document(_ span: CaptureInterval) -> TrackInterval {
    .init(
      startMs: span.startMs,
      endMs: span.endMs,
      state: span.state.rawValue,
      reason: span.state == .recorded ? nil : span.state.rawValue
    )
  }
}

extension LocalRepository {
  /// Raw exchange publication can preserve alternate JSON formatting/interval splits,
  /// but cannot rewrite the source states already witnessed by capture progress.
  func validateCaptureIntervals(_ call: CallDocument, cursor: MediaMasterCursor?) throws {
    for track in call.tracks {
      var expected = CaptureIntervalCursor(
        repository: self,
        callID: call.callId,
        cursor: cursor,
        channel: track.role == "microphone" ? 0 : 1
      )
      var previous: TrackInterval?
      for span in track.intervals {
        if var prior = previous, prior.state == span.state, prior.reason == span.reason {
          prior.endMs = span.endMs
          previous = prior
        } else {
          if let previous, try expected.next() != previous {
            throw LocalPersistenceError.invalidMediaProgress
          }
          previous = span
        }
      }
      if let previous, try expected.next() != previous {
        throw LocalPersistenceError.invalidMediaProgress
      }
      guard try expected.next() == nil else { throw LocalPersistenceError.invalidMediaProgress }
    }
  }
}
