import Darwin
import Foundation
import Testing

@testable import TrigoNative

@Test @MainActor func secondAppCannotFinalizeAnotherAppsLiveRecording() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let first = RecordingApplication(namespace: fixture.namespace) { fixture.coordinator }
  defer { withExtendedLifetime(first) {} }
  #expect(first.coordinator != nil)
  let session = try await CaptureArchiveSession.begin(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID,
    source: fixture.os.source,
    microphone: nil
  )
  let writer = try CaptureMediaWriter(session: session)
  try writer.append(interleaved: Array(repeating: 123, count: 32_000))

  // The second application's startup recovery must not claim a live writer.
  var initializedSecondCoordinator = false
  let second = RecordingApplication(namespace: fixture.namespace) {
    initializedSecondCoordinator = true
    return fixture.coordinator
  }
  if let coordinator = second.coordinator { await coordinator.restore() }
  #expect(!initializedSecondCoordinator)
  #expect(second.coordinator == nil)
  #expect(second.startupFailure?.title == "This local archive is already open")
  let repository = try LocalRepository(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID
  )
  #expect(try repository.captureCompletion(callID: session.callID) == nil)
  #expect(try repository.confirmedMediaCursor(callID: session.callID)?.frames == 16_000)

  try writer.append(interleaved: Array(repeating: 456, count: 32_000))
  let completed = try await session.finish(media: finishCapture(writer), interruptionReason: nil)
  let call = try jsonObject(completed.manifest.storedBytes)
  #expect(call["durationMs"] as? Int == 2_000)
  #expect(call["captureState"] as? String == "stopped")
}

@Test func ownershipIsScopedAndReleasedWithoutRemovingItsLockFile() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("trigo-owner-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let namespace = try AppNamespace(variant: .dev, worktree: "first", support: root)
  var owner: AppInstanceLease? = try AppInstanceLease(namespace: namespace)
  let other = try AppInstanceLease(
    namespace: AppNamespace(variant: .dev, worktree: "second", support: root)
  )
  defer { withExtendedLifetime(other) {} }
  #expect(throws: AppInstanceLeaseError.alreadyRunning) {
    try AppInstanceLease(namespace: namespace)
  }
  let path = namespace.connection.deletingLastPathComponent()
    .appendingPathComponent(
      "application.lock"
    )
  let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
  #expect(attributes[.posixPermissions] as? Int == 0o600)
  withExtendedLifetime(owner) {}
  owner = nil
  let replacement = try AppInstanceLease(namespace: namespace)
  defer { withExtendedLifetime(replacement) {} }
  #expect(
    try FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? UInt64
      == attributes[.systemFileNumber] as? UInt64
  )
}

@Test @MainActor func unsafeLockRejectsStartupBeforeAnyCoordinatorIsConstructed() throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let directory = fixture.namespace.connection.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let foreign = fixture.support.appendingPathComponent("foreign")
  let bytes = Data("untouched".utf8)
  try bytes.write(to: foreign)
  try FileManager.default.createSymbolicLink(
    at: directory.appendingPathComponent("application.lock"),
    withDestinationURL: foreign
  )
  var constructed = false
  let application = RecordingApplication(namespace: fixture.namespace) {
    constructed = true
    return fixture.coordinator
  }
  #expect(!constructed)
  #expect(application.coordinator == nil)
  #expect(application.startupFailure?.title == "Cannot safely open the local archive")
  #expect(try Data(contentsOf: foreign) == bytes)
}

private final class AppLeaseTestBundleMarker: NSObject {}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TRIGO_APP_LEASE_CHILD_ROOT"] != nil))
func applicationLeaseChild() throws {
  let environment = ProcessInfo.processInfo.environment
  let namespace = try AppNamespace(
    variant: .dev,
    worktree: "child",
    support: URL(fileURLWithPath: try #require(environment["TRIGO_APP_LEASE_CHILD_ROOT"]))
  )
  if environment["TRIGO_APP_LEASE_CHILD_MODE"] == "blocked" {
    #expect(throws: AppInstanceLeaseError.alreadyRunning) {
      try AppInstanceLease(namespace: namespace)
    }
  } else {
    let lease = try AppInstanceLease(namespace: namespace)
    defer { withExtendedLifetime(lease) {} }
    guard Darwin.kill(Darwin.getpid(), SIGKILL) == 0 else {
      throw AppInstanceLeaseError.unavailable
    }
    while true { Darwin.pause() }
  }
}

@Test func anotherProcessIsExcludedAndKilledOwnerDoesNotLeaveAStaleLease() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-owner-process-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let namespace = try AppNamespace(variant: .dev, worktree: "child", support: root)
  var owner: AppInstanceLease? = try AppInstanceLease(namespace: namespace)
  let contender = try runLeaseChild(root: root, mode: "blocked")
  #expect(contender.terminationReason == .exit)
  #expect(contender.terminationStatus == 0)
  withExtendedLifetime(owner) {}
  owner = nil
  let crashed = try runLeaseChild(root: root, mode: "crash")
  #expect(crashed.terminationReason == .uncaughtSignal)
  #expect(crashed.terminationStatus == SIGKILL)
  let replacement = try AppInstanceLease(namespace: namespace)
  withExtendedLifetime(replacement) {}
}

private func runLeaseChild(root: URL, mode: String) throws -> Process {
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  let bundlePath = Bundle(for: AppLeaseTestBundleMarker.self).executableURL!.path
  let packagePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().path
  child.arguments = [
    "--test-bundle-path", bundlePath, "--package-path", packagePath,
    "--filter", "applicationLeaseChild", bundlePath, "--testing-library", "swift-testing",
  ]
  child.environment = ProcessInfo.processInfo.environment.merging(
    [
      "TRIGO_APP_LEASE_CHILD_ROOT": root.path, "TRIGO_APP_LEASE_CHILD_MODE": mode,
    ],
    uniquingKeysWith: { _, new in new }
  )
  child.standardOutput = FileHandle.nullDevice
  child.standardError = FileHandle.nullDevice
  try child.run()
  child.waitUntilExit()
  return child
}
