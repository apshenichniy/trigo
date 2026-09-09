import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

extension RecordingGestureSystem {
  static func live(preferences: UserDefaults) -> Self {
    .init(
      loadPreferences: {
        .init(
          enabled: preferences.bool(forKey: "recordingGesture.enabled"),
          requested: preferences.bool(forKey: "recordingGesture.requested"),
          granted: preferences.bool(forKey: "recordingGesture.granted")
        )
      },
      savePreferences: {
        preferences.set($0.enabled, forKey: "recordingGesture.enabled")
        preferences.set($0.requested, forKey: "recordingGesture.requested")
        preferences.set($0.granted, forKey: "recordingGesture.granted")
      },
      environment: {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return .init(
          permission: CGPreflightListenEventAccess(),
          secureInput: IsSecureEventInputEnabled(),
          sessionActive: session?[kCGSessionOnConsoleKey as String] as? Bool == true
            && session?[kCGSessionLoginDoneKey as String] as? Bool == true,
          neutral:
            flags.intersection([
              .maskControl, .maskShift, .maskAlternate, .maskCommand, .maskAlphaShift,
              .maskSecondaryFn,
            ])
            .isEmpty
        )
      },
      requestPermission: { _ = CGRequestListenEventAccess() },
      openSettings: {
        NSWorkspace.shared.open(
          URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
          )!
        )
      },
      acquireOwnership: {
        let support = try FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
        return try acquireRecordingGestureOwnership(support: support)
      },
      listen: installRecordingGestureTap,
      observe: observeRecordingGestureLifecycle
    )
  }
}

/// Deliberately independent of bundle, worktree and archive: every Trigo copy shares this lease.
@MainActor func acquireRecordingGestureOwnership(support: URL) throws -> RecordingShortcutLease {
  let lease = try ExclusiveFileLease(
    file: support.appendingPathComponent(
      "io.github.apshenichniy.trigo.shared/recording-gesture.lock"
    )
  )
  return RecordingShortcutLease { lease.relinquish() }
}

@MainActor private final class RecordingGestureCallback {
  let receive: @MainActor (RecordingGestureSignal) -> Void
  init(_ receive: @escaping @MainActor (RecordingGestureSignal) -> Void) { self.receive = receive }
}

enum RecordingGestureTapError: Error { case unavailable }

@MainActor private func installRecordingGestureTap(
  _ receive: @escaping @MainActor (RecordingGestureSignal) -> Void
) throws -> RecordingShortcutLease {
  let context = RecordingGestureCallback(receive)
  // Pointer movement is deliberately absent. Buttons, drags and scroll only cancel a candidate.
  let types: [CGEventType] = [
    .flagsChanged, .keyDown, .keyUp,
    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
    .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    .scrollWheel,
  ]
  let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
  guard
    let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .listenOnly,
      eventsOfInterest: mask,
      callback: { _, type, event, pointer in
        if let pointer {
          // The source is installed only on the main run loop. Return the original event unchanged.
          MainActor.assumeIsolated {
            let context = Unmanaged<RecordingGestureCallback>.fromOpaque(pointer)
              .takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
              context.receive(.tapDisabled)
            } else {
              context.receive(.input(.decode(type: type, event: event)))
            }
          }
        }
        return Unmanaged.passUnretained(event)
      },
      userInfo: Unmanaged.passUnretained(context).toOpaque()
    )
  else { throw RecordingGestureTapError.unavailable }
  guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
    CFMachPortInvalidate(tap)
    throw RecordingGestureTapError.unavailable
  }
  CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
  CGEvent.tapEnable(tap: tap, enable: true)
  return RecordingShortcutLease {
    withExtendedLifetime(context) {
      CGEvent.tapEnable(tap: tap, enable: false)
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
      CFMachPortInvalidate(tap)
    }
  }
}

@MainActor private func observeRecordingGestureLifecycle(
  _ changed: @escaping @MainActor (RecordingGestureLifecycle) -> Void
) -> RecordingShortcutLease {
  let center = NSWorkspace.shared.notificationCenter
  let events: [(Notification.Name, RecordingGestureLifecycle)] = [
    (NSWorkspace.willSleepNotification, .willSleep),
    (NSWorkspace.didWakeNotification, .didWake),
    (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive),
    (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
  ]
  let observers = events.map { name, event in
    center.addObserver(forName: name, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { changed(event) }
    }
  }
  // Permission revocation, Secure Input and a released owner may have no workspace notification.
  let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
    MainActor.assumeIsolated { changed(.refresh) }
  }
  RunLoop.main.add(timer, forMode: .common)
  return RecordingShortcutLease {
    timer.invalidate()
    for observer in observers { center.removeObserver(observer) }
  }
}
