import Foundation
import Testing

@testable import TrigoNative

@Test @MainActor func finishWaitsForLateMicrophoneReplacementBeforeStartOrQuitIsSafe()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  fixture.os.microphoneDevice = nil
  await fixture.capture.checkSourceAndMicrophone()
  fixture.os.microphone.suspendStart = true
  fixture.os.microphoneDevice = .init(id: "replacement", name: "Replacement")
  let replacement = Task { await fixture.capture.checkSourceAndMicrophone() }
  for _ in 0..<10_000 {
    if fixture.os.microphone.startCalls == 2 { break }
    await Task.yield()
  }
  #expect(fixture.os.microphone.startCalls == 2)
  await fixture.coordinator.stop()
  // The native microphone Start can still acknowledge after its earlier Stop.
  #expect(!fixture.coordinator.canStart)
  #expect(!fixture.coordinator.canTerminateImmediately)
  #expect(fixture.coordinator.finalization.captureStopped)
  #expect(fixture.coordinator.finalization.localSave == .confirmed)
  #expect(fixture.coordinator.finalization.pendingNativeStart)
  fixture.os.microphone.finishStart()
  await replacement.value
  #expect(!fixture.os.microphone.running)
  #expect(fixture.coordinator.canStart)
  #expect(fixture.coordinator.canTerminateImmediately)
  #expect(fixture.coordinator.finalization.isSettled)
}

private struct PanelSaveFailure: Error {}

@Test(arguments: [false, true], [false, true]) @MainActor
func captureStopAndLocalSaveRemainIndependentFacts(stopFails: Bool, saveFails: Bool) async throws {
  let fixture = try RecordingControlFixture(
    persistence: .init(
      complete: { session, media, reason in
        try await session.complete(media: media, interruptionReason: reason) { point in
          if saveFails && point == .beforeCommit { throw PanelSaveFailure() }
        }
      },
      recover: CapturePersistence.live.recover
    )
  )
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  fixture.os.application.failsStop = stopFails
  await fixture.coordinator.stop()
  let state = fixture.coordinator.finalization
  #expect(state.captureStopped == !stopFails)
  #expect(state.localSave == (saveFails ? .needsRecovery : .confirmed))
  #expect(!state.pendingNativeStart)
  #expect(fixture.coordinator.canStart == !(stopFails || saveFails))
  #expect(fixture.coordinator.canTerminateImmediately == !(stopFails || saveFails))
  let repository = try LocalRepository(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID
  )
  let callID = try #require(state.callID)
  #expect((try repository.captureCompletion(callID: callID) != nil) == !saveFails)
  if stopFails || saveFails {
    #expect(fixture.coordinator.canRetryLocalRecovery)
    // A second failed native retirement must not prevent restoring the local save.
    await fixture.coordinator.retryRecovery()
    #expect(fixture.coordinator.finalization.localSave == .confirmed)
    #expect(try repository.captureCompletion(callID: callID) != nil)
    #expect(fixture.coordinator.finalization.captureStopped == !stopFails)
    fixture.os.application.failsStop = false
    await fixture.coordinator.retryRecovery()
    #expect(fixture.coordinator.finalization.isSettled)
    #expect(fixture.coordinator.canStart)
    #expect(fixture.coordinator.canTerminateImmediately)
  }
}

private actor PanelSaveGate {
  private var held: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []
  private(set) var calls = 0
  func hold() async {
    calls += 1
    await withCheckedContinuation {
      held = $0
      for observer in observers { observer.resume() }
      observers = []
    }
  }
  func wait() async {
    guard held == nil else { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() { held?.resume(); held = nil }
}

@Test @MainActor func savingStopsActivityAndRepeatedFinishSharesOneDurableCompletion() async throws
{
  let gate = PanelSaveGate()
  let fixture = try RecordingControlFixture(
    persistence: .init(
      complete: { session, media, reason in
        await gate.hold()
        return try await session.complete(media: media, interruptionReason: reason)
      },
      recover: CapturePersistence.live.recover
    )
  )
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  let first = Task { await fixture.coordinator.stop() }
  await gate.wait()
  #expect(fixture.coordinator.phase == .stopping)
  #expect(fixture.coordinator.finalization.captureStopped)
  #expect(fixture.coordinator.finalization.localSave == .pending)
  #expect(fixture.coordinator.recordingSnapshot?.levels == RecordedAudioLevels())
  #expect(!fixture.coordinator.canStart)
  #expect(!fixture.coordinator.canTerminateImmediately)
  let repeated = Task { await fixture.coordinator.stop() }
  await gate.release()
  await first.value
  await repeated.value
  #expect(await gate.calls == 1)
  #expect(fixture.coordinator.finalization.isSettled)
}
