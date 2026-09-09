import AppKit
import Foundation
import ScreenCaptureKit

@testable import TrigoNative

@MainActor final class FixtureEnvironment {
  let configuration: FixtureConfiguration
  let application = FixtureCaptureTransport()
  let microphone = FixtureCaptureTransport()
  let queue = DispatchQueue(label: "trigo.ui-fixture.audio")
  private var coordinator: RecordingCoordinator?
  private(set) var shortcut: GlobalRecordingShortcut?

  init(configuration: FixtureConfiguration) { self.configuration = configuration }

  func makeShortcut(_ shell: DesktopShell) -> GlobalRecordingShortcut {
    var preferences = RecordingGesturePreferences()
    let shortcut = GlobalRecordingShortcut(
      system: .init(register: { _ in RecordingShortcutLease {} }),
      gestureSystem: .init(
        loadPreferences: { preferences },
        savePreferences: { preferences = $0 },
        environment: {
          .init(permission: false, secureInput: false, sessionActive: true, neutral: true)
        },
        requestPermission: {},
        openSettings: {},
        acquireOwnership: { throw FixtureFailure.forbiddenAdapter },
        listen: { _ in throw FixtureFailure.forbiddenAdapter },
        observe: { _ in RecordingShortcutLease {} }
      ),
      action: { [weak shell] in shell?.startOrReveal(from: .keyboard) }
    )
    self.shortcut = shortcut
    return shortcut
  }

  func makeServices(_ namespace: AppNamespace) throws -> any DesktopRecordingServices {
    guard namespace.fixtureIdentifier == FixtureConfiguration.bundleID, namespace.variant == nil
    else {
      throw FixtureFailure.forbiddenAdapter
    }
    _ = try LocalRepository(root: namespace.archive, archiveID: FixtureConfiguration.archiveID)
    let account = "ui-fixture-memory-token"
    let metadata = FixtureMetadata(
      configuration.scenario == .setup
        ? nil
        : .init(
          committed: .init(
            serverURL: URL(string: "https://fixture.invalid")!,
            archiveId: FixtureConfiguration.archiveID,
            stage: .dev,
            credentialAccount: account
          )
        )
    )
    let connection = ServerConnection(
      expectedStage: .dev,
      metadataStore: metadata,
      credentialStore: FixtureCredentials(account: account),
      statusClient: FixtureStatus()
    )
    let permissions = CapturePermissions(
      screenAudio: configuration.scenario != .denied,
      microphone: configuration.scenario != .denied
    )
    let source = CaptureSource(
      applicationName: "Synthetic conversation",
      bundleID: "io.github.apshenichniy.trigo.fixture.focus",
      processID: 720,
      windowID: 721,
      windowTitle: "Synthetic acceptance conversation",
      processLaunchDate: Date(timeIntervalSince1970: 1_788_864_000)
    )
    let capture = ScreenCaptureRecording(
      system: .init(
        permissions: { permissions },
        filter: { _ in SCContentFilter() },
        microphone: { .init(id: "synthetic-microphone", name: "Synthetic microphone") },
        stream: { [self] _, value, _ in value.captureMicrophone ? microphone : application },
        audioQueue: { [self] in queue },
        sourceIsAvailable: { _ in true }
      )
    )
    let coordinator = RecordingCoordinator(
      connection: connection,
      namespace: namespace,
      capture: capture,
      sources: .init(
        permissions: { permissions },
        frontmost: { source },
        requestPermission: { _ in permissions },
        openSettings: { _ in false }
      )
    )
    self.coordinator = coordinator
    return LiveDesktopRecordingServices(coordinator: coordinator)
  }
}

actor FixtureMetadata: ConnectionMetadataStoring {
  var value: ConnectionMetadata?
  init(_ value: ConnectionMetadata?) { self.value = value }
  func load() -> ConnectionMetadata? { value }
  func save(_ value: ConnectionMetadata) { self.value = value }
}

actor FixtureCredentials: CredentialStoring {
  var values: [String: String]
  init(account: String) { values = [account: "synthetic-in-process-token"] }
  func load(account: String) -> String? { values[account] }
  func save(token: String, account: String) { values[account] = token }
  func delete(account: String) { values.removeValue(forKey: account) }
}

struct FixtureStatus: ServerStatusFetching {
  func fetch(serverURL: URL, token: String) throws -> ServerStatus {
    guard serverURL.host == "fixture.invalid", token == "synthetic-in-process-token" else {
      throw ConnectionIssue.unauthorized
    }
    return .init(
      schemaVersion: 1,
      apiVersion: 1,
      archiveId: FixtureConfiguration.archiveID,
      stage: .dev,
      readiness: .init(
        archive: "ready",
        ownerAuthentication: "ready",
        transcription: .notVerified,
        callOperations: .unavailable
      ),
      errors: []
    )
  }
}

@MainActor final class FixtureCaptureTransport: CaptureTransport {
  func addCaptureOutput(
    _ output: any SCStreamOutput,
    type: SCStreamOutputType,
    queue: DispatchQueue
  ) throws {}
  func startCapture() async throws {}
  func stopForRetirement() async throws {}
}

@MainActor final class FixtureLoginService: DesktopLoginService {
  var status: DesktopLoginStatus = .disabled
  func setEnabled(_ enabled: Bool) async throws { status = enabled ? .enabled : .disabled }
  func openSettings() {}
}
