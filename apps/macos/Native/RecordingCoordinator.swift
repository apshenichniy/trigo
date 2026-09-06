import Combine
import Foundation

public enum RecordingControlPhase: Equatable, Sendable {
  case setupRequired, idle, starting, recording, stopping, recoveryRequired, interrupted, error
}

public struct RecordingNotice: Equatable, Sendable {
  public let title: String
  public let message: String
}

public enum MicrophoneRecordingState: Equatable, Sendable {
  case inactive, starting, recording, muted, unavailable
}

@MainActor struct RecordingSourceAccess {
  var permissions: () -> CapturePermissions
  var frontmost: () throws -> CaptureSource
  var requestPermissions: () async -> CapturePermissions
  static var live: Self {
    .init(
      permissions: SystemCaptureSource.permissions,
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
      noticeTracksMicrophoneAvailability = reason == "microphone_unavailable"
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
      && capturePhase == .idle && !isRecovering && recoveryReport.failures.isEmpty
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
    if canStop {
      await stop()
      return
    }
    await start(useFrontmost: true)
  }

  public func startPinnedSource() async { await start(useFrontmost: false) }

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
    let safe = capture.phase == .idle && startTask == nil && stopTask == nil
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

  private func start(useFrontmost: Bool) async {
    guard mayStart() else { return }
    let current = RecordingControlAttempt()
    attempt = current
    notice = nil
    noticeTracksMicrophoneAvailability = false
    recordingSnapshot = nil
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
        if !useFrontmost && pinnedSource == nil {
          notice = .init(
            title: "Choose an application",
            message: "Focus the target application and use the global recording shortcut.")
          return
        }
        let preflight = sources.permissions()
        if !preflight.screenAudio || !preflight.microphone {
          let granted = await sources.requestPermissions()
          guard !current.cancelled else { return }
          if granted.screenAudio && granted.microphone {
            notice = .init(
              title: "Permissions ready",
              message:
                "Focus the target application and press the shortcut again. No source was selected during the permission request."
            )
          } else {
            report(
              granted.screenAudio
                ? CaptureStartFailure.microphonePermission : .screenAudioPermission)
          }
          return
        }
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
        guard !current.cancelled else { return }
        _ = try CaptureSourceResolver.resolve(
          permissions: preflight, frontmostPID: selected.processID,
          ownPID: ProcessInfo.processInfo.processIdentifier, windows: [selected])
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
    await task.value
  }

  private func mayStart() -> Bool {
    if case .requiresSetup = connectionSnapshot.recordingEligibility {
      notice = .init(
        title: "Setup required", message: "Connect to your archive before the first recording.")
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
    if reason == "microphone_unavailable" {
      return
        "Application audio continues recording. Please check or connect the input device; Trigo will show the microphone when it becomes available."
    }
    let action: String
    switch reason {
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
