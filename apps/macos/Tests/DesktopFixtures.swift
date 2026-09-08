import Combine
import Foundation

import TrigoNative

@MainActor final class DesktopGate {
  private(set) var entered = false
  private var blocked: CheckedContinuation<Void, Never>?
  private var observers: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    await withCheckedContinuation {
      blocked = $0
      entered = true
      observers.forEach { $0.resume() }
      observers = []
    }
  }
  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func release() {
    blocked?.resume()
    blocked = nil
  }
}

@MainActor final class DesktopServicesFixture: DesktopRecordingServices {
  let subject = PassthroughSubject<Void, Never>()
  var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
  var state: DesktopRecordingState { willSet { subject.send() } }
  var restoreCount = 0
  var startCount = 0
  var finishCount = 0
  var terminationCount = 0
  var selectionCount = 0
  var restoreGate: DesktopGate?
  var terminationGate: DesktopGate?
  var terminationSafe = false
  var onSelect: () -> Void = {}
  var selected: Result<CaptureSource, CaptureStartFailure>?
  var frontmost = CaptureSource(
    applicationName: "Controlled source",
    bundleID: "test.source",
    processID: 712,
    windowID: 713,
    windowTitle: "Controlled window",
    processLaunchDate: Date(timeIntervalSince1970: 100)
  )

  init() {
    var state = DesktopRecordingState()
    state.phase = .idle
    state.canStart = true
    state.canConfigureCapture = true
    state.permissions = .init(screenAudio: true, microphone: true)
    state.connection = .init(
      binding: ArchiveBinding(
        serverURL: URL(string: "https://fixture.invalid")!,
        archiveId: "00000000-0000-4000-8000-000000000071",
        stage: .dev
      ),
      health: .blocked(.unreachable),
      lastAttemptIssue: nil
    )
    state.quitRequirement = .ready
    self.state = state
  }
  func restore() async { restoreCount += 1; await restoreGate?.wait() }
  func selectSource() -> Result<CaptureSource, CaptureStartFailure> {
    selectionCount += 1
    onSelect()
    return .success(frontmost)
  }
  func start(source: Result<CaptureSource, CaptureStartFailure>) {
    startCount += 1
    selected = source
    state.source = try? source.get()
    state.phase = .starting
    state.canStart = false
    state.canStop = true
    state.quitRequirement = .confirmFinish
  }
  func retryStart() async {}
  func finish() async { finishCount += 1 }
  func retryRecovery() async {}
  func toggleMicrophone() async {}
  func prepareForTermination() async -> Bool {
    terminationCount += 1
    await terminationGate?.wait()
    if !terminationSafe {
      state.phase = .recoveryRequired
      state.quitRequirement = .waitForSafety
      state.canStart = false
    }
    return terminationSafe
  }
  func connect(serverURL: String, token: String) async {}
  func refreshReadiness() {}
  func enableAccess(_ permission: CapturePermission) async {}
  func openAccessSettings(_ permission: CapturePermission) {}
}

@MainActor struct DesktopTestFixture {
  let root: URL
  let services: DesktopServicesFixture
  let composition: DesktopComposition
  let shell: DesktopShell

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("trigo-desktop-\(UUID())")
    let services = DesktopServicesFixture()
    self.services = services
    composition = try DesktopComposition(
      fixtureBundleIdentifier: "io.github.apshenichniy.trigo.fixture.shell",
      runID: "test",
      support: root,
      makeServices: { _ in services }
    )
    shell = DesktopShell(composition: composition)
  }
  func cleanup() { try? FileManager.default.removeItem(at: root) }
}
