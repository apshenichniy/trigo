import Foundation
import ScreenCaptureKit
import Testing

@testable import TrigoNative

actor RecordingMetadataFixture: ConnectionMetadataStoring {
  var value: ConnectionMetadata?
  init(_ value: ConnectionMetadata? = nil) { self.value = value }
  func load() -> ConnectionMetadata? { value }
  func save(_ metadata: ConnectionMetadata) { value = metadata }
}

actor RecordingCredentialsFixture: CredentialStoring {
  var tokens: [String: String] = [:]
  func load(account: String) -> String? { tokens[account] }
  func save(token: String, account: String) { tokens[account] = token }
  func delete(account: String) { tokens.removeValue(forKey: account) }
}

actor RecordingStatusFixture: ServerStatusFetching {
  let archiveID = "00000000-0000-4000-8000-000000000016"
  var failure: ConnectionIssue?
  private var shouldHold = false
  private var held: CheckedContinuation<Void, Never>?
  private var waiting: [CheckedContinuation<Void, Never>] = []
  func setFailure(_ issue: ConnectionIssue?) { failure = issue }
  func holdNextFetch() { shouldHold = true }
  func waitForHeldFetch() async {
    if held != nil { return }
    await withCheckedContinuation { waiting.append($0) }
  }
  func releaseFetch() {
    shouldHold = false
    held?.resume()
    held = nil
  }
  func fetch(serverURL: URL, token: String) async throws -> ServerStatus {
    if shouldHold {
      await withCheckedContinuation { continuation in
        held = continuation
        for continuation in waiting { continuation.resume() }
        waiting = []
      }
    }
    if let failure { throw failure }
    return .init(
      schemaVersion: 1, apiVersion: 1, archiveId: archiveID, stage: .dev,
      readiness: .init(
        archive: "ready", ownerAuthentication: "ready", transcription: .notVerified,
        callOperations: .unavailable), errors: [])
  }
}

@MainActor final class RecordingTransportFixture: CaptureTransport {
  struct Unavailable: Error {}
  var running = false
  var failsStart = false
  var suspendStart = false
  private var entered = false
  private var observers: [CheckedContinuation<Void, Never>] = []
  private var pending: CheckedContinuation<Void, Never>?
  func addCaptureOutput(
    _ output: any SCStreamOutput, type: SCStreamOutputType, queue: DispatchQueue
  ) throws {}
  func startCapture() async throws {
    if failsStart { throw Unavailable() }
    if suspendStart {
      await withCheckedContinuation {
        pending = $0
        signalStart()
      }
    } else {
      signalStart()
    }
    running = true
  }
  func stopForRetirement() async throws { running = false }
  func waitForStart() async {
    if entered { return }
    await withCheckedContinuation { observers.append($0) }
  }
  func finishStart() {
    pending?.resume()
    pending = nil
  }
  private func signalStart() {
    entered = true
    for continuation in observers { continuation.resume() }
    observers = []
  }
}

@Test @MainActor func recordingRequiresSetupBeforeAnySourceOrPermissionAction() async throws {
  let support = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-controls-\(UUID())")
  defer { try? FileManager.default.removeItem(at: support) }
  let namespace = try AppNamespace(variant: .dev, worktree: "fixture", support: support)
  let connection = ServerConnection(
    expectedStage: .dev, metadataStore: RecordingMetadataFixture(),
    credentialStore: RecordingCredentialsFixture(), statusClient: RecordingStatusFixture())
  var sourceReads = 0
  var permissionRequests = 0
  let coordinator = RecordingCoordinator(
    connection: connection, namespace: namespace, capture: ScreenCaptureRecording(),
    sources: .init(
      permissions: { .init(screenAudio: false, microphone: false) },
      frontmost: {
        sourceReads += 1
        throw CaptureStartFailure.unsupportedSource
      },
      requestPermissions: {
        permissionRequests += 1
        return .init(screenAudio: false, microphone: false)
      }))
  await coordinator.restore()
  #expect(coordinator.phase == .setupRequired)
  await coordinator.shortcutPressed()
  await coordinator.startPinnedSource()
  #expect(coordinator.phase == .setupRequired)
  #expect(sourceReads == 0)
  #expect(permissionRequests == 0)
  #expect(coordinator.notice?.message.contains("Connect") == true)
}

@Test(arguments: [ConnectionIssue.unreachable, .unauthorized, .incompatible]) @MainActor
func savedBindingRecordsLocallyAndShortcutStopsItsPinnedSourceAcrossFocusChanges(
  healthFailure: ConnectionIssue
) async throws {
  let support = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-offline-\(UUID())")
  defer { try? FileManager.default.removeItem(at: support) }
  let namespace = try AppNamespace(variant: .dev, worktree: "fixture", support: support)
  let status = RecordingStatusFixture()
  let connection = ServerConnection(
    expectedStage: .dev, metadataStore: RecordingMetadataFixture(),
    credentialStore: RecordingCredentialsFixture(), statusClient: status)
  let original = CaptureSource(
    applicationName: "Target", bundleID: "test.target", processID: 123, windowID: 456,
    windowTitle: "Original window", processLaunchDate: Date())
  var frontmost = original
  var sourceReads = 0
  let capture = ScreenCaptureRecording(
    system: .init(
      permissions: { .init(screenAudio: true, microphone: true) },
      filter: { _ in SCContentFilter() }, microphone: { nil },
      stream: { _, _, _ in RecordingTransportFixture() }))
  let coordinator = RecordingCoordinator(
    connection: connection, namespace: namespace, capture: capture,
    sources: .init(
      permissions: { .init(screenAudio: true, microphone: true) },
      frontmost: {
        sourceReads += 1
        return frontmost
      },
      requestPermissions: { .init(screenAudio: true, microphone: true) }))
  await coordinator.connect(serverURL: "https://dev.example.test", token: "fixture")
  await status.setFailure(healthFailure)
  await coordinator.restore()
  #expect(coordinator.connectionSnapshot.health == .blocked(healthFailure))
  #expect(!coordinator.connectionSnapshot.serverOperationsAvailable)
  await coordinator.shortcutPressed()
  #expect(coordinator.phase == .recording)
  #expect(coordinator.pinnedSource == original)
  let callID = try #require(coordinator.callID)
  frontmost = .init(
    applicationName: "Other", bundleID: "test.other", processID: 124, windowID: 457,
    windowTitle: "Different window", processLaunchDate: Date())
  await coordinator.shortcutPressed()
  #expect(coordinator.phase == .idle)
  #expect(coordinator.pinnedSource == original)
  #expect(coordinator.callID == callID)
  #expect(sourceReads == 1)
  let archive = try LocalArchive(root: namespace.archive, archiveID: status.archiveID)
  #expect(
    try await archive.loadCall(callID: callID).manifest.value.object?["captureState"]?.string
      == "stopped")
}
