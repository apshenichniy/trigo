import Combine
import Foundation

/// `prepareForTermination` remains the authority before any deferred Quit succeeds.
public enum DesktopQuitRequirement: Equatable, Sendable {
  case ready, confirmFinish, waitForSafety
}

public struct DesktopRecordingState: Equatable, Sendable {
  public var phase: RecordingControlPhase = .setupRequired
  public var connection = ConnectionSnapshot(
    binding: nil,
    health: .setupRequired,
    lastAttemptIssue: nil
  )
  public var permissions = CapturePermissions(screenAudio: false, microphone: false)
  public var isConnecting = false
  public var canStart = false
  public var canStop = false
  public var canConfigureCapture = false
  public var canRetryRecovery = false
  public var isRecovering = false
  public var notice: RecordingNotice?
  public var source: CaptureSource?
  public var elapsedMs = 0
  public var microphoneState: MicrophoneRecordingState = .inactive
  public var microphoneEnabled = true
  public var microphoneChanging = false
  public var microphoneName: String?
  public var microphoneNoticeSequence = 0
  public var microphoneUnavailableReason: String?
  public var levels = RecordedAudioLevels()
  public var finalization = CaptureFinalizationState()
  public var recoveryMessages: [String] = []
  public var quitRequirement: DesktopQuitRequirement = .waitForSafety

  public init() {}

  public var statusTitle: String {
    switch phase {
    case .setupRequired: "Setup required"
    case .idle: permissions.ready ? "Ready to record" : "Capture access required"
    case .starting: "Starting recording…"
    case .recording: "Recording"
    case .stopping: "Saving recording…"
    case .recoveryRequired: recoveryTitle
    case .interrupted: "Recording interrupted"
    case .error: notice?.title ?? "Recording needs attention"
    }
  }
}

/// All recording, repository/connection and permission effects cross this boundary.
/// Fixture implementations must supply every method; none defaults to an installed service.
@MainActor public protocol DesktopRecordingServices: AnyObject {
  var changes: AnyPublisher<Void, Never> { get }
  var state: DesktopRecordingState { get }
  func restore() async
  func selectSource() -> Result<CaptureSource, CaptureStartFailure>
  func start(source: Result<CaptureSource, CaptureStartFailure>)
  func retryStart() async
  func finish() async
  func retryRecovery() async
  func toggleMicrophone() async
  func prepareForTermination() async -> Bool
  func connect(serverURL: String, token: String) async
  func refreshReadiness()
  func enableAccess(_ permission: CapturePermission) async
  func openAccessSettings(_ permission: CapturePermission)
}

@MainActor final class LiveDesktopRecordingServices: DesktopRecordingServices {
  private let coordinator: RecordingCoordinator
  init(coordinator: RecordingCoordinator) { self.coordinator = coordinator }

  var changes: AnyPublisher<Void, Never> { coordinator.objectWillChange.eraseToAnyPublisher() }
  var state: DesktopRecordingState {
    var value = DesktopRecordingState()
    value.phase = coordinator.phase
    value.connection = coordinator.connectionSnapshot
    value.permissions = coordinator.capturePermissions
    value.isConnecting = coordinator.isConnecting
    value.canStart = coordinator.canStart
    value.canStop = coordinator.canStop
    value.canConfigureCapture = coordinator.canConfigureCapture
    value.canRetryRecovery = coordinator.canRetryLocalRecovery
    value.isRecovering = coordinator.isRecovering
    value.notice =
      coordinator.notice
      ?? coordinator.connectionRecoveryIssue.map {
        RecordingNotice(title: $0.title, message: $0.recoverySuggestion)
      }
    value.source = coordinator.pinnedSource
    value.elapsedMs = coordinator.recordingSnapshot?.elapsedMs ?? 0
    value.microphoneState = coordinator.microphoneState
    value.microphoneEnabled = coordinator.microphoneRecordingEnabled
    value.microphoneChanging = coordinator.isMicrophoneChanging
    value.microphoneName = coordinator.recordingSnapshot?.microphone?.name
    value.microphoneNoticeSequence = coordinator.microphoneNoticeSequence
    value.microphoneUnavailableReason = coordinator.microphoneUnavailableReason
    value.levels =
      value.phase == .recording ? coordinator.recordingSnapshot?.levels ?? .init() : .init()
    value.finalization = coordinator.finalization
    value.recoveryMessages =
      coordinator.recoveryReport.recoveredCalls.map { "\($0.callID): \($0.explanation)" }
      + coordinator.recoveryReport.failures.map { "\($0.callID): \($0.message)" }
      + coordinator.recoveryReport.warnings.map { "\($0.callID): \($0.message)" }
    value.quitRequirement =
      coordinator.canTerminateImmediately
      ? .ready
      : coordinator.canStop ? .confirmFinish : .waitForSafety
    return value
  }

  func restore() async { await coordinator.restore() }
  func selectSource() -> Result<CaptureSource, CaptureStartFailure> {
    coordinator.selectFrontmostSource()
  }
  func start(source: Result<CaptureSource, CaptureStartFailure>) {
    coordinator.startSelectedSource(source)
  }
  func retryStart() async { await coordinator.startPinnedSource() }
  func finish() async { await coordinator.stop() }
  func retryRecovery() async { await coordinator.retryRecovery() }
  func toggleMicrophone() async { await coordinator.toggleMicrophone() }
  func prepareForTermination() async -> Bool { await coordinator.prepareForTermination() }
  func connect(serverURL: String, token: String) async {
    await coordinator.connect(serverURL: serverURL, token: token)
  }
  func refreshReadiness() { coordinator.refreshCaptureReadiness() }
  func enableAccess(_ permission: CapturePermission) async {
    await coordinator.enableCaptureAccess(permission)
  }
  func openAccessSettings(_ permission: CapturePermission) {
    coordinator.openCaptureSettings(permission)
  }
}
