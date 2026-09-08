import Foundation
import Testing

@testable import TrigoNative

@Test @MainActor func hiddenPanelNotifiesOncePerMicrophoneLossWithoutOpeningLibrary() throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  var opened = 0
  fixture.shell.openLibrary = { opened += 1 }
  fixture.services.state.phase = .recording
  fixture.services.state.canStart = false
  fixture.shell.hideRecording()
  fixture.services.state.microphoneNoticeSequence = 1
  fixture.services.state.microphoneUnavailableReason =
    "Microphone unavailable. Application audio continues."
  fixture.shell.refreshReadiness()
  let first = try #require(fixture.shell.recordingNotification)
  #expect(first.notice.title == "Microphone unavailable")
  #expect(!fixture.shell.recordingVisible)
  #expect(opened == 0)
  fixture.shell.refreshReadiness()
  #expect(fixture.shell.recordingNotification?.id == first.id)
  fixture.shell.dismissRecordingNotification(first.id)
  fixture.shell.refreshReadiness()
  #expect(fixture.shell.recordingNotification == nil)
  fixture.services.state.microphoneUnavailableReason = nil
  fixture.shell.refreshReadiness()
  fixture.services.state.microphoneNoticeSequence = 2
  fixture.services.state.microphoneUnavailableReason = "Input device disconnected."
  fixture.shell.refreshReadiness()
  #expect(fixture.shell.recordingNotification?.id != first.id)
  #expect(fixture.shell.recordingNotification?.notice.message == "Input device disconnected.")
  #expect(!fixture.shell.recordingVisible)
}

@Test @MainActor func recordingSavedAcknowledgementWaitsForEveryIndependentSafetyFact() throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  var opened = 0
  fixture.shell.openLibrary = { opened += 1 }
  fixture.services.state.phase = .stopping
  fixture.services.state.quitRequirement = .waitForSafety
  fixture.services.state.finalization.callID = "00000000-0000-4000-8000-000000000045"
  fixture.services.state.finalization.localSave = .confirmed
  fixture.services.state.finalization.captureStopped = false
  fixture.services.state.finalization.pendingNativeStart = true
  fixture.shell.showRecording()
  fixture.shell.refreshReadiness()
  #expect(fixture.shell.recordingNotification == nil)
  #expect(fixture.shell.recordingVisible)
  fixture.services.state.finalization.captureStopped = true
  fixture.shell.refreshReadiness()
  #expect(fixture.shell.recordingNotification == nil)
  fixture.shell.hideRecording()
  fixture.services.state.finalization.pendingNativeStart = false
  fixture.services.state.phase = .idle
  fixture.services.state.quitRequirement = .ready
  fixture.shell.refreshReadiness()
  let saved = try #require(fixture.shell.recordingNotification)
  #expect(saved.isSaved)
  #expect(saved.notice.title == "Recording saved")
  #expect(saved.notice.message.contains("transcription may still be pending"))
  #expect(!fixture.shell.recordingVisible)
  #expect(opened == 0)
  fixture.shell.dismissRecordingNotification(saved.id)
  fixture.shell.refreshReadiness()
  #expect(fixture.shell.recordingNotification == nil)
}

@Test func recordingRecoveryTextPreservesSavedAudioWhenNativeStopIsUnconfirmed() {
  var state = DesktopRecordingState()
  state.phase = .recoveryRequired
  state.finalization.callID = "00000000-0000-4000-8000-000000000045"
  state.finalization.captureStopped = false
  state.finalization.localSave = .confirmed
  #expect(state.statusTitle == "Cannot confirm recording has stopped")
  #expect(state.statusDetail.contains("Audio is saved on this Mac."))
  #expect(state.recoveryActionTitle == "Retry stopping")
  state.finalization.captureStopped = true
  state.finalization.localSave = .needsRecovery
  #expect(state.statusTitle == "Recording stopped; saving needs recovery")
  #expect(state.recoveryActionTitle == "Retry saving")
  #expect(!state.statusDetail.contains("Audio is saved on this Mac."))
  state.phase = .interrupted
  state.finalization.localSave = .confirmed
  state.notice = .init(title: "Recording interrupted", message: "The selected application exited.")
  #expect(state.statusDetail.contains("The selected application exited."))
  #expect(state.statusDetail.contains("Audio is saved on this Mac."))
}

@Test func panelPositionStaysOnAnExistingDisplayWithoutChangingItsAcceptedSize() {
  let left = CGRect(x: -1920, y: 40, width: 1920, height: 1000)
  let primary = CGRect(x: 0, y: 40, width: 1440, height: 860)
  let frame = CGRect(x: -1200, y: 800, width: 192, height: 44)
  #expect(RecordingPanelPlacement.clamp(frame, to: [left, primary]) == frame)
  let moved = RecordingPanelPlacement.clamp(frame, to: [primary])
  #expect(primary.contains(moved))
  #expect(moved.size == frame.size)
  let corner = CGRect(x: 1400, y: 895, width: 192, height: 44)
  #expect(
    RecordingPanelPlacement.clamp(corner, to: [primary])
      == CGRect(x: 1248, y: 856, width: 192, height: 44)
  )
  let invalid = CGRect(x: Double.nan, y: 0, width: 192, height: 44)
  #expect(primary.contains(RecordingPanelPlacement.clamp(invalid, to: [primary])))
}

@Test @MainActor func microphoneLossNotificationsFollowActualAvailabilityTransitions() async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  fixture.os.microphoneDevice = nil
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.coordinator.microphoneNoticeSequence == 1)
  #expect(fixture.coordinator.microphoneState == .unavailable)
  #expect(
    fixture.coordinator.microphoneUnavailableReason?.contains("Application audio continues") == true
  )
  for _ in 0..<3 { await fixture.capture.checkSourceAndMicrophone() }
  #expect(fixture.coordinator.microphoneNoticeSequence == 1)
  fixture.os.microphoneDevice = .init(id: "returned", name: "Returned")
  await fixture.capture.checkSourceAndMicrophone()
  await fixture.coordinator.toggleMicrophone()
  #expect(!fixture.coordinator.microphoneRecordingEnabled)
  fixture.os.microphoneDevice = nil
  await fixture.capture.checkSourceAndMicrophone()
  #expect(fixture.coordinator.microphoneNoticeSequence == 2)
  #expect(fixture.os.application.running)
  fixture.os.microphoneDevice = .init(id: "returned-again", name: "Returned again")
  await fixture.capture.checkSourceAndMicrophone()
  #expect(fixture.coordinator.microphoneState == .muted)
  #expect(fixture.coordinator.microphoneUnavailableReason == nil)
  await fixture.coordinator.stop()
}
