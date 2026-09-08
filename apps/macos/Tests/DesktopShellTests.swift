import AppKit
import Carbon
import Foundation
import Testing

@testable import TrigoNative

@Test @MainActor func desktopBackgroundBootstrapIsOnceAndIndependentOfEveryWindow() async throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  let gate = DesktopGate()
  fixture.services.restoreGate = gate
  var opened = 0
  fixture.shell.openLibrary = { opened += 1 }
  fixture.shell.openSettings = { opened += 10 }
  fixture.shell.launch(.background)
  fixture.shell.launch(.background)
  await gate.waitUntilEntered()
  #expect(fixture.services.restoreCount == 1)
  #expect(opened == 0)
  #expect(!fixture.shell.recordingVisible)
  #expect(!fixture.shell.didBootstrap)
  #expect(fixture.services.startCount == 0)
  fixture.shell.reopen()
  #expect(opened == 1)
  gate.release()
  await fixture.shell.bootstrap().value
  #expect(fixture.shell.didBootstrap)
  #expect(fixture.services.restoreCount == 1)
  #expect(fixture.services.startCount == 0)
}

@Test @MainActor func desktopExplicitLaunchRevealsLibraryWithoutStartingCapture() async throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  var opened = 0
  fixture.shell.openLibrary = { opened += 1 }
  fixture.shell.launch(.explicit)
  await fixture.shell.bootstrap().value
  #expect(opened == 1)
  #expect(fixture.services.startCount == 0)
}

@Test @MainActor func desktopMenuPinsTheSourceBeforePresentationAndDoesNotReadItAgain() throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  let source = fixture.services.frontmost
  fixture.services.onSelect = { [weak shell = fixture.shell] in
    #expect(shell?.recordingVisible == false)
  }
  fixture.shell.menuWillOpen()
  fixture.services.frontmost = .init(
    applicationName: "Trigo",
    bundleID: "test.trigo",
    processID: 999,
    windowID: 999,
    windowTitle: "Settings",
    processLaunchDate: Date()
  )
  fixture.shell.startOrReveal(from: .menu)
  #expect(try fixture.services.selected?.get() == source)
  #expect(fixture.services.selectionCount == 1)
  #expect(fixture.shell.recordingVisible)
  #expect(fixture.services.startCount == 1)
  #expect(fixture.services.finishCount == 0)
}

@Test @MainActor func desktopKeyboardSelectsSynchronouslyAndRepeatedIntentOnlyReveals() throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  fixture.services.onSelect = { [weak shell = fixture.shell] in
    #expect(shell?.recordingVisible == false)
  }
  fixture.shell.startOrReveal(from: .keyboard)
  fixture.shell.hideRecording()
  fixture.shell.startOrReveal(from: .keyboard)
  #expect(fixture.shell.recordingVisible)
  #expect(fixture.services.selectionCount == 1)
  #expect(fixture.services.startCount == 1)
  #expect(fixture.services.finishCount == 0)
}

@Test(arguments: [RecordingControlPhase.starting, .recording, .stopping, .recoveryRequired])
@MainActor
func desktopBusyMenuIntentNeverQueuesAStartAfterTheOperationSettles(
  phase: RecordingControlPhase
) throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  fixture.services.state.phase = phase
  fixture.services.state.canStart = false
  fixture.shell.menuWillOpen()
  // The native menu is still tracking when the pending operation completes.
  fixture.services.state.phase = .idle
  fixture.services.state.canStart = true
  fixture.shell.startOrReveal(from: .menu)
  #expect(fixture.services.startCount == 0)
  #expect(fixture.services.selectionCount == 0)
  #expect(fixture.shell.recordingVisible)
}

@Test @MainActor func desktopLibraryPresenceFollowsExistenceAndReusesItsNativeWindow() {
  var actions: [String] = []
  let lifecycle = DesktopLibraryLifecycle(
    setDockPresence: { actions.append($0 ? "regular" : "accessory") },
    create: { actions.append("create") },
    reveal: { actions.append("reveal") },
    activate: { actions.append("activate") }
  )
  #expect(!lifecycle.isOpen)
  lifecycle.open()
  // Minimize/fullscreen/occlusion do not close a library; reopening uses the same handle.
  lifecycle.open()
  #expect(lifecycle.isOpen)
  #expect(actions == ["regular", "create", "reveal", "activate", "reveal", "activate"])
  lifecycle.closed()
  #expect(!lifecycle.isOpen)
  #expect(actions.last == "accessory")
  lifecycle.open()
  #expect(actions.suffix(4) == ["regular", "create", "reveal", "activate"])
}

@Test @MainActor func desktopSettingsAndRecordingPresentationDoNotCreateLibraryPresence() throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  var openedLibrary = false
  var settings = 0
  fixture.shell.openLibrary = { openedLibrary = true }
  fixture.shell.openSettings = { settings += 1 }
  fixture.shell.showSettings(.diagnostics)
  fixture.shell.showRecording()
  fixture.shell.hideRecording()
  #expect(!openedLibrary)
  #expect(settings == 1)
  #expect(fixture.shell.settingsSection == .diagnostics)
  #expect(fixture.services.selectionCount == 0)
}

@Test @MainActor func desktopIdleQuitDoesNotConfirmOrRunAnUnnecessaryStop() throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  let result = fixture.shell.requestQuit(
    confirmFinish: {
      Issue.record("Unexpected confirmation"); return false
    },
    reply: { _ in Issue.record("Unexpected reply") }
  )
  #expect(result == .now)
  #expect(fixture.services.terminationCount == 0)
  fixture.shell.startOrReveal(from: .keyboard)
  #expect(fixture.services.startCount == 0)
}

@Test @MainActor func desktopLiveSourceAdmissionPinsBeforeAsyncWorkAndClearsAnInvalidFreshSource()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  let service = LiveDesktopRecordingServices(coordinator: fixture.coordinator)
  #expect(service.state.quitRequirement == .ready)
  let selected = service.selectSource()
  let start = try #require(fixture.coordinator.startSelectedSource(selected))
  #expect(fixture.coordinator.pinnedSource == fixture.os.source)
  #expect(fixture.coordinator.phase == .starting)
  #expect(service.state.quitRequirement == .confirmFinish)
  await fixture.coordinator.shortcutPressed()
  await start.value
  #expect(fixture.coordinator.phase == .recording)
  #expect(fixture.os.application.startCalls == 1)
  await service.finish()
  #expect(service.state.quitRequirement == .ready)
  fixture.os.frontmostFailure = .unsupportedSource
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.coordinator.pinnedSource == nil)
  #expect(fixture.coordinator.phase == .error)
  #expect(fixture.os.application.startCalls == 1)
  #expect(fixture.coordinator.notice?.message.contains("Focus") == true)
}

@Test(arguments: [RecordingControlPhase.starting, .recording]) @MainActor
func desktopQuitCanBeDeclinedWithoutStoppingTheCall(phase: RecordingControlPhase) async throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  fixture.services.state.phase = phase
  fixture.services.state.quitRequirement = .confirmFinish
  let confirmation = DesktopGate()
  var confirmations = 0
  let result = await withCheckedContinuation { reply in
    let routing = fixture.shell.requestQuit(
      confirmFinish: {
        confirmations += 1
        await confirmation.wait()
        return false
      },
      reply: { reply.resume(returning: $0) }
    )
    #expect(routing == .later)
    Task { @MainActor in
      await confirmation.waitUntilEntered()
      fixture.shell.startOrReveal(from: .keyboard)
      #expect(fixture.services.startCount == 0)
      let duplicate = fixture.shell.requestQuit(
        confirmFinish: {
          Issue.record("Duplicate confirmation"); return true
        },
        reply: { _ in Issue.record("Duplicate reply") }
      )
      #expect(duplicate == .later)
      confirmation.release()
    }
  }
  #expect(!result)
  #expect(confirmations == 1)
  #expect(fixture.services.terminationCount == 0)
  #expect(!fixture.shell.isQuitting)
}

@Test(arguments: [DesktopQuitRequirement.confirmFinish, .waitForSafety]) @MainActor
func desktopQuitWaitsForTheSafetyAuthorityAndKeepsRecoveryReachable(
  requirement: DesktopQuitRequirement
) async throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  fixture.services.state.quitRequirement = requirement
  fixture.services.state.phase = requirement == .confirmFinish ? .recording : .stopping
  let safety = DesktopGate()
  fixture.services.terminationGate = safety
  var confirmations = 0
  var replied = false
  let result = await withCheckedContinuation { reply in
    #expect(
      fixture.shell.requestQuit(
        confirmFinish: {
          confirmations += 1; return true
        },
        reply: {
          replied = true
          reply.resume(returning: $0)
        }
      ) == .later
    )
    Task { @MainActor in
      await safety.waitUntilEntered()
      #expect(!replied)
      #expect(fixture.shell.isQuitting)
      #expect(fixture.services.terminationCount == 1)
      safety.release()
    }
  }
  #expect(!result)
  #expect(confirmations == (requirement == .confirmFinish ? 1 : 0))
  #expect(fixture.shell.recordingVisible)
  #expect(!fixture.shell.isQuitting)
  #expect(fixture.shell.recording.phase == .recoveryRequired)
  fixture.services.terminationGate = nil
  fixture.services.terminationSafe = true
  let recovered = await withCheckedContinuation { reply in
    #expect(
      fixture.shell.requestQuit(
        confirmFinish: {
          Issue.record("Recovery must not reconfirm"); return false
        },
        reply: { reply.resume(returning: $0) }
      ) == .later
    )
  }
  #expect(recovered)
  #expect(fixture.services.terminationCount == 2)
}

@Test @MainActor func desktopLaunchClassificationPreservesLoginAndBackgroundDefaults() {
  #expect(DesktopLaunchReason.resolve(arguments: ["Trigo"], appleEvent: nil) == .explicit)
  #expect(
    DesktopLaunchReason.resolve(arguments: ["Trigo", "--background"], appleEvent: nil)
      == .background
  )
  #expect(
    DesktopLaunchReason.resolve(arguments: ["Trigo"], appleEvent: nil, isDefaultLaunch: false)
      == .background
  )
  for reason in [keyAELaunchedAsLogInItem, keyAELaunchedAsServiceItem] {
    let event = NSAppleEventDescriptor(
      eventClass: kCoreEventClass,
      eventID: kAEOpenApplication,
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: keyAEPropData)
    #expect(DesktopLaunchReason.resolve(arguments: ["Trigo"], appleEvent: event) == .background)
  }
}

@Test @MainActor func desktopBackgroundRecoverySurfacesFailureWithoutClearingItsGuardOnHide()
  async throws
{
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  fixture.services.state.isRecovering = true
  fixture.services.state.phase = .recoveryRequired
  fixture.services.state.canStart = false
  fixture.services.state.quitRequirement = .waitForSafety
  fixture.shell.launch(.background)
  await fixture.shell.bootstrap().value
  #expect(!fixture.shell.recordingVisible)
  fixture.services.state.isRecovering = false
  fixture.shell.refreshReadiness()
  #expect(fixture.shell.recordingVisible)
  fixture.shell.hideRecording()
  #expect(!fixture.shell.recording.canStart)
  fixture.shell.startOrReveal(from: .keyboard)
  #expect(fixture.services.startCount == 0)
  #expect(fixture.shell.recordingVisible)
}

@Test @MainActor func desktopConnectionMetadataRecoveryKeepsItsActionableReason() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.metadata.setLoadFailure(true)
  let service = LiveDesktopRecordingServices(coordinator: fixture.coordinator)
  await service.restore()
  #expect(service.state.phase == .recoveryRequired)
  #expect(service.state.notice?.title == ConnectionIssue.persistence.title)
  #expect(service.state.notice?.message == ConnectionIssue.persistence.recoverySuggestion)
  #expect(!service.state.canStart)
}
