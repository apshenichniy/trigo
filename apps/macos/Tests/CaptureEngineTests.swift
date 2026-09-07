import CoreMedia
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func microphoneLossKeepsApplicationRecordingAndReturnPreservesMute() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("trigo-engine-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let engine = try CaptureRecordingEngine(
    writer: writer,
    origin: .zero,
    microphone: .init(id: "first", name: "First")
  )
  try engine.setMicrophoneEnabled(false, at: CMTime(seconds: 0.1, preferredTimescale: 16_000))
  try engine.microphoneChanged(nil, at: CMTime(seconds: 0.2, preferredTimescale: 16_000))
  #expect(engine.snapshot.state == .recording)
  #expect(engine.snapshot.microphone == nil)
  try engine.microphoneChanged(
    .init(id: "replacement", name: "Replacement"),
    at: CMTime(seconds: 0.3, preferredTimescale: 16_000)
  )
  #expect(engine.snapshot.microphone?.name == "Replacement")
  #expect(!engine.snapshot.microphoneEnabled)
  try engine.receive(
    controlledAudioBuffer(sampleRate: 16_000, frames: 8_000, time: .zero, value: 0.25),
    role: .application
  )
  try engine.receive(
    controlledAudioBuffer(
      sampleRate: 16_000,
      frames: 3_200,
      time: CMTime(seconds: 0.3, preferredTimescale: 16_000),
      value: 0.75
    ),
    role: .microphone
  )
  let media = try engine.stop(
    at: CMTime(seconds: 0.5, preferredTimescale: 16_000),
    reason: "source_exited"
  )
  #expect(engine.snapshot.state == .interrupted)
  #expect(engine.snapshot.interruptionReason == "source_exited")
  #expect(media.durationMs == 500)
  #expect(
    (try captureIntervals(writer, role: .application)) == [
      .init(startMs: 0, endMs: 500, state: .recorded)
    ]
  )
  #expect(
    (try captureIntervals(writer, role: .microphone)) == [
      .init(startMs: 0, endMs: 100, state: .unavailable),
      .init(startMs: 100, endMs: 200, state: .muted),
      .init(startMs: 200, endMs: 300, state: .unavailable),
      .init(startMs: 300, endMs: 500, state: .muted),
    ]
  )
  #expect(throws: CaptureError.closed) {
    try engine.receive(
      controlledAudioBuffer(sampleRate: 16_000, frames: 16, time: .zero, value: 1),
      role: .application
    )
  }
}

@Test func delayedMutedInputCannotPrimeTheConverterAfterUnmute() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-mute-fence-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let engine = try CaptureRecordingEngine(
    writer: writer,
    origin: .zero,
    microphone: .init(id: "mic", name: "Mic")
  )
  try engine.setMicrophoneEnabled(false, at: .zero)
  try engine.receive(
    controlledAudioBuffer(sampleRate: 48_000, frames: 4_800, time: .zero, value: 0.9),
    role: .microphone
  )
  try engine.setMicrophoneEnabled(true, at: CMTime(seconds: 0.1, preferredTimescale: 48_000))
  // This stale callback is delivered after Unmute, but originated during mute.
  try engine.receive(
    controlledAudioBuffer(sampleRate: 48_000, frames: 4_800, time: .zero, value: 0.9),
    role: .microphone
  )
  try engine.receive(
    controlledAudioBuffer(
      sampleRate: 48_000,
      frames: 4_800,
      time: CMTime(seconds: 0.1, preferredTimescale: 48_000),
      value: 0
    ),
    role: .microphone
  )
  _ = try engine.stop(at: CMTime(seconds: 0.2, preferredTimescale: 48_000))
  let bytes = try Data(
    contentsOf: writer.master.mediaURL
  )
  #expect(bytes.dropFirst(68).allSatisfy { $0 == 0 })
}

@Test func invalidInterruptionIdentityCannotFinalizeEitherStore() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-invalid-reason-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let engine = try CaptureRecordingEngine(writer: writer, origin: .zero, microphone: nil)
  #expect(throws: LocalPersistenceError.invalidFailureCode("Bad reason")) {
    try engine.stop(at: .zero, reason: "Bad reason")
  }
  #expect(engine.snapshot.state == .recording)
  #expect(try CaptureMediaWriter.recover(session: writer.session).master.finalized == nil)
}
