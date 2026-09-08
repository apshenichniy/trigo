import Combine
import Foundation

public enum RecordingGestureStatus: String, Sendable {
  case disabled, permissionRequired, denied, revoked, unavailable, anotherTrigoOwner
  case secureInput, sessionInactive, available

  public var message: String {
    switch self {
    case .disabled: "Double Left Control is disabled."
    case .permissionRequired: "Enable Input Monitoring for this copy of Trigo in System Settings."
    case .denied:
      "Input Monitoring has not been granted. Enable this copy of Trigo in System Settings."
    case .revoked:
      "Input Monitoring was revoked. Enable this copy of Trigo again in System Settings."
    case .unavailable:
      "The gesture listener is unavailable. Check Input Monitoring and retry; reopen Trigo if macOS asks."
    case .anotherTrigoOwner:
      "Another copy of Trigo owns the gesture. Disable it there or quit that copy to use it here."
    case .secureInput:
      "The gesture is suspended while Secure Input is active. Use the menu or recording controls."
    case .sessionInactive:
      "The gesture is suspended while this login session is inactive or the Mac is sleeping."
    case .available: "Double Left Control is available."
    }
  }
}

struct RecordingGesturePreferences {
  var enabled = false
  var requested = false
  var granted = false
}

struct RecordingGestureEnvironment {
  var permission: Bool
  var secureInput: Bool
  var sessionActive: Bool
  var neutral: Bool
}

enum RecordingGestureSignal { case input(RecordingGestureInput), tapDisabled }
enum RecordingGestureLifecycle { case refresh, willSleep, didWake, sessionInactive, sessionActive }

@MainActor struct RecordingGestureSystem {
  var loadPreferences: () -> RecordingGesturePreferences
  var savePreferences: (RecordingGesturePreferences) -> Void
  var environment: () -> RecordingGestureEnvironment
  var requestPermission: () -> Void
  var openSettings: () -> Void
  var acquireOwnership: () throws -> RecordingShortcutLease
  var listen:
    (@escaping @MainActor (RecordingGestureSignal) -> Void) throws -> RecordingShortcutLease
  var observe: (@escaping @MainActor (RecordingGestureLifecycle) -> Void) -> RecordingShortcutLease
}

/// Owns the permission/lease/tap lifetime. A retired listener can never dispatch a new intent.
@MainActor public final class RecordingGestureController: ObservableObject {
  @Published public private(set) var status: RecordingGestureStatus = .disabled
  @Published public private(set) var isEnabled = false
  private let system: RecordingGestureSystem?
  private let action: @MainActor () -> Void
  private var preferences = RecordingGesturePreferences()
  private var started = false
  private var sleeping = false
  private var inactive = false
  private var ownership: RecordingShortcutLease?
  private var listener: RecordingShortcutLease?
  private var observer: RecordingShortcutLease?
  private var generation = UUID()
  private var observationGeneration = UUID()
  private var recognizer = LeftControlGesture()

  init(system: RecordingGestureSystem?, action: @escaping @MainActor () -> Void) {
    self.system = system
    self.action = action
    if let system { preferences = system.loadPreferences() }
    isEnabled = preferences.enabled
  }

  func start() {
    guard !started, let system else { return }
    started = true
    sleeping = false
    inactive = false
    observationGeneration = UUID()
    let expected = observationGeneration
    observer = system.observe { [weak self] event in
      guard let self, observationGeneration == expected else { return }
      lifecycle(event)
    }
    refresh()
  }

  func stop() {
    started = false
    observationGeneration = UUID()
    retire()
    observer?.cancel()
    observer = nil
    status = .disabled
  }

  public func enable() {
    guard let system else { return }
    preferences.enabled = true
    isEnabled = true
    if !system.environment().permission {
      preferences.requested = true
      system.savePreferences(preferences)
      // This is the only permission-request path; startup, polling and recording never prompt.
      system.requestPermission()
    }
    system.savePreferences(preferences)
    refresh()
  }

  public func disable() {
    preferences.enabled = false
    isEnabled = false
    system?.savePreferences(preferences)
    retire()
    status = .disabled
  }

  public func openSettings() { system?.openSettings() }

  public func refresh() {
    guard started, let system else { return }
    let environment = system.environment()
    let blocked: RecordingGestureStatus?
    if !preferences.enabled {
      blocked = .disabled
    } else if !environment.permission {
      blocked =
        preferences.granted ? .revoked : preferences.requested ? .denied : .permissionRequired
    } else if sleeping || inactive || !environment.sessionActive {
      blocked = .sessionInactive
    } else if environment.secureInput {
      blocked = .secureInput
    } else {
      blocked = nil
    }
    if environment.permission && !preferences.granted {
      preferences.granted = true
      system.savePreferences(preferences)
    }
    if let blocked {
      retire()
      status = blocked
      return
    }
    guard listener == nil else { return }
    do {
      ownership = try system.acquireOwnership()
      generation = UUID()
      let expected = generation
      recognizer.reset(neutral: environment.neutral)
      listener = try system.listen { [weak self] signal in
        self?.receive(signal, generation: expected)
      }
      status = .available
    } catch ExclusiveFileLeaseError.alreadyOwned {
      retire()
      status = .anotherTrigoOwner
    } catch {
      retire()
      status = .unavailable
    }
  }

  private func receive(_ signal: RecordingGestureSignal, generation expected: UUID) {
    guard started, listener != nil, generation == expected else { return }
    switch signal {
    case .tapDisabled:
      retire()
      status = .unavailable
    case .input(let input):
      refresh()
      guard generation == expected, status == .available else { return }
      if recognizer.consume(input) { action() }
    }
  }

  private func lifecycle(_ event: RecordingGestureLifecycle) {
    guard started else { return }
    switch event {
    case .refresh: break
    case .willSleep: sleeping = true; retire()
    case .didWake: sleeping = false; retire()
    case .sessionInactive: inactive = true; retire()
    case .sessionActive: inactive = false; retire()
    }
    refresh()
  }

  private func retire() {
    generation = UUID()
    recognizer.reset()
    listener?.cancel()
    listener = nil
    ownership?.cancel()
    ownership = nil
  }

  isolated deinit { stop() }
}
