import Carbon.HIToolbox
import CoreGraphics
import Foundation
import IOKit.hidsystem
import Testing

@testable import TrigoNative

private func control(_ down: Bool, _ milliseconds: UInt64) -> RecordingGestureInput {
  .init(kind: .leftControl(down), timestamp: milliseconds * 1_000_000, neutral: !down)
}

private func assertGesture(
  _ recognizer: inout LeftControlGesture,
  _ input: RecordingGestureInput,
  _ expected: Bool = false
) {
  let actual = recognizer.consume(input)
  #expect(actual == expected)
}

@Test func gestureTriggersExactlyOnSecondReleaseAndDoesNotOverlapPairs() {
  var recognizer = LeftControlGesture()
  for base in [UInt64(0), 500] {
    assertGesture(&recognizer, control(true, base))
    assertGesture(&recognizer, control(false, base + 100))
    assertGesture(&recognizer, .init(kind: .pointerMovement, timestamp: 0, neutral: true))
    assertGesture(&recognizer, control(true, base + 200))
    assertGesture(&recognizer, control(false, base + 300), true)
  }
}

@Test(arguments: [
  [UInt64(0), 251, 350, 450],
  [UInt64(0), 100, 451, 551],
  [UInt64(0), 100, 200, 451],
  [UInt64(100), 100, 200, 300],
  [UInt64(100), 50, 200, 300],
]) func gestureRejectsHeldSlowDuplicateAndOutOfOrderTraces(times: [UInt64]) {
  var recognizer = LeftControlGesture()
  for (index, time) in times.enumerated() {
    assertGesture(&recognizer, control(index % 2 == 0, time))
  }
}

@Test func gestureTimingBoundsAreInclusiveAndDuplicateTransitionsCancel() {
  var recognizer = LeftControlGesture()
  assertGesture(&recognizer, control(true, 0))
  assertGesture(&recognizer, control(false, 250))
  assertGesture(&recognizer, control(true, 600))
  assertGesture(&recognizer, control(false, 850), true)
  for down in [true, false] {
    recognizer.reset()
    assertGesture(&recognizer, control(true, 1000))
    if !down { assertGesture(&recognizer, control(false, 1050)) }
    assertGesture(&recognizer, control(down, 1100))
    assertGesture(&recognizer, control(true, 1150))
    assertGesture(&recognizer, control(false, 1200))
  }
}

@Test(arguments: [
  CGEventType.keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
  .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
  .scrollWheel,
]) func gestureOtherInputCancelsAndDecodingLeavesTheEventUntouched(type: CGEventType) throws {
  var recognizer = LeftControlGesture()
  assertGesture(&recognizer, control(true, 0))
  assertGesture(&recognizer, control(false, 100))
  let event = try #require(CGEvent(source: nil))
  event.type = type
  event.timestamp = 150_000_000
  event.flags = []
  let bytes = event.data
  assertGesture(&recognizer, .decode(type: type, event: event))
  assertGesture(&recognizer, control(true, 200))
  assertGesture(&recognizer, control(false, 300))
  #expect(event.data == bytes)
}

@Test(arguments: [
  (kVK_RightControl, UInt64(CGEventFlags.maskControl.rawValue) | UInt64(NX_DEVICERCTLKEYMASK)),
  (kVK_Control, UInt64(CGEventFlags.maskControl.rawValue)),
  (
    kVK_Control,
    UInt64(CGEventFlags.maskControl.rawValue | CGEventFlags.maskShift.rawValue)
      | UInt64(NX_DEVICELCTLKEYMASK)
  ),
  (
    kVK_Control,
    UInt64(CGEventFlags.maskControl.rawValue) | UInt64(NX_DEVICELCTLKEYMASK | NX_DEVICERCTLKEYMASK)
  ),
  (kVK_CapsLock, UInt64(CGEventFlags.maskAlphaShift.rawValue)),
  (kVK_Option, UInt64(CGEventFlags.maskAlternate.rawValue)),
  (kVK_Command, UInt64(CGEventFlags.maskCommand.rawValue)),
  (kVK_Function, UInt64(CGEventFlags.maskSecondaryFn.rawValue)),
]) func gestureRequiresPublicLeftIdentityAndNeutralOtherModifiers(key: Int, flags: UInt64) throws {
  let event = try #require(
    CGEvent(keyboardEventSource: nil, virtualKey: UInt16(key), keyDown: true)
  )
  event.type = .flagsChanged
  #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(key))
  event.flags = .init(rawValue: flags)
  let decoded = RecordingGestureInput.decode(type: .flagsChanged, event: event)
  guard case .cancellation = decoded.kind else {
    Issue.record("Accepted a mixed or right-side event"); return
  }
  #expect(!decoded.neutral)
}

@Test func gestureDecodesBothLeftEdgesAndRequiresNeutralAfterAnInterruptedPress() throws {
  var recognizer = LeftControlGesture()
  recognizer.reset(neutral: false)
  assertGesture(&recognizer, control(true, 0))
  assertGesture(&recognizer, control(false, 100))
  for (offset, down) in [true, false, true, false].enumerated() {
    let event = try #require(
      CGEvent(keyboardEventSource: nil, virtualKey: UInt16(kVK_Control), keyDown: down)
    )
    event.type = .flagsChanged
    #expect(event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Control))
    event.timestamp = UInt64(offset + 2) * 100_000_000
    event.flags =
      down ? .init(rawValue: CGEventFlags.maskControl.rawValue | UInt64(NX_DEVICELCTLKEYMASK)) : []
    assertGesture(&recognizer, .decode(type: .flagsChanged, event: event), offset == 3)
  }
}

@MainActor final class GestureFixture {
  var preferences = RecordingGesturePreferences(enabled: true)
  var environment = RecordingGestureEnvironment(
    permission: true,
    secureInput: false,
    sessionActive: true,
    neutral: true
  )
  var requested = 0
  var settingsOpened = 0
  var owner = false
  var ownershipBlocked = false
  var tapUnavailable = false
  var cancellations = 0
  var callbacks: [@MainActor (RecordingGestureSignal) -> Void] = []
  var observations: [@MainActor (RecordingGestureLifecycle) -> Void] = []
  var time: UInt64 = 0

  var system: RecordingGestureSystem {
    .init(
      loadPreferences: { self.preferences },
      savePreferences: { self.preferences = $0 },
      environment: { self.environment },
      requestPermission: { self.requested += 1 },
      openSettings: { self.settingsOpened += 1 },
      acquireOwnership: {
        guard !self.owner, !self.ownershipBlocked else {
          throw ExclusiveFileLeaseError.alreadyOwned
        }
        self.owner = true
        return RecordingShortcutLease { self.owner = false }
      },
      listen: {
        if self.tapUnavailable { throw RecordingGestureTapError.unavailable }
        self.callbacks.append($0)
        return RecordingShortcutLease { self.cancellations += 1 }
      },
      observe: {
        self.observations.append($0)
        return RecordingShortcutLease {}
      }
    )
  }
  func tap(callback: Int? = nil) {
    for down in [true, false] {
      time += 50
      callbacks[callback ?? callbacks.count - 1](.input(control(down, time)))
    }
  }
}

@Test @MainActor func gesturePermissionSetupIsExplicitAndRevocationKeepsFallbackIndependent() {
  let fixture = GestureFixture()
  fixture.preferences.enabled = false
  fixture.environment.permission = false
  var fallback: (@MainActor () -> Void)?
  var actions = 0
  let shortcut = GlobalRecordingShortcut(
    system: .init(register: { callback in
      fallback = callback; return RecordingShortcutLease {}
    }),
    gestureSystem: fixture.system,
    action: { actions += 1 }
  )
  shortcut.register()
  #expect(shortcut.isRegistered)
  #expect(shortcut.gesture.status == .disabled)
  #expect(fixture.requested == 0)
  shortcut.gesture.enable()
  #expect(fixture.requested == 1)
  #expect(shortcut.gesture.status == .denied)
  shortcut.gesture.refresh()
  shortcut.register()
  #expect(fixture.requested == 1)
  fallback?()
  #expect(actions == 1)
  fixture.environment.permission = true
  shortcut.gesture.refresh()
  fixture.tap()
  fixture.environment.permission = false
  fixture.tap()
  #expect(shortcut.gesture.status == .revoked)
  #expect(!fixture.owner)
  #expect(actions == 1)
  #expect(shortcut.isRegistered)
  shortcut.gesture.openSettings()
  #expect(fixture.settingsOpened == 1)
  fixture.environment.permission = true
  shortcut.gesture.refresh()
  fixture.tap()
  #expect(actions == 1)
  fixture.tap()
  #expect(actions == 2)
  shortcut.unregister()
}

@Test(arguments: [RecordingGestureLifecycle.willSleep, .didWake, .sessionInactive, .sessionActive])
@MainActor func gestureLifecycleResetsCandidatesAndFencesRetiredListeners(
  event: RecordingGestureLifecycle
) {
  let fixture = GestureFixture()
  var actions = 0
  let gesture = RecordingGestureController(system: fixture.system, action: { actions += 1 })
  gesture.start()
  fixture.tap()
  fixture.observations[0](event)
  if event == .willSleep { fixture.observations[0](.didWake) }
  if event == .sessionInactive { fixture.observations[0](.sessionActive) }
  fixture.tap(callback: 0)
  fixture.tap(callback: 0)
  #expect(actions == 0)
  fixture.tap()
  #expect(actions == 0)
  fixture.tap()
  #expect(actions == 1)
  gesture.stop()
}

@Test @MainActor func gestureSecureInputDisabledTapAndUnavailableLeaseDiscardPartialInput() {
  let fixture = GestureFixture()
  var actions = 0
  let gesture = RecordingGestureController(system: fixture.system, action: { actions += 1 })
  gesture.start()
  for interruption in 0..<3 {
    fixture.tap()
    let old = fixture.callbacks.count - 1
    switch interruption {
    case 0:
      fixture.environment.secureInput = true
      fixture.tap()
      #expect(gesture.status == .secureInput)
      fixture.environment.secureInput = false
    case 1: fixture.callbacks[old](.tapDisabled)
    default:
      gesture.disable()
      fixture.ownershipBlocked = true
      gesture.enable()
      #expect(gesture.status == .anotherTrigoOwner)
      fixture.ownershipBlocked = false
    }
    #expect(!fixture.owner)
    gesture.refresh()
    fixture.tap(callback: old)
    fixture.tap()
    #expect(actions == interruption)
    fixture.tap()
    #expect(actions == interruption + 1)
  }
  gesture.stop()
  fixture.tap()
  #expect(actions == 3)
  fixture.tapUnavailable = true
  gesture.start()
  #expect(gesture.status == .unavailable)
  #expect(!fixture.owner)
  gesture.stop()
}

@Test @MainActor func gestureOwnerTransferIsExclusiveAndDoesNotReplayAnOldCandidate() {
  let fixture = GestureFixture()
  var firstActions = 0
  var secondActions = 0
  let first = RecordingGestureController(system: fixture.system, action: { firstActions += 1 })
  let second = RecordingGestureController(system: fixture.system, action: { secondActions += 1 })
  first.start()
  second.start()
  #expect(second.status == .anotherTrigoOwner)
  fixture.tap()
  first.disable()
  second.refresh()
  #expect(second.status == .available)
  fixture.tap(callback: 0)
  fixture.tap()
  #expect(firstActions == 0 && secondActions == 0)
  fixture.tap()
  #expect(secondActions == 1)
  second.stop()
  first.stop()
}

@Test @MainActor func gestureRestartDoesNotKeepOldSessionFlagsOrObservers() {
  let fixture = GestureFixture()
  var actions = 0
  let gesture = RecordingGestureController(system: fixture.system, action: { actions += 1 })
  gesture.start()
  fixture.observations[0](.willSleep)
  #expect(gesture.status == .sessionInactive)
  gesture.stop()
  gesture.start()
  #expect(gesture.status == .available)
  fixture.observations[0](.willSleep)
  #expect(gesture.status == .available)
  fixture.tap()
  fixture.tap()
  #expect(actions == 1)
  gesture.stop()
}

@Test @MainActor func gestureControllersShareARealKernelLeaseAcrossSeparatePreferences() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-gesture-owner-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let first = GestureFixture()
  let second = GestureFixture()
  var firstSystem = first.system
  var secondSystem = second.system
  firstSystem.acquireOwnership = { try acquireRecordingGestureOwnership(support: root) }
  secondSystem.acquireOwnership = { try acquireRecordingGestureOwnership(support: root) }
  var actions = 0
  let dev = RecordingGestureController(system: firstSystem, action: { actions += 1 })
  let personal = RecordingGestureController(system: secondSystem, action: { actions += 10 })
  dev.start()
  personal.start()
  #expect(dev.status == .available)
  #expect(personal.status == .anotherTrigoOwner)
  first.tap()
  dev.stop()
  personal.refresh()
  #expect(personal.status == .available)
  first.tap()
  second.tap()
  #expect(actions == 0)
  second.tap()
  #expect(actions == 10)
  personal.stop()
}

@Test(arguments: [RecordingControlPhase.starting, .recording, .stopping, .recoveryRequired])
@MainActor func gestureAndOrdinaryShortcutUseImmediateStartOrRevealWithoutDelayedCapture(
  phase: RecordingControlPhase
) throws {
  let desktop = try DesktopTestFixture()
  defer { desktop.cleanup() }
  let fixture = GestureFixture()
  var fallback: (@MainActor () -> Void)?
  let shortcut = GlobalRecordingShortcut(
    system: .init(register: { callback in
      fallback = callback; return RecordingShortcutLease {}
    }),
    gestureSystem: fixture.system,
    action: { desktop.shell.startOrReveal(from: .keyboard) }
  )
  desktop.services.onSelect = { #expect(!desktop.shell.recordingVisible) }
  shortcut.register()
  fixture.tap()
  fixture.tap()
  #expect(desktop.services.startCount == 1)
  #expect(desktop.services.selectionCount == 1)
  desktop.services.state.phase = phase
  desktop.services.state.canStart = false
  desktop.shell.hideRecording()
  fallback?()
  #expect(desktop.shell.recordingVisible)
  desktop.shell.hideRecording()
  fixture.tap()
  fixture.tap()
  #expect(desktop.shell.recordingVisible)
  desktop.services.state.phase = .idle
  desktop.services.state.canStart = true
  #expect(desktop.services.startCount == 1)
  #expect(desktop.services.finishCount == 0)
  shortcut.unregister()
}
