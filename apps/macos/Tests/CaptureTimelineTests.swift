import AVFoundation
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func commonTimelineKeepsInitialGapAndSuppressesQueuedMicrophoneBeforePersistence() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-timeline-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try CaptureMediaWriter(directory: root)
  let timeline = CaptureTimeline(writer: writer)
  try timeline.append(
    role: .application, startFrame: 0, samples: Array(repeating: -8_192, count: 9_600))
  try timeline.append(
    role: .microphone, startFrame: 1_600, samples: Array(repeating: 8_192, count: 3_200))
  try timeline.setMicrophoneEnabled(false, atMs: 200)
  try timeline.append(
    role: .microphone, startFrame: 3_200, samples: Array(repeating: 30_000, count: 3_200))
  try timeline.setMicrophoneEnabled(true, atMs: 400)
  // A delayed callback covers muted time and the newly enabled interval.
  try timeline.append(
    role: .microphone, startFrame: 4_800, samples: Array(repeating: 16_384, count: 4_800))
  try timeline.flush(throughMs: 600)
  let media = try writer.finish()
  let file = try AVAudioFile(
    forReading: root.appendingPathComponent(#require(media.objects.first).filename))
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 9_600))
  try file.read(into: buffer)
  let channels = try #require(buffer.floatChannelData)
  #expect((0..<1_600).allSatisfy { channels[0][$0] == 0 })
  #expect((1_600..<3_200).allSatisfy { channels[0][$0] == 0.25 })
  #expect((3_200..<6_400).allSatisfy { channels[0][$0] == 0 })
  #expect((6_400..<9_600).allSatisfy { channels[0][$0] == 0.5 })
  #expect((0..<9_600).allSatisfy { channels[1][$0] == -0.25 })
  #expect(
    timeline.intervals(for: .microphone) == [
      .init(startMs: 0, endMs: 100, state: .unavailable),
      .init(startMs: 100, endMs: 200, state: .recorded),
      .init(startMs: 200, endMs: 400, state: .muted),
      .init(startMs: 400, endMs: 600, state: .recorded),
    ])
  let recovered = try CaptureMediaWriter.recover(directory: root)
  #expect(recovered.media.microphoneIntervals == timeline.intervals(for: .microphone))
  #expect(recovered.media.applicationIntervals == timeline.intervals(for: .application))
}
