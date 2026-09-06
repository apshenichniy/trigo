import Foundation
import Testing

@testable import TrigoNative

@Test @MainActor func shortcutRegistrationIsSingleAndRetiredCallbacksCannotAct() async throws {
  var callbacks: [@MainActor () -> Void] = []
  var cancellations = 0
  var presses = 0
  let shortcut = GlobalRecordingShortcut(
    system: .init(register: { callback in
      callbacks.append(callback)
      return RecordingShortcutLease { cancellations += 1 }
    }), action: { presses += 1 })
  shortcut.register()
  shortcut.register()
  #expect(callbacks.count == 1)
  callbacks[0]()
  #expect(presses == 1)
  shortcut.unregister()
  shortcut.unregister()
  callbacks[0]()
  #expect(presses == 1)
  #expect(cancellations == 1)
  shortcut.register()
  callbacks[0]()
  callbacks[1]()
  #expect(presses == 2)
  shortcut.unregister()
}

@Test @MainActor func shortcutConflictLeavesPinnedPanelControlsUsable() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.bind()
  await fixture.coordinator.shortcutPressed()
  await fixture.coordinator.stop()
  let shortcut = GlobalRecordingShortcut(
    system: .init(register: { _ in
      throw RecordingShortcutError.registrationFailed(-9878)
    }), action: {})
  shortcut.register()
  #expect(!shortcut.isRegistered)
  #expect(shortcut.issue?.contains("Keyboard") == true)
  await fixture.coordinator.startPinnedSource()
  #expect(fixture.coordinator.phase == .recording)
  await fixture.coordinator.stop()
}
