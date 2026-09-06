import Testing

@testable import TrigoNative

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
