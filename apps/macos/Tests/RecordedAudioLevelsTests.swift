import CoreMedia
import Foundation
import Testing

@testable import TrigoNative

@Test func recordedLevelsMeasureWrittenContributionsAfterDuplicatesMuteAndAvailability()
  async throws
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("trigo-levels-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let timeline = CaptureTimeline(writer: writer)
  try timeline.append(
    role: .application,
    startFrame: 0,
    samples: Array(repeating: 8192, count: 8000)
  )
  try timeline.append(
    role: .microphone,
    startFrame: 0,
    samples: Array(repeating: 16384, count: 8000)
  )
  // A duplicate callback must not affect either the recorded PCM or its indicator.
  try timeline.append(
    role: .application,
    startFrame: 0,
    samples: Array(repeating: 30000, count: 8000)
  )
  let initial = try timeline.flush(throughMs: 500)
  #expect(initial == RecordedAudioLevels(microphoneRMS: 0.5, applicationRMS: 0.25))
  try timeline.append(
    role: .application,
    startFrame: 8000,
    samples: Array(repeating: 0, count: 8000)
  )
  try timeline.append(
    role: .microphone,
    startFrame: 8000,
    samples: Array(repeating: 0, count: 8000)
  )
  #expect(try timeline.flush(throughMs: 1000) == RecordedAudioLevels())

  try timeline.append(
    role: .application,
    startFrame: 16000,
    samples: Array(repeating: 8192, count: 8000)
  )
  try timeline.append(
    role: .microphone,
    startFrame: 16000,
    samples: Array(repeating: 30000, count: 8000)
  )
  try timeline.setMicrophoneEnabled(false, atMs: 1000)
  #expect(try timeline.flush(throughMs: 1500) == RecordedAudioLevels(applicationRMS: 0.25))
  try timeline.setMicrophoneEnabled(true, atMs: 1500)
  try timeline.append(
    role: .microphone,
    startFrame: 16000,
    samples: Array(repeating: 30000, count: 8000)
  )
  try timeline.append(
    role: .microphone,
    startFrame: 24000,
    samples: Array(repeating: 0, count: 8000)
  )
  #expect(try timeline.flush(throughMs: 2000) == RecordedAudioLevels())
  try timeline.setMicrophoneAvailable(false, atMs: 2000)
  try timeline.append(
    role: .microphone,
    startFrame: 32000,
    samples: Array(repeating: 30000, count: 8000)
  )
  #expect(try timeline.flush(throughMs: 2500) == RecordedAudioLevels())
  #expect(try timeline.flush(throughMs: 2500) == RecordedAudioLevels())
  _ = try finishCapture(writer)
  let bytes = try Data(contentsOf: writer.master.mediaURL)
  // The first admitted signal is present; every microphone frame after mute is zero.
  for frame in 0..<8000 {
    let offset = MediaMasterProfile.headerBytes + frame * 4
    #expect(bytes[offset] == 0 && bytes[offset + 1] == 64)
    #expect(bytes[offset + 2] == 0 && bytes[offset + 3] == 32)
  }
  for frame in 16000..<40000 {
    let offset = MediaMasterProfile.headerBytes + frame * 4
    #expect(bytes[offset] == 0 && bytes[offset + 1] == 0)
  }
}

@Test func recordedLevelsBoundTheirWindowAndResetOnControlAndStop() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-level-window-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let timeline = CaptureTimeline(writer: writer)
  try timeline.append(
    role: .application,
    startFrame: 0,
    samples: Array(repeating: 32767, count: 24000)
  )
  try timeline.append(
    role: .application,
    startFrame: 24000,
    samples: Array(repeating: 0, count: 8000)
  )
  #expect(try timeline.flush(throughMs: 2000) == RecordedAudioLevels())
  _ = try finishCapture(writer)

  let engineWriter = try await captureWriter(root: root.appendingPathComponent("engine"))
  let engine = try CaptureRecordingEngine(
    writer: engineWriter,
    origin: .zero,
    microphone: .init(id: "mic", name: "Mic")
  )
  try engine.receive(
    controlledAudioBuffer(sampleRate: 16000, frames: 8000, time: .zero, value: 0.5),
    role: .microphone
  )
  try engine.receive(
    controlledAudioBuffer(sampleRate: 16000, frames: 8000, time: .zero, value: 0.25),
    role: .application
  )
  #expect(engine.snapshot.levels == RecordedAudioLevels())
  try engine.advance(at: CMTime(seconds: 0.75, preferredTimescale: 16000))
  #expect(abs(engine.snapshot.levels.microphoneRMS - 0.5) < 0.001)
  #expect(abs(engine.snapshot.levels.applicationRMS - 0.25) < 0.001)
  try engine.setMicrophoneEnabled(false, at: CMTime(seconds: 0.75, preferredTimescale: 16000))
  #expect(engine.snapshot.levels.microphoneRMS == 0)
  try engine.microphoneChanged(nil, at: CMTime(seconds: 0.75, preferredTimescale: 16000))
  #expect(engine.snapshot.levels.microphoneRMS == 0)
  _ = try engine.stop(at: CMTime(seconds: 1, preferredTimescale: 16000))
  #expect(engine.snapshot.levels == RecordedAudioLevels())
}
