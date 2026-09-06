import Combine
import Foundation

public enum RecordingControlPhase: Equatable, Sendable {
  case setupRequired, idle, starting, recording, stopping, recoveryRequired, interrupted, error
}

public struct RecordingNotice: Equatable, Sendable {
  public let title: String
  public let message: String
}

@MainActor struct RecordingSourceAccess {
  var frontmost: () throws -> CaptureSource
  var requestPermissions: () async -> CapturePermissions
  static var live: Self {
    .init(
      frontmost: SystemCaptureSource.frontmost,
      requestPermissions: SystemCaptureSource.requestPermissions)
  }
}

@MainActor private final class RecordingControlAttempt {
  var cancelled = false
}

/// One control owner for the floating panel, global shortcut and application termination.
@MainActor public final class RecordingCoordinator: ObservableObject {
  @Published public private(set) var connectionSnapshot = ConnectionSnapshot(
    binding: nil, health: .setupRequired, lastAttemptIssue: nil)
  @Published public private(set) var isConnecting = false
  @Published public private(set) var notice: RecordingNotice?
  @Published public private(set) var pinnedSource: CaptureSource?
  @Published public private(set) var callID: String?
  @Published public private(set) var recordingSnapshot: CaptureRecordingSnapshot?
  @Published private var capturePhase: ScreenCapturePhase = .idle
  @Published private var attempt: RecordingControlAttempt?
  @Published private var isStopping = false
  private var startTask: Task<Void, Never>?
  private let connection: ServerConnection
  private let namespace: AppNamespace
  private let capture: ScreenCaptureRecording
  private let sources: RecordingSourceAccess

  public convenience init(connection: ServerConnection, namespace: AppNamespace) {
    self.init(
      connection: connection, namespace: namespace, capture: ScreenCaptureRecording(),
      sources: .live)
  }

  init(
    connection: ServerConnection, namespace: AppNamespace, capture: ScreenCaptureRecording,
    sources: RecordingSourceAccess
  ) {
    self.connection = connection
    self.namespace = namespace
    self.capture = capture
    self.sources = sources
    capture.onPhaseChange = { [weak self] phase in self?.capturePhase = phase }
    capture.onChange = { [weak self] snapshot in self?.recordingSnapshot = snapshot }
    capture.onFailure = { [weak self] reason in
      self?.notice = .init(
        title: "Capture needs attention",
        message:
          "\(reason.replacingOccurrences(of: "_", with: " ")). Retained local media has not been discarded."
      )
    }
  }

  public var phase: RecordingControlPhase {
    if isStopping || attempt?.cancelled == true { return .stopping }
    switch capturePhase {
    case .starting: return .starting
    case .recording: return .recording
    case .stopping, .cancellingStart: return .stopping
    case .needsRecovery: return .recoveryRequired
    case .idle: break
    }
    if attempt != nil { return .starting }
    if recordingSnapshot?.state == .interrupted { return .interrupted }
    switch connectionSnapshot.recordingEligibility {
    case .requiresSetup: return .setupRequired
    case .unavailableUntilRecovery: return .recoveryRequired
    case .eligible: return notice == nil ? .idle : .error
    }
  }

  public var canStop: Bool { phase == .starting || phase == .recording }

  public func restore() async {
    guard !isConnecting else { return }
    isConnecting = true
    defer { isConnecting = false }
    connectionSnapshot = await connection.restore()
  }

  public func connect(serverURL: String, token: String) async {
    guard !isConnecting else { return }
    isConnecting = true
    defer { isConnecting = false }
    connectionSnapshot = await connection.connect(serverURL: serverURL, token: token)
  }

  public func shortcutPressed() async {
    if canStop {
      await stop()
      return
    }
    await start(useFrontmost: true)
  }

  public func startPinnedSource() async { await start(useFrontmost: false) }

  public func stop() async {
    guard !isStopping else { return }
    attempt?.cancelled = true
    isStopping = true
    defer { isStopping = false }
    do { _ = try await capture.stop() } catch { report(error) }
    capturePhase = capture.phase
    callID = capture.session?.callID
  }

  private func start(useFrontmost: Bool) async {
    guard mayStart() else { return }
    let current = RecordingControlAttempt()
    attempt = current
    notice = nil
    recordingSnapshot = nil
    let task = Task { [self] in
      do {
        let selected: CaptureSource
        if useFrontmost {
          selected = try sources.frontmost()
        } else if let pinnedSource {
          selected = pinnedSource
        } else {
          notice = .init(
            title: "Choose an application",
            message: "Focus the target application and use the global recording shortcut.")
          return
        }
        guard selected.processID != ProcessInfo.processInfo.processIdentifier else {
          throw CaptureStartFailure.unsupportedSource
        }
        pinnedSource = selected
        let permissions = await sources.requestPermissions()
        guard !current.cancelled else { return }
        _ = try CaptureSourceResolver.resolve(
          permissions: permissions, frontmostPID: selected.processID,
          ownPID: ProcessInfo.processInfo.processIdentifier, windows: [selected])
        guard case .eligible(let archiveID) = connectionSnapshot.recordingEligibility else {
          return
        }
        try await capture.start(root: namespace.archive, archiveID: archiveID, source: selected)
        recordingSnapshot = capture.snapshot
      } catch {
        if !current.cancelled { report(error) }
      }
    }
    startTask = task
    await task.value
    if attempt === current {
      callID = capture.session?.callID
      capturePhase = capture.phase
      attempt = nil
      startTask = nil
    }
  }

  private func mayStart() -> Bool {
    guard attempt == nil, !isStopping, capturePhase == .idle else { return false }
    guard case .eligible = connectionSnapshot.recordingEligibility else {
      notice = .init(
        title: "Setup required", message: "Connect to your archive before the first recording.")
      return false
    }
    return true
  }

  private func report(_ error: any Error) {
    if let failure = error as? CaptureStartFailure {
      notice = .init(title: "Recording could not start", message: failure.recoverySuggestion)
    } else {
      notice = .init(
        title: "Local capture needs recovery",
        message:
          "Check free disk space and access to the archive, then retry recovery. Retained media has not been deleted."
      )
    }
  }
}
