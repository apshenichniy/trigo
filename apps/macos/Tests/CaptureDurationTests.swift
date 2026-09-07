import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import TrigoNative

@Test func threeHourProfileWriterRetainsEverySecondWithoutTruncation() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-three-hour-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let second = (0..<16_000).flatMap { _ in [Int16(2_048), Int16(-4_096)] }
  for _ in 0..<10_800 { try writer.append(interleaved: second) }
  #expect(throws: CaptureError.durationLimit) {
    try writer.append(interleaved: Array(repeating: 0, count: 32))
  }
  let media = try finishCapture(writer)
  #expect(media.durationMs == 10_800_000)
  #expect(media.cursor.stableBytes == 691_200_068)
  #expect(try AVAudioFile(forReading: writer.master.mediaURL).length == 172_800_000)
  let recovery = try CaptureMediaWriter.recover(session: writer.session)
  #expect(try recovery.finish() == media)
  let final = try await writer.session.finish(media: media, interruptionReason: nil)
  #expect(final.manifest.value.durationMs == 10_800_000)
  #expect(final.manifest.value.tracks.allSatisfy { $0.intervals.count == 1 })
  masterResources("production-constant-three-hour-final-projection")
}

@Test func oneHourCommonClockFixtureHasNoAccumulatingSourceRelativeDrift() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-one-hour-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let engine = try CaptureRecordingEngine(
    writer: writer,
    origin: .zero,
    microphone: .init(id: "fixture", name: "Controlled 44.1 kHz microphone")
  )
  // Independent 48 kHz/44.1 kHz callbacks share host timestamps. A simultaneous
  // 100 ms pulse every second is an external synchronization marker, not implementation math.
  for second in 0..<3_600 {
    for part in 0..<10 {
      let time = CMTime(value: Int64(second * 10 + part), timescale: 10)
      let level: Float = part == 0 ? 0.25 : 0
      try engine.receive(
        controlledAudioBuffer(sampleRate: 48_000, frames: 4_800, time: time, value: level),
        role: .application
      )
      try engine.receive(
        controlledAudioBuffer(sampleRate: 44_100, frames: 4_410, time: time, value: level),
        role: .microphone
      )
      if part == 4 || part == 9 {
        try engine.advance(at: CMTime(value: Int64(second * 10 + part + 1), timescale: 10))
      }
    }
  }
  let media = try engine.stop(at: CMTime(value: 3_600, timescale: 1))
  #expect(media.durationMs == 3_600_000)
  #expect(media.cursor.stableBytes == 230_400_068)
  var worstDriftFrames = 0
  let file = try AVAudioFile(forReading: writer.master.mediaURL)
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)
  )
  for _ in 0..<3_600 {
    try file.read(into: buffer)
    let channels = try #require(buffer.floatChannelData)
    let mic = try #require((0..<3_200).first { abs(channels[0][$0]) > 0.1 })
    let app = try #require((0..<3_200).first { abs(channels[1][$0]) > 0.1 })
    worstDriftFrames = max(worstDriftFrames, abs(mic - app))
  }
  let final = try await writer.session.finish(media: media, interruptionReason: nil)
  #expect(final.manifest.value.durationMs == 3_600_000)
  let repository = try LocalRepository(root: root, archiveID: writer.session.archiveID)
  #expect(try repository.finalizedMaster(callID: writer.session.callID) == media)
  masterResources("production-common-clock-one-hour-final-projection")
  #expect(worstDriftFrames <= 3_200)  // 200 ms at the independently decoded profile rate.
  print("Controlled one-hour source-relative drift: \(Double(worstDriftFrames) / 16) ms")
}
