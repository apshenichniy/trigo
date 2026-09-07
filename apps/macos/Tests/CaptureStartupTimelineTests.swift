import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Testing
import TrigoContracts

@testable import TrigoNative

private struct StartupAudioPayload: @unchecked Sendable {
  let sample: CMSampleBuffer
}

/// Native Start may emit audio before its acknowledgement. This transport exercises
/// that real facade/sink boundary with finite synthetic PCM and no capture permissions.
/// Test-driven batches isolate startup correctness from the full suite's CPU scheduling.
@MainActor final class StartupAudioTransport: CaptureTransport {
  let role: MediaSourceRole
  var holdsStart: Bool
  private(set) var sink: CaptureStreamSink?
  private(set) var hasPendingStart = false
  private var pending: CheckedContinuation<Void, Never>?
  private var entered = false
  private var observers: [CheckedContinuation<Void, Never>] = []
  private var acceptsDelivery = false
  private let payload: StartupAudioPayload

  init(role: MediaSourceRole, holdsStart: Bool = false) throws {
    self.role = role
    self.holdsStart = holdsStart
    payload = .init(
      sample: try controlledAudioBuffer(
        sampleRate: 48_000,
        frames: 4_800,
        time: .zero,
        value: 0.25,
        channels: role == .application ? 2 : 1
      )
    )
  }

  func addCaptureOutput(
    _ output: any SCStreamOutput,
    type: SCStreamOutputType,
    queue: DispatchQueue
  ) throws {
    sink = try #require(output as? CaptureStreamSink)
  }

  func startCapture() async throws {
    _ = try #require(sink)
    acceptsDelivery = true
    if holdsStart {
      await withCheckedContinuation {
        pending = $0
        hasPendingStart = true
        signalStart()
      }
    } else {
      signalStart()
    }
  }

  func deliverBatch() async throws {
    guard acceptsDelivery, let sink else { return }
    let streamID = ObjectIdentifier(self)
    let payload = payload
    let role = role
    let accepted = await withCheckedContinuation { continuation in
      sink.callbackQueue.async {
        let deliveredAt = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
          duration: CMTime(value: 1, timescale: 48_000),
          presentationTimeStamp: CMTimeSubtract(deliveredAt, CMTime(value: 1, timescale: 10)),
          decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
          allocator: kCFAllocatorDefault,
          sampleBuffer: payload.sample,
          sampleTimingEntryCount: 1,
          sampleTimingArray: &timing,
          sampleBufferOut: &sample
        )
        guard status == noErr, let sample else {
          Issue.record("Cannot timestamp synthetic PCM")
          continuation.resume(returning: false)
          return
        }
        continuation.resume(
          returning: sink.enqueue(sample, role: role, streamID: streamID, deliveredAt: deliveredAt)
        )
      }
    }
    #expect(accepted)
    // The callback never waits. The test driver waits outside it, after one 100 ms batch,
    // so a delayed engine cannot turn this lifecycle test into an ingress overload test.
    try await sink.perform { _ in () }
  }

  func waitForStart() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }

  func acknowledgeStart() {
    pending?.resume()
    pending = nil
    hasPendingStart = false
  }

  func stopForRetirement() async throws {
    acceptsDelivery = false
  }

  private func signalStart() {
    entered = true
    for observer in observers { observer.resume() }
    observers = []
  }
}

@MainActor final class StartupAudioFixture {
  var application: StartupAudioTransport
  var microphone: StartupAudioTransport
  var failures: [String] = []
  let source = CaptureSource(
    applicationName: "Synthetic source",
    bundleID: "test.startup-audio",
    processID: 123,
    windowID: 456,
    windowTitle: nil,
    processLaunchDate: Date()
  )

  init(delayedMicrophone: Bool) throws {
    application = try .init(role: .application, holdsStart: !delayedMicrophone)
    microphone = try .init(role: .microphone, holdsStart: delayedMicrophone)
  }

  func recorder() -> ScreenCaptureRecording {
    let recorder = ScreenCaptureRecording(
      system: .init(
        permissions: { .init(screenAudio: true, microphone: true) },
        filter: { _ in SCContentFilter() },
        microphone: { .init(id: "fixture", name: "Synthetic microphone") },
        stream: { [self] _, configuration, _ in
          configuration.captureMicrophone ? microphone : application
        },
        sourceIsAvailable: { _ in true }
      )
    )
    recorder.onFailure = { [weak self] in self?.failures.append($0) }
    return recorder
  }

  func deliverBatches(_ count: Int) async throws {
    for _ in 0..<count {
      guard failures.isEmpty else { return }
      try await Task.sleep(for: .milliseconds(100))
      try await application.deliverBatch()
      try await microphone.deliverBatch()
    }
  }
}

private typealias StartupAudioRun = (
  root: URL, archiveID: String, fixture: StartupAudioFixture,
  recorder: ScreenCaptureRecording, attempt: Task<Void, any Error>
)

@MainActor private func withStartupAudioFixture(
  delayedMicrophone: Bool,
  body: @MainActor (StartupAudioRun) async throws -> Void
) async throws {
  let root = masterFixtureRoot()
  let fixture = try StartupAudioFixture(delayedMicrophone: delayedMicrophone)
  let recorder = fixture.recorder()
  let archiveID = UUID().uuidString.lowercased()
  let attempt = Task {
    try await recorder.start(root: root, archiveID: archiveID, source: fixture.source)
  }
  func cleanup() async {
    _ = try? await recorder.stop()
    for transport in [fixture.application, fixture.microphone] {
      try? await transport.stopForRetirement()
      transport.acknowledgeStart()
    }
    _ = await attempt.result
    _ = try? await recorder.stop()
    try? FileManager.default.removeItem(at: root)
  }
  do {
    try await body((root, archiveID, fixture, recorder, attempt))
  } catch {
    await cleanup()
    throw error
  }
  await cleanup()
}

@Test(arguments: [false, true]) @MainActor
func pendingNativeStartCommitsApplicationAudioAndStopFencesLateDelivery(
  delayedMicrophone: Bool
)
  async throws
{
  try await withStartupAudioFixture(delayedMicrophone: delayedMicrophone) { run in
    let (root, archiveID, fixture, recorder, attempt) = run
    let pending = delayedMicrophone ? fixture.microphone : fixture.application
    await pending.waitForStart()
    let firstSession = try #require(recorder.session)
    let oldApplication = fixture.application
    let oldSink = try #require(oldApplication.sink)
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    // Exceed the two-second reorder window with finite input while Start remains pending.
    try await fixture.deliverBatches(28)
    let confirmed = try repository.confirmedMediaCursor(callID: firstSession.callID)
    #expect((confirmed?.frames ?? 0) >= 16_000)
    #expect(recorder.phase == .starting)
    #expect(pending.hasPendingStart)
    #expect(fixture.failures.isEmpty)
    #expect(!oldSink.ingressStatistics.rejected)
    #expect(oldSink.ingressStatistics.maximumPendingSourceSeconds <= 0.100_001)
    if let confirmed {
      let spans = try repository.captureIntervals(callID: firstSession.callID, through: confirmed)
      #expect(spans[0].allSatisfy { $0.state == .unavailable })
      #expect(
        spans[1].filter { $0.state == .recorded }.reduce(0) { $0 + $1.endMs - $1.startMs } >= 1000
      )
    }
    _ = try await recorder.stop()
    #expect(recorder.phase == .cancellingStart)
    let stoppedCursor = try repository.confirmedMediaCursor(callID: firstSession.callID)
    pending.acknowledgeStart()
    _ = await attempt.result
    #expect(recorder.phase == .idle)
    let stale = try controlledAudioBuffer(sampleRate: 48_000, frames: 480, time: .zero, value: 0.9)
    #expect(
      !oldSink.enqueue(
        stale,
        role: .application,
        streamID: ObjectIdentifier(oldApplication),
        deliveredAt: .zero
      )
    )
    // A fresh call owns fresh transports; late old callbacks cannot consume its capacity.
    fixture.application = try .init(role: .application)
    fixture.microphone = try .init(role: .microphone)
    try await recorder.start(root: root, archiveID: archiveID, source: fixture.source)
    #expect(recorder.session?.callID != firstSession.callID)
    let nextSink = try #require(fixture.application.sink)
    #expect(
      !nextSink.enqueue(
        stale,
        role: .application,
        streamID: ObjectIdentifier(oldApplication),
        deliveredAt: .zero
      )
    )
    _ = try await recorder.stop()
    #expect(try repository.confirmedMediaCursor(callID: firstSession.callID) == stoppedCursor)
    #expect(recorder.phase == .idle)
  }
}

@Test @MainActor func pendingMicrophoneSamplesStaySuppressedAndRecordingMuteRemainsEffective()
  async throws
{
  try await withStartupAudioFixture(delayedMicrophone: true) { run in
    let (root, archiveID, fixture, recorder, attempt) = run
    await fixture.microphone.waitForStart()
    let session = try #require(recorder.session)
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    try await fixture.deliverBatches(5)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    var beforeFrames: Int64 = 0
    while beforeFrames == 0, ContinuousClock.now < deadline, fixture.failures.isEmpty {
      beforeFrames = try repository.confirmedMediaCursor(callID: session.callID)?.frames ?? 0
      if beforeFrames == 0 { try await Task.sleep(for: .milliseconds(20)) }
    }
    #expect(beforeFrames > 0)
    #expect(recorder.phase == .starting)
    #expect(fixture.failures.isEmpty)
    fixture.microphone.acknowledgeStart()
    try await attempt.value
    #expect(recorder.phase == .recording)
    try await fixture.deliverBatches(3)
    // Use the existing recording-only control admission; pending Start admits no new UI controls.
    try await recorder.setMicrophoneEnabled(false)
    try await fixture.deliverBatches(3)
    let result = try #require(try await recorder.stop())
    let final = try #require(try repository.finalizedMaster(callID: session.callID))
    let spans = try repository.captureIntervals(callID: session.callID, through: final.cursor)
    #expect(spans[0].first?.state == .unavailable)
    #expect(spans[0].contains { $0.state == .recorded })
    #expect(spans[0].last?.state == .muted)
    #expect(
      spans[1].filter { $0.state == .recorded }.reduce(0) { $0 + $1.endMs - $1.startMs } >= 500
    )
    let file = try AVAudioFile(
      forReading: session.mediaDirectory.appendingPathComponent("master.caf")
    )
    let pcm = try #require(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(file.length)
      )
    )
    try file.read(into: pcm)
    let channels = try #require(pcm.floatChannelData)
    for interval in spans[0] where interval.state != .recorded {
      #expect((interval.startMs * 16..<interval.endMs * 16).allSatisfy { channels[0][$0] == 0 })
    }
    #expect((0..<Int(beforeFrames)).allSatisfy { channels[0][$0] == 0 })
    #expect(fixture.failures.isEmpty)
    #expect(result.call.captureState == .stopped)
  }
}
