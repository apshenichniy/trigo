import Foundation
import Testing

@testable import TrigoNative

@Test @MainActor func shortcutCancelsPendingStartWithoutAcknowledgingRecordingOrAdmittingOverlap()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  fixture.os.application.suspendStart = true
  let attempt = Task { await fixture.coordinator.shortcutPressed() }
  await fixture.os.application.waitForStart()
  #expect(fixture.coordinator.phase == .starting)
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.coordinator.phase == .stopping)
  await fixture.coordinator.startPinnedSource()
  #expect(fixture.coordinator.phase == .stopping)
  fixture.os.application.finishStart()
  await attempt.value
  #expect(fixture.coordinator.phase == .idle)
  #expect(!fixture.os.application.running)
}

@Test @MainActor func terminationWaitsForThePendingOSStartToRetire() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  fixture.os.application.suspendStart = true
  let attempt = Task { await fixture.coordinator.shortcutPressed() }
  await fixture.os.application.waitForStart()
  var terminationCompleted = false
  let termination = Task {
    let result = await fixture.coordinator.prepareForTermination()
    terminationCompleted = true
    return result
  }
  // The coordinator exposes cancellation before the platform is allowed to quit.
  for _ in 0..<10_000 {
    if fixture.coordinator.phase == .stopping { break }
    await Task.yield()
  }
  #expect(fixture.coordinator.phase == .stopping)
  #expect(!terminationCompleted)
  fixture.os.application.finishStart()
  #expect(await termination.value)
  await attempt.value
  #expect(!fixture.os.application.running)
  #expect(fixture.coordinator.phase == .interrupted)
  #expect(fixture.coordinator.recordingSnapshot?.interruptionReason == "application_termination")
}

@Test @MainActor func restoredLocalBindingCanRecordWhileServerHealthIsStillPending() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  let fresh = RecordingCoordinator(
    connection: fixture.connection, namespace: fixture.namespace,
    capture: fixture.capture,
    sources: .init(
      permissions: { fixture.os.permissions },
      frontmost: fixture.os.frontmost, requestPermissions: { fixture.os.permissions }))
  await fixture.status.holdNextFetch()
  let restoration = Task { await fresh.restore() }
  await fixture.status.waitForHeldFetch()
  #expect(fresh.isConnecting)
  #expect(fresh.connectionSnapshot.health == .checking)
  #expect(fresh.canStart)
  await fresh.shortcutPressed()
  #expect(fresh.phase == .recording)
  await fresh.stop()
  await fixture.status.releaseFetch()
  await restoration.value
}

@Test @MainActor func stalePinnedSourceCannotFallBackToThePanelOrAnotherApplication() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  await fixture.coordinator.stop()
  let pinned = fixture.coordinator.pinnedSource
  fixture.os.filterFailure = .sourceExited
  let reads = fixture.os.frontmostReads
  await fixture.coordinator.startPinnedSource()
  #expect(fixture.coordinator.phase == .error)
  #expect(fixture.coordinator.pinnedSource == pinned)
  #expect(fixture.os.frontmostReads == reads)
  #expect(!fixture.os.application.running)
  #expect(fixture.coordinator.notice?.message.contains("no longer running") == true)
}

@Test @MainActor func sourceExitIsShownAsAnInterruptedCallWithActionableRecovery() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  fixture.os.sourceAvailable = false
  for _ in 0..<300 {
    if fixture.coordinator.notice != nil { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(fixture.coordinator.phase == .interrupted)
  #expect(fixture.coordinator.recordingSnapshot?.interruptionReason == "source_exited")
  #expect(fixture.coordinator.notice?.message.contains("Focus") == true)
  #expect(!fixture.os.application.running)
  await fixture.coordinator.stop()
}

@Test @MainActor func initialPermissionGrantRequiresReselectingTheTargetWithoutCapturingThePrompt()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  fixture.os.frontmostFailure = .screenAudioPermission
  fixture.os.permissions = .init(screenAudio: false, microphone: false)
  fixture.os.onPermissionRequest = {
    fixture.os.permissions = .init(screenAudio: true, microphone: true)
  }
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.os.permissionRequests == 1)
  #expect(fixture.os.frontmostReads == 0)
  #expect(fixture.coordinator.notice?.message.contains("Focus") == true)
  #expect(fixture.coordinator.callID == nil)
  #expect(!fixture.os.application.running)
  fixture.os.frontmostFailure = nil
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.coordinator.phase == .recording)
  await fixture.coordinator.stop()
}

@Test @MainActor func panelDoesNotSelectItselfAndShortcutPinsBeforeAsyncCaptureValidation()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.startPinnedSource()
  #expect(fixture.coordinator.notice?.message.contains("Focus") == true)
  #expect(fixture.os.permissionRequests == 0)
  let expected = fixture.os.source
  fixture.os.onFilter = {
    fixture.os.source = .init(
      applicationName: "Permission prompt", bundleID: "test.prompt", processID: 999,
      windowID: 999, windowTitle: nil, processLaunchDate: expected.processLaunchDate)
  }
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.coordinator.phase == .recording)
  #expect(fixture.coordinator.pinnedSource == expected)
  #expect(fixture.os.permissionRequests == 0)
  await fixture.coordinator.stop()
  // A panel Start intentionally reuses the pinned source, never the current panel/frontmost app.
  await fixture.coordinator.startPinnedSource()
  #expect(fixture.coordinator.pinnedSource == expected)
  #expect(fixture.coordinator.phase == .recording)
  await fixture.coordinator.stop()
}

@Test(arguments: [false, true]) @MainActor
func permissionDenialNeverSnapshotsOrStartsAndRetainsActionableSettingsHelp(screenGranted: Bool)
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  fixture.os.permissions = .init(screenAudio: screenGranted, microphone: false)
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.os.permissionRequests == 1)
  #expect(fixture.os.frontmostReads == 0)
  #expect(fixture.coordinator.callID == nil)
  #expect(fixture.coordinator.notice?.message.contains("System Settings") == true)
  #expect(!fixture.os.application.running)
}
