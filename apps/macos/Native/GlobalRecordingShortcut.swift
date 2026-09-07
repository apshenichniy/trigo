import Carbon.HIToolbox
import Combine
import Foundation

enum RecordingShortcutError: Error { case registrationFailed(OSStatus) }

@MainActor final class RecordingShortcutLease {
  private var release: (() -> Void)?
  init(release: @escaping () -> Void) { self.release = release }
  func cancel() {
    let cleanup = release
    release = nil
    cleanup?()
  }
  isolated deinit { cancel() }
}

@MainActor struct RecordingShortcutSystem {
  var register: (@escaping @MainActor () -> Void) throws -> RecordingShortcutLease
  static var live: Self { .init(register: registerCarbonRecordingShortcut) }
}

/// Owns one exclusive registration and fences callbacks from a retired registration.
@MainActor public final class GlobalRecordingShortcut: ObservableObject {
  public static let label = "⌃⌥⌘R"
  @Published public private(set) var isRegistered = false
  @Published public private(set) var issue: String?
  private let system: RecordingShortcutSystem
  private let action: @MainActor () -> Void
  private var lease: RecordingShortcutLease?
  private var generation = UUID()

  public convenience init(action: @escaping @MainActor () -> Void) {
    self.init(system: .live, action: action)
  }
  init(system: RecordingShortcutSystem, action: @escaping @MainActor () -> Void) {
    self.system = system
    self.action = action
  }

  public func register() {
    guard lease == nil else { return }
    generation = UUID()
    let expected = generation
    do {
      lease = try system.register { [weak self] in
        guard let self, isRegistered, generation == expected else { return }
        action()
      }
      isRegistered = true
      issue = nil
    } catch {
      isRegistered = false
      issue =
        "The recording shortcut could not be registered. Close another Trigo instance or release Control–Option–Command–R in the conflicting app or System Settings → Keyboard → Keyboard Shortcuts, then retry. Panel controls remain available for a pinned source."
    }
  }

  public func unregister() {
    isRegistered = false
    generation = UUID()
    lease?.cancel()
    lease = nil
  }
}

@MainActor private final class RecordingHotKeyCallback {
  let action: @MainActor () -> Void
  init(_ action: @escaping @MainActor () -> Void) { self.action = action }
}

@MainActor private func registerCarbonRecordingShortcut(
  _ action: @escaping @MainActor () -> Void
) throws -> RecordingShortcutLease {
  let context = RecordingHotKeyCallback(action)
  var handler: EventHandlerRef?
  var hotKey: EventHotKeyRef?
  var eventType = EventTypeSpec(
    eventClass: OSType(kEventClassKeyboard),
    eventKind: UInt32(kEventHotKeyPressed)
  )
  let handlerStatus = InstallEventHandler(
    GetApplicationEventTarget(),
    { _, event, pointer in
      guard let pointer, let event else { return OSStatus(eventNotHandledErr) }
      var identifier = EventHotKeyID()
      let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
      )
      guard status == noErr, identifier.signature == 0x5452_4947, identifier.id == 16 else {
        return OSStatus(eventNotHandledErr)
      }
      // The application event target dispatches on the main event loop; Carbon is not thread safe.
      MainActor.assumeIsolated {
        Unmanaged<RecordingHotKeyCallback>.fromOpaque(pointer).takeUnretainedValue().action()
      }
      return noErr
    },
    1,
    &eventType,
    Unmanaged.passUnretained(context).toOpaque(),
    &handler
  )
  guard handlerStatus == noErr else {
    throw RecordingShortcutError.registrationFailed(handlerStatus)
  }
  let status = RegisterEventHotKey(
    UInt32(kVK_ANSI_R),
    UInt32(controlKey | optionKey | cmdKey),
    EventHotKeyID(signature: 0x5452_4947, id: 16),
    GetApplicationEventTarget(),
    OptionBits(kEventHotKeyExclusive),
    &hotKey
  )
  guard status == noErr else {
    if let handler { RemoveEventHandler(handler) }
    throw RecordingShortcutError.registrationFailed(status)
  }
  return RecordingShortcutLease {
    // Keep the C callback context alive until after its handler is removed.
    withExtendedLifetime(context) {
      if let hotKey { UnregisterEventHotKey(hotKey) }
      if let handler { RemoveEventHandler(handler) }
    }
  }
}
