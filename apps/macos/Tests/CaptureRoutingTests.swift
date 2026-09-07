import CoreMedia
import Foundation
import Testing

@testable import TrigoNative

@Test func nativeRoutingRejectsForeignAndReplacedStreamsAndIsolatesMicrophoneFailure() async throws
{
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-routing-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let engine = try CaptureRecordingEngine(
    writer: writer, origin: .zero, microphone: .init(id: "mic", name: "Mic"))
  let routing = CaptureAudioRouting(engine: engine)
  let app = NSObject()
  let mic = NSObject()
  let replacement = NSObject()
  routing.select(ObjectIdentifier(app), for: .application)
  routing.select(ObjectIdentifier(mic), for: .microphone)
  let sample = try controlledAudioBuffer(sampleRate: 16_000, frames: 160, time: .zero, value: 0.25)
  #expect(
    routing.receive(sample, role: .application, streamID: ObjectIdentifier(mic), at: .zero)
      == .ignored)
  routing.select(ObjectIdentifier(replacement), for: .microphone)
  #expect(
    routing.receive(sample, role: .microphone, streamID: ObjectIdentifier(mic), at: .zero)
      == .ignored)
  CMSampleBufferInvalidate(sample)
  #expect(
    routing.receive(sample, role: .microphone, streamID: ObjectIdentifier(replacement), at: .zero)
      == .microphoneUnavailable)
  #expect(engine.snapshot.state == .recording)
  #expect(engine.snapshot.microphone == nil)
  let valid = try controlledAudioBuffer(sampleRate: 16_000, frames: 160, time: .zero, value: 0.25)
  #expect(
    routing.receive(valid, role: .application, streamID: ObjectIdentifier(app), at: .zero)
      == .accepted)
  _ = try engine.stop(at: CMTime(seconds: 0.01, preferredTimescale: 16_000))
  #expect(
    (try captureIntervals(writer, role: .application)) == [
      .init(startMs: 0, endMs: 10, state: .recorded)
    ])
}
