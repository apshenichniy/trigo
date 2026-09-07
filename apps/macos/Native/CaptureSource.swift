import AVFoundation
import AppKit
import ScreenCaptureKit

public enum CapturePermission: String, Sendable {
  case screenAudio, microphone

  public var settingsURL: URL {
    URL(
      string: "x-apple.systempreferences:com.apple.preference.security?"
        + (self == .screenAudio ? "Privacy_ScreenCapture" : "Privacy_Microphone"))!
  }
}

public enum MicrophoneAuthorization: Equatable, Sendable {
  case notDetermined, authorized, denied, restricted, unknown
}

public struct CapturePermissions: Equatable, Sendable {
  /// CoreGraphics supplies only a Boolean: false does not distinguish denial from revocation.
  public let screenAudio: Bool
  public let microphoneAuthorization: MicrophoneAuthorization
  public let microphoneAvailable: Bool
  public var microphone: Bool { microphoneAuthorization == .authorized }
  public var ready: Bool { screenAudio && microphone }

  public init(screenAudio: Bool, microphone: Bool) {
    self.init(
      screenAudio: screenAudio,
      microphoneAuthorization: microphone ? .authorized : .notDetermined,
      microphoneAvailable: true)
  }

  public init(
    screenAudio: Bool, microphoneAuthorization: MicrophoneAuthorization,
    microphoneAvailable: Bool
  ) {
    self.screenAudio = screenAudio
    self.microphoneAuthorization = microphoneAuthorization
    self.microphoneAvailable = microphoneAvailable
  }
}

public enum CaptureStartFailure: Error, Equatable, Sendable {
  case screenAudioPermission, microphonePermission, unsupportedSource, sourceExited,
    alreadyRecording

  public var recoverySuggestion: String {
    switch self {
    case .screenAudioPermission:
      "Allow Trigo in System Settings → Privacy & Security → Screen & System Audio Recording, then retry."
    case .microphonePermission:
      "Allow Trigo in System Settings → Privacy & Security → Microphone, then retry."
    case .unsupportedSource:
      "Focus a normal window of the application to record, then retry. All audio from that application is included."
    case .sourceExited:
      "The selected application instance is no longer running. Select a source and start a new recording."
    case .alreadyRecording:
      "Stop the active recording before starting another."
    }
  }
}

public struct CaptureSource: Codable, Equatable, Sendable {
  public let applicationName: String
  public let bundleID: String
  public let processID: Int32
  public let windowID: UInt32
  public let windowTitle: String?
  public let processLaunchDate: Date

  public init(
    applicationName: String, bundleID: String, processID: Int32,
    windowID: UInt32, windowTitle: String?, processLaunchDate: Date
  ) {
    self.applicationName = applicationName
    self.bundleID = bundleID
    self.processID = processID
    self.windowID = windowID
    self.windowTitle = windowTitle
    self.processLaunchDate = processLaunchDate
  }

  public func matches(processID: Int32, bundleID: String?, launchDate: Date?) -> Bool {
    self.processID == processID && self.bundleID == bundleID && processLaunchDate == launchDate
  }
}

public enum CaptureSourceResolver {
  /// Windows are ordered front-to-back by the OS adapter. Never falls back to a display/system source.
  public static func resolve(
    permissions: CapturePermissions, frontmostPID: Int32?, ownPID: Int32,
    windows: [CaptureSource]
  ) throws -> CaptureSource {
    guard permissions.screenAudio else { throw CaptureStartFailure.screenAudioPermission }
    guard permissions.microphone else { throw CaptureStartFailure.microphonePermission }
    guard let frontmostPID, frontmostPID != ownPID,
      let source = windows.first(where: { $0.processID == frontmostPID }),
      !source.bundleID.isEmpty, !source.applicationName.isEmpty
    else { throw CaptureStartFailure.unsupportedSource }
    return source
  }
}

@MainActor public enum SystemCaptureSource {
  public static func permissions() -> CapturePermissions {
    let authorization: MicrophoneAuthorization
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .notDetermined: authorization = .notDetermined
    case .authorized: authorization = .authorized
    case .denied: authorization = .denied
    case .restricted: authorization = .restricted
    @unknown default: authorization = .unknown
    }
    return .init(
      screenAudio: CGPreflightScreenCaptureAccess(),
      microphoneAuthorization: authorization,
      microphoneAvailable: AVCaptureDevice.default(for: .audio)?.isConnected == true)
  }

  /// Only the explicit setup/enable action calls this OS consent boundary. Never Start.
  public static func requestPermission(_ permission: CapturePermission) async -> CapturePermissions
  {
    switch permission {
    case .screenAudio:
      if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    case .microphone:
      if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
      }
    }
    return permissions()
  }

  public static func frontmost() throws -> CaptureSource {
    let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let permission = permissions()
    CaptureDiagnostics.shared?.record(
      .init(
        kind: .sourceLookup,
        flags: (permission.screenAudio ? 1 : 0) | (permission.microphone ? 2 : 0),
        // DEBUG-57-CAPTURE
        frontmostPID: frontmost))
    guard permission.screenAudio else { throw CaptureStartFailure.screenAudioPermission }
    guard permission.microphone else { throw CaptureStartFailure.microphonePermission }
    let windows =
      CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
      as? [[String: Any]] ?? []
    let candidates = windows.compactMap { info -> CaptureSource? in
      guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid == frontmost,
        info[kCGWindowLayer as String] as? Int == 0,
        let id = info[kCGWindowNumber as String] as? UInt32,
        let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
        app.activationPolicy == .regular, let bundleID = app.bundleIdentifier,
        let name = app.localizedName, let launch = app.launchDate
      else { return nil }
      return .init(
        applicationName: name, bundleID: bundleID, processID: pid, windowID: id,
        windowTitle: info[kCGWindowName as String] as? String, processLaunchDate: launch)
    }
    do {
      let selected = try CaptureSourceResolver.resolve(
        permissions: permission, frontmostPID: frontmost,
        ownPID: ProcessInfo.processInfo.processIdentifier, windows: candidates)
      CaptureDiagnostics.shared?.record(
        .init(
          kind: .sourceResult,
          // DEBUG-57-CAPTURE
          frontmostPID: frontmost, candidateCount: candidates.count, outcome: .selected))
      return selected
    } catch {
      CaptureDiagnostics.shared?.record(
        .init(
          kind: .sourceResult,
          // DEBUG-57-CAPTURE
          frontmostPID: frontmost, candidateCount: candidates.count, outcome: .unavailable))
      throw error
    }
  }

  static func filter(for source: CaptureSource) async throws -> SCContentFilter {
    guard let running = NSRunningApplication(processIdentifier: source.processID),
      !running.isTerminated,
      source.matches(
        processID: running.processIdentifier, bundleID: running.bundleIdentifier,
        launchDate: running.launchDate)
    else { throw CaptureStartFailure.sourceExited }
    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    guard
      let application = content.applications.first(where: {
        $0.processID == source.processID && $0.bundleIdentifier == source.bundleID
      }), let window = content.windows.first(where: { $0.windowID == source.windowID }),
      let display = content.displays.first(where: { $0.frame.intersects(window.frame) })
    else { throw CaptureStartFailure.unsupportedSource }
    // Including exactly one application also includes its other windows/tabs. No display-wide fallback.
    return SCContentFilter(display: display, including: [application], exceptingWindows: [])
  }
}
