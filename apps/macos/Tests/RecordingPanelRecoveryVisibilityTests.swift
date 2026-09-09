import Foundation
import Testing

@testable import TrigoNative

private struct PanelRecoveryVisibilityFailure: Error {}

@Test(arguments: [false, true]) @MainActor
func successfulLivePanelRecoveryHidesControlsAfterStopOrSaveFailure(stopFails: Bool) async throws {
  let fixture = try RecordingControlFixture(
    persistence: .init(
      complete: { session, media, reason in
        try await session.complete(media: media, interruptionReason: reason) { point in
          if !stopFails && point == .beforeCommit { throw PanelRecoveryVisibilityFailure() }
        }
      },
      recover: CapturePersistence.live.recover
    )
  )
  defer { fixture.cleanup() }
  await fixture.bind()
  let services = LiveDesktopRecordingServices(coordinator: fixture.coordinator)
  let composition = try DesktopComposition(
    fixtureBundleIdentifier: "io.github.apshenichniy.trigo.fixture.desktop",
    runID: UUID().uuidString.lowercased(),
    support: fixture.support,
    makeServices: { _ in services }
  )
  let shell = DesktopShell(composition: composition)
  var libraryOpened = 0
  shell.openLibrary = { _ in libraryOpened += 1 }
  await fixture.coordinator.shortcutPressed()
  shell.refreshReadiness()
  shell.showRecording()
  fixture.os.application.failsStop = stopFails
  await shell.finish()
  #expect(shell.recording.phase == .recoveryRequired)
  #expect(shell.recordingVisible)
  #expect(shell.recordingNotification == nil)
  #expect(!fixture.coordinator.canTerminateImmediately)
  fixture.os.application.failsStop = false
  await shell.retryRecovery()
  #expect(shell.recording.phase == .idle)
  #expect(shell.recording.finalization.isSettled)
  #expect(shell.recordingNotification?.isSaved == true)
  #expect(!shell.recordingVisible)
  #expect(libraryOpened == 0)
  #expect(fixture.coordinator.canTerminateImmediately)
}

@Test @MainActor func restartedPanelRetainsRecoveredDurationSourceAndSavedOutcome() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let session = try await CaptureArchiveSession.begin(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID,
    source: fixture.os.source,
    microphone: nil
  )
  let writer = try CaptureMediaWriter(session: session)
  try writer.append(interleaved: Array(repeating: Int16(123), count: 32_000))
  // No normal Finish occurred: restore must recover the real confirmed prefix.
  await fixture.bind()
  let services = LiveDesktopRecordingServices(coordinator: fixture.coordinator)
  let state = services.state
  #expect(state.phase == .interrupted)
  #expect(state.source == fixture.os.source)
  #expect(state.elapsedMs == 1000)
  #expect(state.finalization.callID == session.callID)
  #expect(state.finalization.localSave == .confirmed)
  #expect(state.finalization.captureStopped)
  #expect(!state.finalization.pendingNativeStart)
  #expect(state.statusDetail.contains("process ended"))
  #expect(state.statusDetail.contains("Audio is saved on this Mac."))
  #expect(state.levels == RecordedAudioLevels())
  #expect(!fixture.os.application.running)
  #expect(!fixture.os.microphone.running)
  let repository = try LocalRepository(
    root: fixture.namespace.archive,
    archiveID: session.archiveID
  )
  let completion = try #require(try repository.captureCompletion(callID: session.callID))
  #expect(completion.call.durationMs == 1000)
}

@Test(arguments: [
  CaptureStartFailure.unsupportedSource, .screenAudioPermission, .microphonePermission,
])
@MainActor func rejectedNewStartTakesPrecedenceOverRestoredInterruption(
  failure: CaptureStartFailure
) async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let session = try await CaptureArchiveSession.begin(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID,
    source: fixture.os.source,
    microphone: nil
  )
  let writer = try CaptureMediaWriter(session: session)
  try writer.append(interleaved: Array(repeating: Int16(123), count: 32_000))
  await fixture.bind()
  #expect(fixture.coordinator.phase == .interrupted)
  switch failure {
  case .unsupportedSource: fixture.os.frontmostFailure = failure
  case .screenAudioPermission: fixture.os.permissions = .init(screenAudio: false, microphone: true)
  case .microphonePermission: fixture.os.permissions = .init(screenAudio: true, microphone: false)
  default: Issue.record("Unexpected fixture failure")
  }
  await fixture.coordinator.shortcutPressed()
  let state = LiveDesktopRecordingServices(coordinator: fixture.coordinator).state
  #expect(state.phase == .error)
  #expect(state.notice?.message == fixture.coordinator.notice?.message)
  #expect(state.notice?.message.contains(failure.recoverySuggestion) == true)
  #expect(state.source == fixture.coordinator.pinnedSource)
  #expect(state.elapsedMs == 0)
  #expect(!state.canStop)
  #expect(!fixture.os.application.running)
  #expect(fixture.coordinator.recoveryReport.recoveredCallIDs == [session.callID])
  let repository = try LocalRepository(
    root: fixture.namespace.archive,
    archiveID: session.archiveID
  )
  #expect(try repository.captureCompletion(callID: session.callID)?.call.durationMs == 1000)
}

@Test @MainActor func liveInterruptedPanelRetainsCauseAndSavedDuration() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  await fixture.coordinator.stop(reason: "system_sleep")
  let state = LiveDesktopRecordingServices(coordinator: fixture.coordinator).state
  #expect(state.phase == .interrupted)
  #expect(state.statusDetail.contains("System sleep interrupted recording."))
  #expect(state.statusDetail.contains("Retained duration:"))
  #expect(state.statusDetail.contains("Audio is saved on this Mac."))
  #expect(state.finalization.localSave == .confirmed)
}
