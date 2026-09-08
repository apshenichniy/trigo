import Foundation
import ScreenCaptureKit

@testable import TrigoNative

@MainActor final class RecordingOSFixture {
  let audioQueue = DispatchQueue(label: "trigo.fixture.capture")
  let application = RecordingTransportFixture()
  let microphone = RecordingTransportFixture()
  var microphoneDevice: CaptureMicrophone? = .init(id: "fixture-mic", name: "Fixture microphone")
  var source = CaptureSource(
    applicationName: "Fixture target",
    bundleID: "test.target",
    processID: 123,
    windowID: 456,
    windowTitle: "Fixture window",
    processLaunchDate: Date()
  )
  var permissions = CapturePermissions(screenAudio: true, microphone: true)
  var permissionRequests = 0
  var requestedPermissions: [CapturePermission] = []
  var settingsOpened: [CapturePermission] = []
  var onPermissionRequest: (() -> Void)?
  var onFilter: (() -> Void)?
  var filterFailure: CaptureStartFailure?
  var sourceAvailable = true
  var frontmostFailure: CaptureStartFailure?
  var frontmostReads = 0
  func frontmost() throws -> CaptureSource {
    frontmostReads += 1
    if let frontmostFailure { throw frontmostFailure }
    return source
  }
}

@MainActor final class RecordingControlFixture {
  let support: URL
  let namespace: AppNamespace
  let os = RecordingOSFixture()
  let status = RecordingStatusFixture()
  let metadata = RecordingMetadataFixture()
  let connection: ServerConnection
  let capture: ScreenCaptureRecording
  let coordinator: RecordingCoordinator

  init(persistence: CapturePersistence = .live) throws {
    support = FileManager.default.temporaryDirectory.appendingPathComponent(
      "trigo-coordinator-\(UUID())"
    )
    namespace = try AppNamespace(variant: .dev, worktree: "fixture", support: support)
    connection = ServerConnection(
      expectedStage: .dev,
      metadataStore: metadata,
      credentialStore: RecordingCredentialsFixture(),
      statusClient: status
    )
    let os = self.os
    capture = ScreenCaptureRecording(
      system: .init(
        permissions: { os.permissions },
        filter: { _ in
          if let failure = os.filterFailure { throw failure }
          os.onFilter?()
          return SCContentFilter()
        },
        microphone: { os.microphoneDevice },
        stream: { _, configuration, _ in
          configuration.captureMicrophone ? os.microphone : os.application
        },
        audioQueue: { os.audioQueue },
        sourceIsAvailable: { _ in os.sourceAvailable }
      ),
      persistence: persistence
    )
    coordinator = RecordingCoordinator(
      connection: connection,
      namespace: namespace,
      capture: capture,
      sources: .init(
        permissions: { os.permissions },
        frontmost: os.frontmost,
        requestPermission: { permission in
          os.requestedPermissions.append(permission)
          os.permissionRequests += 1
          os.onPermissionRequest?()
          return os.permissions
        },
        openSettings: { permission in
          os.settingsOpened.append(permission)
          return true
        }
      )
    )
  }

  func bind() async {
    await coordinator.connect(serverURL: "https://dev.example.test", token: "fixture")
  }
  func cleanup() { try? FileManager.default.removeItem(at: support) }
}
