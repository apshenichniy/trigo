import Testing

@testable import TrigoNative

@Test @MainActor func revokedMicrophoneAccessRetiresInputWithoutRepeatedNativeStarts() async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  let starts = fixture.os.microphone.startCalls
  fixture.os.permissions = .init(
    screenAudio: true, microphoneAuthorization: .denied,
    microphoneAvailable: true)
  for _ in 0..<3 { await fixture.capture.checkSourceAndMicrophone() }
  #expect(fixture.coordinator.phase == .recording)
  #expect(fixture.os.application.running)
  #expect(!fixture.os.microphone.running)
  #expect(fixture.coordinator.microphoneState == .unavailable)
  #expect(fixture.coordinator.capturePermissions.microphoneAuthorization == .denied)
  #expect(fixture.coordinator.capturePermissions.microphoneAvailable)
  #expect(fixture.coordinator.notice?.message.contains("Microphone settings") == true)
  #expect(fixture.os.microphone.startCalls == starts)
  #expect(fixture.os.permissionRequests == 0)
  fixture.os.permissions = .init(screenAudio: true, microphone: true)
  await fixture.capture.checkSourceAndMicrophone()
  #expect(fixture.coordinator.microphoneState == .recording)
  #expect(fixture.os.microphone.startCalls == starts + 1)
  await fixture.coordinator.stop()
}

@Test @MainActor func revokedScreenAudioAccessInterruptsWithSettingsRecovery() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  fixture.os.permissions = .init(screenAudio: false, microphone: true)
  await fixture.capture.checkSourceAndMicrophone()
  #expect(fixture.coordinator.phase == .interrupted)
  #expect(fixture.coordinator.recordingSnapshot?.interruptionReason == "screen_audio_permission")
  #expect(fixture.coordinator.notice?.message.contains("System Settings") == true)
  #expect(!fixture.coordinator.capturePermissions.screenAudio)
  #expect(!fixture.os.application.running)
  #expect(fixture.os.permissionRequests == 0)
  await fixture.coordinator.stop()
}

@Test(arguments: [false, true]) @MainActor
func microphoneStartIsNotPublishedBeforeNativeAcknowledgement(failsAfterStart: Bool) async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  fixture.os.microphone.suspendStart = true
  let start = Task { await fixture.coordinator.shortcutPressed() }
  await fixture.os.microphone.waitForStart()
  #expect(fixture.coordinator.phase == .starting)
  #expect(fixture.coordinator.microphoneState == .starting)
  #expect(fixture.coordinator.recordingSnapshot?.microphone == nil)
  #expect(fixture.capture.snapshot?.microphone == nil)
  fixture.os.microphone.failsAfterStart = failsAfterStart
  fixture.os.microphone.finishStart()
  await start.value
  #expect(fixture.coordinator.phase == .recording)
  #expect(fixture.coordinator.microphoneState == (failsAfterStart ? .unavailable : .recording))
  #expect(fixture.os.application.running)
  await fixture.coordinator.stop()
}

@Test @MainActor func microphoneControlAcknowledgesOnlyTheCompletedAudioQueueChangeAndRejectsRaces()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.coordinator.microphoneState == .recording)
  fixture.os.audioQueue.suspend()
  let toggle = Task { await fixture.coordinator.toggleMicrophone() }
  for _ in 0..<10_000 {
    if fixture.coordinator.isMicrophoneChanging { break }
    await Task.yield()
  }
  #expect(fixture.coordinator.isMicrophoneChanging)
  #expect(fixture.coordinator.microphoneRecordingEnabled)
  #expect(fixture.coordinator.microphoneState == .recording)
  await fixture.coordinator.toggleMicrophone()
  fixture.os.audioQueue.resume()
  await toggle.value
  #expect(!fixture.coordinator.isMicrophoneChanging)
  #expect(!fixture.coordinator.microphoneRecordingEnabled)
  #expect(fixture.coordinator.microphoneState == .muted)
  #expect(fixture.os.application.running)
  await fixture.coordinator.stop()
  await fixture.coordinator.startPinnedSource()
  #expect(fixture.coordinator.microphoneRecordingEnabled)
  #expect(fixture.coordinator.microphoneState == .recording)
  await fixture.coordinator.stop()
}

@Test(arguments: [false, true]) @MainActor
func unavailableMicrophoneIsNotReportedAsMutedAndDoesNotStopApplicationAudio(streamFails: Bool)
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  if streamFails {
    fixture.os.microphone.failsStart = true
  } else {
    fixture.os.microphoneDevice = nil
  }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.coordinator.microphoneState == .unavailable)
  if streamFails {
    #expect(fixture.coordinator.notice?.message.contains("Application audio continues") == true)
    #expect(fixture.coordinator.notice?.message.contains("check or connect") == true)
  }
  await fixture.coordinator.toggleMicrophone()
  #expect(!fixture.coordinator.microphoneRecordingEnabled)
  #expect(fixture.coordinator.microphoneState == .unavailable)
  #expect(fixture.coordinator.phase == .recording)
  #expect(fixture.os.application.running)
  if streamFails {
    fixture.os.microphone.failsStart = false
    for _ in 0..<300 {
      if fixture.coordinator.recordingSnapshot?.microphone != nil { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(fixture.coordinator.microphoneState == .muted)
    #expect(!fixture.coordinator.microphoneRecordingEnabled)
    #expect(fixture.coordinator.notice == nil)
  }
  await fixture.coordinator.stop()
}
