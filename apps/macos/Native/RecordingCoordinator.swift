import AppKit
import Combine
import Foundation

public enum RecordingControlPhase: Equatable, Sendable {
  case setupRequired, idle, starting, recording, stopping, recoveryRequired, interrupted, error
}

public struct RecordingNotice: Equatable, Sendable {
  public let title: String
  public let message: String

  public init(title: String, message: String) {
    self.title = title
    self.message = message
  }
}

public enum MicrophoneRecordingState: Equatable, Sendable {
  case inactive, starting, recording, muted, unavailable
}

@MainActor struct RecordingSourceAccess {
  var permissions: () -> CapturePermissions
  var frontmost: () throws -> CaptureSource
  var requestPermission: (CapturePermission) async -> CapturePermissions
  var openSettings: (CapturePermission) -> Bool = { _ in false }
  static var live: Self {
    .init(
      permissions: SystemCaptureSource.permissions,
      frontmost: SystemCaptureSource.frontmost,
      requestPermission: SystemCaptureSource.requestPermission,
      openSettings: { NSWorkspace.shared.open($0.settingsURL) }
    )
  }
}

@MainActor private final class RecordingControlAttempt {
  var cancelled = false
}

/// One control owner for the floating panel, global shortcut and application termination.
@MainActor public final class RecordingCoordinator: ObservableObject {
  @Published public private(set) var connectionSnapshot = ConnectionSnapshot(
    binding: nil,
    health: .setupRequired,
    lastAttemptIssue: nil
  )
  @Published public private(set) var isConnecting = false
  @Published public private(set) var capturePermissions: CapturePermissions
  @Published public private(set) var isRequestingPermission = false
  private var requestedScreenAccess = false

  @Published public private(set) var notice: RecordingNotice?
  @Published public private(set) var pinnedSource: CaptureSource?
  @Published public private(set) var callID: String?
  @Published public private(set) var recordingSnapshot: CaptureRecordingSnapshot?
  @Published public private(set) var microphoneRecordingEnabled = true
  @Published public private(set) var isMicrophoneChanging = false
  @Published public private(set) var recoveryReport = RecordingRecoveryReport()
  @Published public private(set) var isRecovering = false
  private var recoveredArchiveID: String?
  private var noticeTracksMicrophoneAvailability = false
  @Published private var capturePhase: ScreenCapturePhase = .idle
  @Published private var attempt: RecordingControlAttempt?
  @Published private var isStopping = false
  @Published private var isTerminating = false
  private var startTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private let connection: ServerConnection
  private let namespace: AppNamespace
  private let capture: ScreenCaptureRecording
  private let sources: RecordingSourceAccess

  public convenience init(connection: ServerConnection, namespace: AppNamespace) {
    self.init(
      connection: connection,
      namespace: namespace,
      capture: ScreenCaptureRecording(),
      sources: .live
    )
  }

  init(
    connection: ServerConnection,
    namespace: AppNamespace,
    capture: ScreenCaptureRecording,
    sources: RecordingSourceAccess
  ) {
    self.connection = connection
    self.namespace = namespace
    self.capture = capture
    self.sources = sources
    self.capturePermissions = sources.permissions()
    capture.onPhaseChange = { [weak self] phase in self?.capturePhase = phase }
    capture.onChange = { [weak self] snapshot in
      guard let self else { return }
      recordingSnapshot = snapshot
      if !isMicrophoneChanging { microphoneRecordingEnabled = snapshot.microphoneEnabled }
      if noticeTracksMicrophoneAvailability,
        snapshot.microphone != nil || snapshot.state != .recording
      {
        notice = nil
        noticeTracksMicrophoneAvailability = false
      }
    }
    capture.onFailure = { [weak self] reason in
      guard let self else { return }
      refreshCaptureReadiness()
      noticeTracksMicrophoneAvailability =
        reason == "microphone_unavailable" || reason == "microphone_permission"
      notice = .init(
        title: "Capture needs attention",
        message: Self.captureRecoverySuggestion(reason)
      )
    }
  }

  public var phase: RecordingControlPhase {
    if isStopping || attempt?.cancelled == true { return .stopping }
    if isRecovering { return .recoveryRequired }
    switch capturePhase {
    case .starting: return .starting
    case .recording: return .recording
    case .stopping, .cancellingStart: return .stopping
    case .needsRecovery: return .recoveryRequired
    case .idle: break
    }
    if attempt != nil { return .starting }
    if !recoveryReport.failures.isEmpty { return .recoveryRequired }
    if recordingSnapshot?.state == .interrupted { return .interrupted }
    if recordingSnapshot == nil,
      recoveryReport.recoveredCalls.contains(where: { $0.interruptionReason != nil })
    {
      return .interrupted
    }
    switch connectionSnapshot.recordingEligibility {
    case .requiresSetup: return .setupRequired
    case .unavailableUntilRecovery: return .recoveryRequired
    case .eligible: return notice == nil ? .idle : .error
    }
  }

  public var canStop: Bool { phase == .starting || phase == .recording }
  public var connectionRecoveryIssue: ConnectionIssue? {
    guard case .unavailableUntilRecovery = connectionSnapshot.recordingEligibility,
      case .recoveryRequired(let issue) = connectionSnapshot.health
    else { return nil }
    return issue
  }

  public var canRetryLocalRecovery: Bool {
    guard case .eligible = connectionSnapshot.recordingEligibility,
      !isRecovering, attempt == nil, !isStopping, !isTerminating
    else { return false }
    if case .needsRecovery = capturePhase { return true }
    return capturePhase == .idle && !recoveryReport.failures.isEmpty
  }
  public var canStart: Bool {
    guard case .eligible = connectionSnapshot.recordingEligibility else { return false }
    return attempt == nil && !isStopping && !isTerminating && !isMicrophoneChanging
      && !isRequestingPermission
      && capturePhase == .idle && !isRecovering && recoveryReport.failures.isEmpty
  }

  /// Read-only refresh after activation, wake, Settings return and device changes.
  public func refreshCaptureReadiness() {
    capturePermissions = sources.permissions()
  }

  public var canConfigureCapture: Bool {
    !isRequestingPermission && !isTerminating && attempt == nil
      && capturePhase == .idle && !isStopping
  }

  public func enableCaptureAccess(_ permission: CapturePermission) async {
    guard canConfigureCapture else { return }
    refreshCaptureReadiness()
    switch permission {
    case .screenAudio:
      guard !capturePermissions.screenAudio else { return }
      // Request history only controls this session's setup action; it is not a TCC status.
      if requestedScreenAccess {
        openCaptureSettings(permission)
        return
      }
      requestedScreenAccess = true
    case .microphone:
      guard !capturePermissions.microphone else { return }
      guard capturePermissions.microphoneAuthorization == .notDetermined else {
        openCaptureSettings(permission)
        return
      }
    }
    isRequestingPermission = true
    defer { isRequestingPermission = false }
    capturePermissions = await sources.requestPermission(permission)
    notice = .init(
      title: capturePermissions.ready ? "Permissions ready" : "Capture access required",
      message: capturePermissions.ready
        ? "Focus the target application and press the shortcut. No source was selected during setup."
        : "Review capture access in System Settings, return to Trigo and refresh readiness. No recording has started."
    )
  }

  public func openCaptureSettings(_ permission: CapturePermission) {
    if !sources.openSettings(permission) {
      notice = .init(
        title: "Open System Settings",
        message: permission == .screenAudio
          ? CaptureStartFailure.screenAudioPermission.recoverySuggestion
          : CaptureStartFailure.microphonePermission.recoverySuggestion
      )
    }
  }

  public func retryRecovery() async {
    guard !isRecovering, attempt == nil, !isStopping, !isTerminating,
      capturePhase != .recording, capturePhase != .starting,
      case .eligible(let archiveID) = connectionSnapshot.recordingEligibility
    else { return }
    isRecovering = true
    let task = Task { [self] in
      defer {
        isRecovering = false
        recoveryTask = nil
      }
      if case .needsRecovery = capture.phase {
        do { _ = try await capture.retryRecovery() } catch {
          report(error)
          return
        }
      }
      guard capture.phase == .idle else { return }
      recoveryReport = await RecordingRecovery.run(root: namespace.archive, archiveID: archiveID)
      recoveredArchiveID = archiveID
      if recoveryReport.failures.isEmpty { notice = nil }
    }
    recoveryTask = task
    await task.value
  }

  private func acceptConnection(_ snapshot: ConnectionSnapshot) async {
    connectionSnapshot = snapshot
    if case .eligible(let archiveID) = snapshot.recordingEligibility,
      recoveredArchiveID != archiveID
    {
      await retryRecovery()
    }
  }

  public var microphoneState: MicrophoneRecordingState {
    guard phase == .recording || phase == .starting else { return .inactive }
    if phase == .starting { return .starting }
    guard let recordingSnapshot else { return .starting }
    guard recordingSnapshot.microphone != nil else { return .unavailable }
    return microphoneRecordingEnabled ? .recording : .muted
  }

  public func toggleMicrophone() async {
    guard phase == .recording, !isMicrophoneChanging, !isTerminating else { return }
    isMicrophoneChanging = true
    defer { isMicrophoneChanging = false }
    let expectedCall = capture.session?.callID
    let enabled = !microphoneRecordingEnabled
    do {
      try await capture.setMicrophoneEnabled(enabled)
      guard phase == .recording, capture.session?.callID == expectedCall else { return }
      microphoneRecordingEnabled = enabled
      recordingSnapshot = capture.snapshot
    } catch {
      if phase == .recording, capture.session?.callID == expectedCall { report(error) }
    }
  }

  public func restore() async {
    refreshCaptureReadiness()
    guard !isConnecting else { return }
    isConnecting = true
    defer { isConnecting = false }
    let snapshot = await connection.restore(onBindingRestored: { [weak self] snapshot in
      await self?.acceptConnection(snapshot)
    })
    await acceptConnection(snapshot)
  }

  public func connect(serverURL: String, token: String) async {
    guard !isConnecting else { return }
    isConnecting = true
    defer { isConnecting = false }
    await acceptConnection(await connection.connect(serverURL: serverURL, token: token))
  }

  public func shortcutPressed() async {
    guard mayStart() else { return }
    await startSelectedSource(selectFrontmostSource())?.value
  }

  /// Selection is synchronous, before a menu, panel or asynchronous Start can change focus.
  public func selectFrontmostSource() -> Result<CaptureSource, CaptureStartFailure> {
    refreshCaptureReadiness()
    guard capturePermissions.ready else {
      return .failure(
        capturePermissions.screenAudio ? .microphonePermission : .screenAudioPermission
      )
    }
    do { return .success(try sources.frontmost()) } catch {
      return .failure(error as? CaptureStartFailure ?? .unsupportedSource)
    }
  }

  public func startPinnedSource() async {
    await startSelectedSource(pinnedSource.map { .success($0) } ?? .failure(.unsupportedSource))?
      .value
  }

  /// The shell may exit immediately only when no capture, late Start or recovery is outstanding.
  public var canTerminateImmediately: Bool {
    capture.phase == .idle && attempt == nil && startTask == nil && stopTask == nil
      && recoveryTask == nil && !isRecovering && recoveryReport.failures.isEmpty
  }

  public func stop(reason: String? = nil) async {
    if let stopTask {
      await stopTask.value
      return
    }
    attempt?.cancelled = true
    isStopping = true
    let task = Task { [self] in
      defer {
        isStopping = false
        stopTask = nil
      }
      do { _ = try await capture.stop(reason: reason) } catch { report(error) }
      capturePhase = capture.phase
      callID = capture.session?.callID
    }
    stopTask = task
    await task.value
  }

  /// Return true only when native retirement/finalization and late Start continuations are done.
  public func prepareForTermination() async -> Bool {
    isTerminating = true
    await stop(reason: "application_termination")
    await startTask?.value
    await recoveryTask?.value
    let safe = canTerminateImmediately
    if !safe {
      isTerminating = false
      notice = .init(
        title: "Finish recovery before quitting",
        message:
          "The recording has not finished safely. Retry local recovery; do not discard the retained media."
      )
    }
    return safe
  }

  /// Synchronous admission fences repeated intents; the returned task owns native completion.
  @discardableResult public func startSelectedSource(
    _ selection: Result<CaptureSource, CaptureStartFailure>
  ) -> Task<Void, Never>? {
    guard mayStart() else { return nil }
    let current = RecordingControlAttempt()
    attempt = current
    notice = nil
    noticeTracksMicrophoneAvailability = false
    recordingSnapshot = nil
    pinnedSource = try? selection.get()
    let task = Task { [self] in
      defer {
        if attempt === current {
          callID = capture.session?.callID
          capturePhase = capture.phase
          attempt = nil
          startTask = nil
        }
      }
      do {
        refreshCaptureReadiness()
        let preflight = capturePermissions
        if !preflight.ready {
          report(
            preflight.screenAudio
              ? CaptureStartFailure.microphonePermission : .screenAudioPermission
          )
          return
        }
        let selected = try selection.get()
        guard selected.processID != ProcessInfo.processInfo.processIdentifier else {
          throw CaptureStartFailure.unsupportedSource
        }
        pinnedSource = selected
        guard !current.cancelled else { return }
        _ = try CaptureSourceResolver.resolve(
          permissions: preflight,
          frontmostPID: selected.processID,
          ownPID: ProcessInfo.processInfo.processIdentifier,
          windows: [selected]
        )
        guard case .eligible(let archiveID) = connectionSnapshot.recordingEligibility else {
          return
        }
        try await capture.start(root: namespace.archive, archiveID: archiveID, source: selected)
        recordingSnapshot = capture.snapshot
        recoveryReport.recoveredCalls = []
        recoveryReport.warnings = []
      } catch {
        guard !current.cancelled else { return }
        report(error)
      }
    }
    startTask = task
    return task
  }

  private func mayStart() -> Bool {
    if case .requiresSetup = connectionSnapshot.recordingEligibility {
      notice = .init(
        title: "Setup required",
        message: "Connect to your archive before the first recording."
      )
    }
    return canStart
  }

  private func report(_ error: any Error) {
    noticeTracksMicrophoneAvailability = false
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

  private static func captureRecoverySuggestion(_ reason: String) -> String {
    if reason == "microphone_permission" {
      return
        "Application audio continues recording. Microphone access is required; review Microphone settings and refresh readiness."
    }
    if reason == "microphone_unavailable" {
      return
        "Application audio continues recording. Please check or connect the input device; Trigo will show the microphone when it becomes available."
    }
    let action: String
    switch reason {
    case "screen_audio_permission":
      action = CaptureStartFailure.screenAudioPermission.recoverySuggestion
    case "source_exited":
      action =
        "The selected application exited. Focus the target application and press the shortcut to start a new recording."
    case "system_sleep":
      action =
        "Recording was interrupted by sleep. Focus the target application and press the shortcut to start a new recording."
    case "duration_limit":
      action = "The three-hour recording limit was reached. Start a new recording to continue."
    default:
      action =
        "Check capture permissions, free disk space and archive access, then retry local recovery or start a new recording when ready."
    }
    return "\(action) Retained local media has not been discarded."
  }
}
