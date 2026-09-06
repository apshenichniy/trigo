import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import TrigoNative

@Test func threeHourProfileWriterRetainsEverySecondWithoutTruncation() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-three-hour-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try CaptureMediaWriter(directory: root)
  let second = (0..<16_000).flatMap { _ in [Int16(2_048), Int16(-4_096)] }
  for _ in 0..<10_800 { try writer.append(interleaved: second) }
  #expect(throws: CaptureError.durationLimit) {
    try writer.append(interleaved: Array(repeating: 0, count: 32))
  }
  let media = try writer.finish()
  #expect(media.durationMs == 10_800_000)
  #expect(media.objects.count == 180)
  #expect(media.objects.allSatisfy { $0.byteLength == 3_840_044 })
  var frames: Int64 = 0
  for object in media.objects {
    frames += try AVAudioFile(forReading: root.appendingPathComponent(object.filename)).length
  }
  #expect(frames == 172_800_000)
  let recovery = try CaptureMediaWriter.recover(directory: root)
  #expect(recovery.media == media)
  #expect(!recovery.wasInterrupted)
}

@Test func oneHourCommonClockFixtureHasNoAccumulatingSourceRelativeDrift() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-one-hour-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let engine = try CaptureRecordingEngine(
    directory: root, origin: .zero,
    microphone: .init(id: "fixture", name: "Controlled 44.1 kHz microphone"))
  // Independent 48 kHz/44.1 kHz callbacks share host timestamps. A simultaneous
  // 100 ms pulse every second is an external synchronization marker, not implementation math.
  for second in 0..<3_600 {
    for part in 0..<10 {
      let time = CMTime(value: Int64(second * 10 + part), timescale: 10)
      let level: Float = part == 0 ? 0.25 : 0
      try engine.receive(
        controlledAudioBuffer(sampleRate: 48_000, frames: 4_800, time: time, value: level),
        role: .application)
      try engine.receive(
        controlledAudioBuffer(sampleRate: 44_100, frames: 4_410, time: time, value: level),
        role: .microphone)
      if part == 4 || part == 9 {
        try engine.advance(at: CMTime(value: Int64(second * 10 + part + 1), timescale: 10))
      }
    }
  }
  let media = try engine.stop(at: CMTime(value: 3_600, timescale: 1))
  #expect(media.durationMs == 3_600_000)
  #expect(media.objects.count == 60)
  var worstDriftFrames = 0
  for object in media.objects {
    let file = try AVAudioFile(forReading: root.appendingPathComponent(object.filename))
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 960_000))
    try file.read(into: buffer)
    let channels = try #require(buffer.floatChannelData)
    for second in 0..<60 {
      let start = second * 16_000
      let mic = try #require((start..<(start + 3_200)).first { abs(channels[0][$0]) > 0.1 })
      let app = try #require((start..<(start + 3_200)).first { abs(channels[1][$0]) > 0.1 })
      worstDriftFrames = max(worstDriftFrames, abs(mic - app))
    }
  }
  #expect(worstDriftFrames <= 3_200)  // 200 ms at the independently decoded profile rate.
  print("Controlled one-hour source-relative drift: \(Double(worstDriftFrames) / 16) ms")
}
