import Combine
import Foundation

public enum DesktopLaunchReason: Equatable, Sendable { case explicit, background }
public enum DesktopStartOrigin: Sendable { case keyboard, menu, library }
public enum DesktopTerminationReply: Equatable, Sendable { case now, later, cancel }
public enum DesktopSettingsSection: String, CaseIterable, Sendable {
  case general = "General", connection = "Connection", diagnostics = "Diagnostics"
}

/// App-lifetime command owner. Closing a view cannot cancel restore or retarget a call.
@MainActor public final class DesktopShell: ObservableObject {
  public let composition: DesktopComposition
  @Published public private(set) var recording: DesktopRecordingState
  @Published public private(set) var didBootstrap = false
  @Published public private(set) var isQuitting = false
  @Published public private(set) var recordingVisible = false
  @Published public private(set) var recordingRevealSequence = 0
  @Published public private(set) var recordingNotification: DesktopRecordingNotification?
  @Published public var settingsSection: DesktopSettingsSection = .general
  private var bootstrapTask: Task<Void, Never>?
  private var quitTask: Task<Void, Never>?
  private var observation: AnyCancellable?
  private var menuSource: Result<CaptureSource, CaptureStartFailure>?
  private var menuMayStart = false
  private var lastPhase: RecordingControlPhase
  private var lastSavedCallID: String?
  public var openLibrary: () -> Void = {}
  public var openSettings: () -> Void = {}

  public init(composition: DesktopComposition) {
    self.composition = composition
    let initial = composition.services?.state ?? DesktopRecordingState()
    recording = initial
    lastPhase = initial.phase
    observation = composition.services?.changes
      .sink { [weak self] in
        // ObservableObject sends before mutation. Read the final state on the next main turn.
        Task { @MainActor in self?.refresh() }
      }
  }

  @discardableResult public func bootstrap() -> Task<Void, Never> {
    if let bootstrapTask { return bootstrapTask }
    let task = Task { [self] in
      await composition.services?.restore()
      refresh()
      didBootstrap = true
    }
    bootstrapTask = task
    return task
  }

  public func launch(_ reason: DesktopLaunchReason) {
    bootstrap()
    if reason == .explicit { openLibrary() }
  }

  public func reopen() { openLibrary() }

  /// Called synchronously by the native menu's will-open callback, before it is presented.
  /// An intent shown during a busy operation must not become a queued Start after it settles.
  public func menuWillOpen() {
    guard let services = composition.services else { return }
    menuMayStart = services.state.canStart && !isQuitting
    menuSource = menuMayStart ? services.selectSource() : nil
    refresh()
  }

  public func startOrReveal(from origin: DesktopStartOrigin) {
    guard let services = composition.services else { return }
    if services.state.canStart && !isQuitting {
      recordingNotification = nil
      if origin == .menu {
        if menuMayStart, let menuSource { services.start(source: menuSource) }
      } else {
        // No Task, activation, panel or asynchronous work precedes this snapshot.
        let source = services.selectSource()
        services.start(source: source)
      }
    }
    menuMayStart = false
    menuSource = nil
    refresh()
    showRecording()
  }

  public func showRecording() {
    recordingRevealSequence += 1
    recordingVisible = true
  }
  public func hideRecording() { recordingVisible = false }
  public func dismissRecordingNotification(_ id: UUID) {
    guard recordingNotification?.id == id else { return }
    recordingNotification = nil
  }

  public func finish() async {
    await composition.services?.finish()
    refresh()
  }
  public func retryStart() async {
    guard !isQuitting else { return }
    await composition.services?.retryStart()
    refresh()
    showRecording()
  }
  public func retryRecovery() async {
    guard !isQuitting else { return }
    await composition.services?.retryRecovery()
    refresh()
  }
  public func toggleMicrophone() async {
    guard !isQuitting else { return }
    await composition.services?.toggleMicrophone()
    refresh()
  }
  public func connect(serverURL: String, token: String) async {
    await composition.services?.connect(serverURL: serverURL, token: token)
    refresh()
  }
  public func retryConnection() async {
    await composition.services?.restore()
    refresh()
  }
  public func refreshReadiness() {
    composition.services?.refreshReadiness()
    refresh()
  }
  public func enableAccess(_ permission: CapturePermission) async {
    await composition.services?.enableAccess(permission)
    refresh()
  }
  public func openAccessSettings(_ permission: CapturePermission) {
    composition.services?.openAccessSettings(permission)
    refresh()
  }
  public func showSettings(_ section: DesktopSettingsSection) {
    settingsSection = section
    openSettings()
  }

  /// AppKit's menu and Command-Q use this same route. No immediate workbench exit exists.
  public func requestQuit(
    confirmFinish: @escaping @MainActor () async -> Bool,
    reply: @escaping @MainActor (Bool) -> Void
  ) -> DesktopTerminationReply {
    guard !isQuitting else { return quitTask == nil ? .cancel : .later }
    guard let services = composition.services else { return .now }
    let requirement = services.state.quitRequirement
    if requirement == .ready {
      isQuitting = true
      return .now
    }
    isQuitting = true
    quitTask = Task { [self] in
      if requirement == .confirmFinish, !(await confirmFinish()) {
        isQuitting = false
        quitTask = nil
        reply(false)
        return
      }
      let safe = await services.prepareForTermination()
      refresh()
      if !safe {
        recordingVisible = true
        isQuitting = false
      }
      quitTask = nil
      reply(safe)
    }
    return .later
  }

  private func refresh() {
    guard let services = composition.services else { return }
    let value = services.state
    if value.microphoneNoticeSequence != recording.microphoneNoticeSequence,
      let message = value.microphoneUnavailableReason
    {
      recordingNotification = .init(
        notice: .init(title: "Microphone unavailable", message: message),
        isSaved: false
      )
    }
    if value.phase == .idle, value.finalization.isSettled,
      value.finalization.localSave == .confirmed, let callID = value.finalization.callID,
      lastSavedCallID != callID
    {
      lastSavedCallID = callID
      recordingVisible = false
      recordingNotification = .init(
        notice: .init(
          title: "Recording saved",
          message: "Audio is saved on this Mac. Upload and transcription may still be pending."
        ),
        isSaved: true
      )
    }
    if value.phase != lastPhase || (recording.isRecovering && !value.isRecovering) {
      if value.phase == .interrupted || value.phase == .error
        || (value.phase == .recoveryRequired && !value.isRecovering)
      {
        // Failures remain reachable after hide, and newly interrupted capture is surfaced.
        recordingVisible = true
      } else if lastPhase == .stopping && value.quitRequirement == .ready {
        recordingVisible = false
      }
      lastPhase = value.phase
    }
    recording = value
  }
}

/// Dock presence follows window existence, never visibility/minimization/fullscreen.
@MainActor public final class DesktopLibraryLifecycle {
  public private(set) var isOpen = false
  private let setDockPresence: (Bool) -> Void
  private let create: () -> Void
  private let reveal: () -> Void
  private let activate: () -> Void

  public init(
    setDockPresence: @escaping (Bool) -> Void,
    create: @escaping () -> Void,
    reveal: @escaping () -> Void,
    activate: @escaping () -> Void
  ) {
    self.setDockPresence = setDockPresence
    self.create = create
    self.reveal = reveal
    self.activate = activate
  }

  public func open() {
    if !isOpen {
      isOpen = true
      setDockPresence(true)
      create()
    }
    reveal()
    activate()
  }

  public func closed() {
    guard isOpen else { return }
    isOpen = false
    setDockPresence(false)
  }
}
