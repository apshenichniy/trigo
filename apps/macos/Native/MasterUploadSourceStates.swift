import Foundation
import TrigoContracts

/// The complete lossless state map has a fixed maximum of 5.4 MB, regardless of
/// interval fragmentation. Missing source coverage starts invalid and cannot imply sound.
struct MasterUploadSourceStates {
  let durationMs: Int
  private var bytes: Data
  private var ends = [0, 0]

  init(durationMs: Int) throws {
    guard durationMs >= 0 && durationMs <= MediaMasterProfile.maximumDurationMs else {
      throw LocalPersistenceError.invalidMediaProgress
    }
    self.durationMs = durationMs
    bytes = Data(repeating: 0xff, count: (durationMs + 1) / 2)
  }

  mutating func append(_ span: TrackInterval, channel: Int) throws {
    guard (0...1).contains(channel), span.startMs == ends[channel],
      span.endMs > span.startMs, span.endMs <= durationMs
    else { throw LocalPersistenceError.invalidMediaProgress }
    let code: UInt8
    switch span.state {
    case "recorded": code = 0
    case "muted" where channel == 0: code = 1
    case "unavailable": code = 2
    default: throw LocalPersistenceError.invalidMediaProgress
    }
    bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
      for millisecond in span.startMs..<span.endMs {
        let index = millisecond / 2
        let shift = (millisecond % 2) * 4 + channel * 2
        buffer[index] = (buffer[index] & ~(UInt8(3) << shift)) | (code << shift)
      }
    }
    ends[channel] = span.endMs
  }

  mutating func finish() throws -> Data {
    guard ends == [durationMs, durationMs] else {
      throw LocalPersistenceError.invalidMediaProgress
    }
    if durationMs % 2 == 1 { bytes[bytes.count - 1] &= 0x0f }
    return bytes
  }
}

extension LocalRepository {
  func masterUploadSourceStates(callID: String, master: FinalizedMediaMaster) async throws -> Data {
    var bitmap = try MasterUploadSourceStates(durationMs: master.durationMs)
    for channel in 0..<2 {
      var intervals = CaptureIntervalCursor(
        repository: self,
        callID: callID,
        cursor: master.cursor,
        channel: channel
      )
      var count = 0
      while let span = try intervals.next() {
        try bitmap.append(span, channel: channel)
        count += 1
        if count % 128 == 0 { try Task.checkCancellation(); await Task.yield() }
      }
    }
    return try bitmap.finish()
  }

  /// Later annotations and revision imports advance calls.hash. The first closed
  /// snapshot remains the capture's immutable upload evidence and has no revisions.
  func masterUploadSnapshotHash(callID: String) throws -> String {
    try database.access {
      guard
        let row =
          try database.rows(
            "SELECT h.hash FROM snapshot_history h JOIN call_values c ON c.hash=h.hash WHERE h.call_id=? AND c.capture_state!='recording' ORDER BY h.version LIMIT 1",
            [.text(callID)]
          )
          .first
      else { throw LocalPersistenceError.invalidMediaProgress }
      return try row.string(0)
    }
  }
}
