import AVFoundation
import CryptoKit
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

/// The same source-state fixture as #51, now through production timeline, writer and SQLite.
private func productionTimelineSecond(_ second: Int, into timeline: CaptureTimeline) throws {
  for ms in stride(from: 0, to: 1000, by: 10) {
    let microphone = masterState(second: second, millisecond: ms, channel: 0)
    try timeline.setMicrophoneEnabled(microphone != .muted, atMs: second * 1000 + ms)
    try timeline.setMicrophoneAvailable(microphone != .unavailable, atMs: second * 1000 + ms)
    let start = second * 16000 + ms * 16
    try timeline.append(
      role: .microphone,
      startFrame: start,
      samples: (ms * 16..<(ms * 16 + 160))
        .map {
          masterSignal(second: second, frame: $0, channel: 0)
        }
    )
    if masterState(second: second, millisecond: ms, channel: 1) == .recorded {
      try timeline.append(
        role: .application,
        startFrame: start,
        samples: (ms * 16..<(ms * 16 + 160))
          .map {
            masterSignal(second: second, frame: $0, channel: 1)
          }
      )
    }
  }
  try timeline.flush(throughMs: (second + 1) * 1000)
}

private func proveProductionMaster(seconds: Int) async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let timeline = CaptureTimeline(writer: writer)
  let start = Date()
  var stableRange: Data?
  for second in 0..<seconds {
    try autoreleasepool { try productionTimelineSecond(second, into: timeline) }
    if second == 132 {
      stableRange = try writer.readStableBytes(
        in: 0..<Int64(MediaMasterProfile.maximumRequestBytes)
      )
    }
  }
  let appendSeconds = Date().timeIntervalSince(start)
  masterResources("production-frequent-append-\(seconds)")
  let final = try finishCapture(writer)
  #expect(final.cursor.frames == Int64(seconds) * 16_000)
  #expect(final.cursor.stableBytes == 68 + Int64(seconds) * 64_000)
  #expect(
    try writer.readStableBytes(in: 0..<Int64(MediaMasterProfile.maximumRequestBytes)) == stableRange
  )
  #expect(throws: MediaMasterError.invalidInput) {
    try writer.readStableBytes(in: 0..<Int64(MediaMasterProfile.maximumRequestBytes + 1))
  }
  let file = try AVAudioFile(forReading: writer.master.mediaURL)
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)
  )
  for second in 0..<seconds {
    try file.read(into: buffer)
    #expect(buffer.frameLength == 16_000)
    try checkMasterSamples(buffer, startFrame: Int64(second) * 16_000)
  }
  for position in [Int64(0), 1599, Int64(seconds / 2) * 16_000 + 15993, final.cursor.frames - 77] {
    file.framePosition = position
    try file.read(into: buffer, frameCount: 77)
    try checkMasterSamples(buffer, startFrame: position)
  }
  let reopen = try CaptureMediaWriter.recover(session: writer.session)
  #expect(try reopen.finish() == final)
  #expect(try masterFileHash(writer.master.mediaURL) == final.sha256)
  masterResources("production-frequent-reopen-\(seconds)")
  let projectionStart = Date()
  let result = try await writer.session.complete(media: final, interruptionReason: nil)
  let repository = try LocalRepository(root: root, archiveID: writer.session.archiveID)
  let intervalCount = try repository.database.access {
    try repository.database
      .rows(
        "SELECT COUNT(*) FROM track_intervals WHERE hash=?",
        [.text(result.snapshotSHA256)]
      )[0]
      .int(0)
  }
  var streamedHash = SHA256()
  try repository.forEachSnapshotChunk(callID: writer.session.callID, version: 2) {
    streamedHash.update(data: $0)
  }
  #expect(Data(streamedHash.finalize()).masterHex == result.snapshotSHA256)
  #expect(try await writer.session.recoverCompletion() == result)
  let projectionSeconds = Date().timeIntervalSince(projectionStart)
  masterResources("production-frequent-final-projection-\(seconds)")
  let extracted = root.appendingPathComponent("complete-extraction.caf")
  let extraction = try reopen.extract(frames: 0..<final.cursor.frames, to: extracted)
  #expect(extraction.sha256 == final.sha256)
  #expect(try masterFileHash(extracted) == final.sha256)
  #expect(extraction.master.cursor.identity == writer.session.mediaMasterIdentity)
  #expect(FileManager.default.fileExists(atPath: writer.master.mediaURL.path))
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: writer.session.mediaDirectory.path).sorted()
      == ["master.caf", "master.index"]
  )
  masterResources("production-frequent-full-extraction-\(seconds)")
  print(
    "PRODUCTION_MASTER seconds=\(seconds) frames=\(final.cursor.frames) bytes=\(final.cursor.stableBytes) intervals=\(intervalCount) snapshot_bytes=\(result.snapshotByteLength) append_s=\(appendSeconds) final_projection_s=\(projectionSeconds) sha256=\(final.sha256)"
  )
}

@Test func productionMasterOneHourFrequentStateProof() async throws {
  try await proveProductionMaster(seconds: 3600)
}
@Test func productionMasterThreeHourFrequentStateProof() async throws {
  try await proveProductionMaster(seconds: 10800)
}
