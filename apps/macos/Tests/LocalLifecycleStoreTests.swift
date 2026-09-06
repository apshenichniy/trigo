import Foundation
import Testing

@testable import TrigoNative

private let lifecycleArchiveID = "00000000-0000-4000-8000-000000000012"
private let lifecycleCallID = "00000000-0000-4000-8000-000000000001"

private struct LifecycleInjectedInterruption: Error {}

private final class LifecycleFailOnce: @unchecked Sendable {
  private let lock = NSLock()
  private let target: PersistenceInterruptionPoint
  private var didFail = false

  init(at target: PersistenceInterruptionPoint) {
    self.target = target
  }

  func callAsFunction(_ point: PersistenceInterruptionPoint) throws {
    lock.lock()
    defer { lock.unlock() }
    if point == target && !didFail {
      didFail = true
      throw LifecycleInjectedInterruption()
    }
  }
}

private func lifecycleRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("trigo-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

@Test func lifecycleEnumsPersistTheExactAcceptedStates() {
  #expect(
    CaptureLifecycleState.allCases.map(\.rawValue) == ["recording", "stopped", "interrupted"])
  #expect(
    UploadLifecycleState.allCases.map(\.rawValue)
      == ["pending", "uploading", "stored", "failed"])
  #expect(
    TranscriptionLifecycleState.allCases.map(\.rawValue)
      == ["waiting_for_audio", "queued", "running", "result_available", "failed"])
  #expect(
    ImportLifecycleState.allCases.map(\.rawValue)
      == ["not_available", "pending", "imported", "failed"])
  #expect(
    ReplicaLifecycleState.allCases.map(\.rawValue) == ["pending", "confirmed", "conflict"])
  #expect(
    DeletionLifecycleState.allCases.map(\.rawValue)
      == ["active", "requested", "draining", "deleting", "complete"])
}

@Test func independentLifecycleDimensionsAndStructuredFailuresSurviveRelaunch() async throws {
  let root = try lifecycleRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try LocalLifecycleStore(root: root, archiveID: lifecycleArchiveID)
  _ = try await store.publish(.initial(archiveID: lifecycleArchiveID, callID: lifecycleCallID))

  let updated = try await store.update(callID: lifecycleCallID) { snapshot in
    snapshot.capture = LifecycleValue(
      state: .interrupted,
      failure: try LifecycleFailure(code: "capture_interrupted", retry: .never))
    snapshot.upload = LifecycleValue(
      state: .failed,
      failure: try LifecycleFailure(code: "upload_unavailable", retry: .retryable))
    snapshot.transcription = LifecycleValue(state: .queued)
    snapshot.importState = LifecycleValue(
      state: .failed,
      failure: try LifecycleFailure(code: "invalid_result", retry: .afterCorrection))
    snapshot.replica = LifecycleValue(
      state: .conflict,
      failure: try LifecycleFailure(code: "version_conflict", retry: .afterCorrection))
    snapshot.deletion = LifecycleValue(state: .draining)
  }

  let relaunched = try LocalLifecycleStore(root: root, archiveID: lifecycleArchiveID)
  let loaded = try #require(try await relaunched.load(callID: lifecycleCallID))
  #expect(loaded == updated)
  #expect(loaded.capture.state == .interrupted)
  #expect(loaded.upload.failure?.retry == .retryable)
  #expect(loaded.transcription.state == .queued)
  #expect(loaded.importState.failure?.code == "invalid_result")
  #expect(loaded.replica.state == .conflict)
  #expect(loaded.deletion.state == .draining)
}

@Test func lifecycleAtomicInterruptionLeavesPriorOrCommittedSnapshot() async throws {
  let root = try lifecycleRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let baseline = try LocalLifecycleStore(root: root, archiveID: lifecycleArchiveID)
  _ = try await baseline.publish(.initial(archiveID: lifecycleArchiveID, callID: lifecycleCallID))

  let beforeReplacement = LifecycleFailOnce(at: .afterLifecycleTemporaryFileSynced)
  let interruptedBefore = try LocalLifecycleStore(
    root: root, archiveID: lifecycleArchiveID,
    interruption: beforeReplacement.callAsFunction)
  await #expect(throws: LifecycleInjectedInterruption.self) {
    try await interruptedBefore.update(callID: lifecycleCallID) {
      $0.upload = LifecycleValue(state: .uploading)
    }
  }

  let relaunchedPrior = try LocalLifecycleStore(root: root, archiveID: lifecycleArchiveID)
  let priorReport = try await relaunchedPrior.reconcile()
  #expect(priorReport.removedTemporaryFiles == 1)
  #expect(try await relaunchedPrior.load(callID: lifecycleCallID)?.stateVersion == 1)

  let afterReplacement = LifecycleFailOnce(at: .afterLifecycleAtomicReplacement)
  let interruptedAfter = try LocalLifecycleStore(
    root: root, archiveID: lifecycleArchiveID,
    interruption: afterReplacement.callAsFunction)
  await #expect(throws: LifecycleInjectedInterruption.self) {
    try await interruptedAfter.update(callID: lifecycleCallID) {
      $0.upload = LifecycleValue(state: .uploading)
    }
  }

  let relaunchedCommitted = try LocalLifecycleStore(root: root, archiveID: lifecycleArchiveID)
  #expect(try await relaunchedCommitted.load(callID: lifecycleCallID)?.stateVersion == 2)
  #expect(try await relaunchedCommitted.load(callID: lifecycleCallID)?.upload.state == .uploading)
}

@Test func lifecycleCorruptionAndForeignIdentityAreRejectedWithoutDeletion() async throws {
  let root = try lifecycleRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try LocalLifecycleStore(root: root, archiveID: lifecycleArchiveID)
  let initial = CallLifecycleSnapshot.initial(
    archiveID: lifecycleArchiveID, callID: lifecycleCallID)
  _ = try await store.publish(initial)
  let foreign = CallLifecycleSnapshot.initial(
    archiveID: "00000000-0000-4000-8000-000000000099", callID: lifecycleCallID)
  await #expect(throws: LocalPersistenceError.self) {
    try await store.publish(foreign)
  }
  #expect(try await store.load(callID: lifecycleCallID) == initial)

  let snapshotURL = root.appendingPathComponent("lifecycle", isDirectory: true)
    .appendingPathComponent(lifecycleCallID).appendingPathExtension("json")
  var object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any])
  var upload = try #require(object["upload"] as? [String: Any])
  upload["failure"] = ["code": "Unstable Code", "retry": "retryable"]
  object["upload"] = upload
  try JSONSerialization.data(withJSONObject: object).write(to: snapshotURL)

  await #expect(throws: LocalPersistenceError.self) {
    try await store.load(callID: lifecycleCallID)
  }
  let report = try await store.reconcile()
  #expect(report.rejectedCallIDs == [lifecycleCallID])
  #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
}

@Test func lifecycleStoredCallIdentityMustMatchItsFilename() async throws {
  let root = try lifecycleRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try LocalLifecycleStore(root: root, archiveID: lifecycleArchiveID)
  _ = try await store.publish(.initial(archiveID: lifecycleArchiveID, callID: lifecycleCallID))
  let snapshotURL = root.appendingPathComponent("lifecycle", isDirectory: true)
    .appendingPathComponent(lifecycleCallID).appendingPathExtension("json")
  var object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: snapshotURL)) as? [String: Any])
  object["callId"] = "00000000-0000-4000-8000-000000000099"
  try JSONSerialization.data(withJSONObject: object).write(to: snapshotURL)

  await #expect(throws: LocalPersistenceError.self) {
    try await store.load(callID: lifecycleCallID)
  }
  let report = try await store.reconcile()
  #expect(report.rejectedCallIDs == [lifecycleCallID])
  #expect(FileManager.default.fileExists(atPath: snapshotURL.path))
}
