import AVFoundation
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func commonTimelineKeepsInitialGapAndSuppressesQueuedMicrophoneBeforePersistence()
  async throws
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-timeline-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let timeline = CaptureTimeline(writer: writer)
  try timeline.append(
    role: .application,
    startFrame: 0,
    samples: Array(repeating: -8_192, count: 9_600)
  )
  try timeline.append(
    role: .microphone,
    startFrame: 1_600,
    samples: Array(repeating: 8_192, count: 3_200)
  )
  try timeline.setMicrophoneEnabled(false, atMs: 200)
  try timeline.append(
    role: .microphone,
    startFrame: 3_200,
    samples: Array(repeating: 30_000, count: 3_200)
  )
  try timeline.setMicrophoneEnabled(true, atMs: 400)
  // A delayed callback covers muted time and the newly enabled interval.
  try timeline.append(
    role: .microphone,
    startFrame: 4_800,
    samples: Array(repeating: 16_384, count: 4_800)
  )
  try timeline.flush(throughMs: 600)
  _ = try finishCapture(writer)
  let file = try AVAudioFile(
    forReading: writer.master.mediaURL
  )
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 9_600)
  )
  try file.read(into: buffer)
  let channels = try #require(buffer.floatChannelData)
  #expect((0..<1_600).allSatisfy { channels[0][$0] == 0 })
  #expect((1_600..<3_200).allSatisfy { channels[0][$0] == 0.25 })
  #expect((3_200..<6_400).allSatisfy { channels[0][$0] == 0 })
  #expect((6_400..<9_600).allSatisfy { channels[0][$0] == 0.5 })
  #expect((0..<9_600).allSatisfy { channels[1][$0] == -0.25 })
  #expect(
    (try captureIntervals(writer, role: .microphone)) == [
      .init(startMs: 0, endMs: 100, state: .unavailable),
      .init(startMs: 100, endMs: 200, state: .recorded),
      .init(startMs: 200, endMs: 400, state: .muted),
      .init(startMs: 400, endMs: 600, state: .recorded),
    ]
  )
  let recovered = try CaptureMediaWriter.recover(session: writer.session)
  #expect(
    (try captureIntervals(recovered, role: .microphone))
      == (try captureIntervals(writer, role: .microphone))
  )
  #expect(
    (try captureIntervals(recovered, role: .application))
      == (try captureIntervals(writer, role: .application))
  )
}

@Test func partialMillisecondsAreWhollyUnavailableAndSilentBeforeStableReads() async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let timeline = CaptureTimeline(writer: writer)
  // One missing sample makes that canonical millisecond unavailable. Samples from the
  // other 15 frames must not survive in the master, its hash, ranges or extracted input.
  try timeline.append(role: .microphone, startFrame: 1, samples: Array(repeating: 8192, count: 31))
  try timeline.append(
    role: .application,
    startFrame: 0,
    samples: Array(repeating: -8192, count: 31)
  )
  try timeline.flush(throughMs: 2)
  let bytes = try writer.master.readStableBytes(in: 68..<196)
  let samples = bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
  #expect((0..<16).allSatisfy { samples[$0 * 2] == 0 && samples[$0 * 2 + 1] == -8192 })
  #expect((16..<32).allSatisfy { samples[$0 * 2] == 8192 && samples[$0 * 2 + 1] == 0 })
  #expect(
    try captureIntervals(writer, role: .microphone) == [
      .init(startMs: 0, endMs: 1, state: .unavailable),
      .init(startMs: 1, endMs: 2, state: .recorded),
    ]
  )
  #expect(
    try captureIntervals(writer, role: .application) == [
      .init(startMs: 0, endMs: 1, state: .recorded),
      .init(startMs: 1, endMs: 2, state: .unavailable),
    ]
  )
  _ = try finishCapture(writer)
  let extracted = root.appendingPathComponent("interval.caf")
  _ = try writer.master.extract(frames: 0..<32, to: extracted)
  #expect(try Data(contentsOf: extracted).dropFirst(68) == bytes)
}
