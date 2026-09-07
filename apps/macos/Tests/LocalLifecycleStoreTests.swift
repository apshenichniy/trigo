import Foundation
import Testing
import TrigoContracts

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
  _ = try await seedRepositoryCall(root: root, archiveID: lifecycleArchiveID)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try LocalRepository(root: root, archiveID: lifecycleArchiveID)
  _ = try await store.publishLifecycle(
    .initial(archiveID: lifecycleArchiveID, callID: lifecycleCallID))

  let updated = try await store.updateLifecycle(callID: lifecycleCallID) { snapshot in
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

  let relaunched = try LocalRepository(root: root, archiveID: lifecycleArchiveID)
  let loaded = try #require(try await relaunched.lifecycle(callID: lifecycleCallID))
  #expect(loaded == updated)
  #expect(loaded.capture.state == .recording)
  #expect(loaded.upload.failure?.retry == .retryable)
  #expect(loaded.transcription.state == .queued)
  #expect(loaded.importState.failure?.code == "invalid_result")
  #expect(loaded.replica.state == .conflict)
  #expect(loaded.deletion.state == .draining)
}

@Test func lifecycleAtomicInterruptionLeavesPriorOrCommittedSnapshot() async throws {
  let root = try lifecycleRoot()
  _ = try await seedRepositoryCall(root: root, archiveID: lifecycleArchiveID)
  defer { try? FileManager.default.removeItem(at: root) }
  let baseline = try LocalRepository(root: root, archiveID: lifecycleArchiveID)
  _ = try await baseline.publishLifecycle(
    .initial(archiveID: lifecycleArchiveID, callID: lifecycleCallID))

  let beforeReplacement = LifecycleFailOnce(at: .beforeRepositoryCommit)
  let interruptedBefore = try LocalRepository(
    root: root, archiveID: lifecycleArchiveID,
    interruption: beforeReplacement.callAsFunction)
  await #expect(throws: LifecycleInjectedInterruption.self) {
    try await interruptedBefore.updateLifecycle(callID: lifecycleCallID) {
      $0.upload = LifecycleValue(state: .uploading)
    }
  }

  let relaunchedPrior = try LocalRepository(root: root, archiveID: lifecycleArchiveID)
  let priorReport = try await relaunchedPrior.inspectArchive()
  #expect(priorReport.validCallIDs == [lifecycleCallID])
  #expect(try await relaunchedPrior.lifecycle(callID: lifecycleCallID)?.stateVersion == 1)

  let afterReplacement = LifecycleFailOnce(at: .afterRepositoryCommit)
  let interruptedAfter = try LocalRepository(
    root: root, archiveID: lifecycleArchiveID,
    interruption: afterReplacement.callAsFunction)
  await #expect(throws: LifecycleInjectedInterruption.self) {
    try await interruptedAfter.updateLifecycle(callID: lifecycleCallID) {
      $0.upload = LifecycleValue(state: .uploading)
    }
  }

  let relaunchedCommitted = try LocalRepository(root: root, archiveID: lifecycleArchiveID)
  #expect(try await relaunchedCommitted.lifecycle(callID: lifecycleCallID)?.stateVersion == 2)
  #expect(
    try await relaunchedCommitted.lifecycle(callID: lifecycleCallID)?.upload.state == .uploading)
}

@Test func lifecycleCorruptionAndForeignIdentityAreRejectedWithoutDeletion() async throws {
  let root = try lifecycleRoot()
  _ = try await seedRepositoryCall(root: root, archiveID: lifecycleArchiveID)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try LocalRepository(root: root, archiveID: lifecycleArchiveID)
  let initial = CallLifecycleSnapshot.initial(
    archiveID: lifecycleArchiveID, callID: lifecycleCallID)
  _ = try await store.publishLifecycle(initial)
  let foreign = CallLifecycleSnapshot.initial(
    archiveID: "00000000-0000-4000-8000-000000000099", callID: lifecycleCallID)
  await #expect(throws: LocalPersistenceError.self) {
    try await store.publishLifecycle(foreign)
  }
  #expect(try await store.lifecycle(callID: lifecycleCallID) == initial)

  try store.database.access {
    try store.database.execute(
      "UPDATE lifecycle SET upload_failure='Unstable Code',upload_retry='retryable' WHERE call_id=?",
      [.text(lifecycleCallID)])
  }

  await #expect(throws: LocalPersistenceError.self) {
    try await store.lifecycle(callID: lifecycleCallID)
  }
  let report = try await store.inspectArchive()
  #expect(report.rejectedCallIDs == [lifecycleCallID])
  #expect(
    FileManager.default.fileExists(
      atPath: root.appendingPathComponent(SQLiteDatabase.filename).path))
}

@Test func lifecycleStoredCallIdentityMustReferenceACanonicalCall() async throws {
  let root = try lifecycleRoot()
  _ = try await seedRepositoryCall(root: root, archiveID: lifecycleArchiveID)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try LocalRepository(root: root, archiveID: lifecycleArchiveID)
  #expect(throws: LocalPersistenceError.self) {
    try store.database.access {
      try store.database.execute(
        "UPDATE lifecycle SET call_id=? WHERE call_id=?",
        [.text("00000000-0000-4000-8000-000000000099"), .text(lifecycleCallID)])
    }
  }
  #expect(try await store.lifecycle(callID: lifecycleCallID)?.capture.state == .recording)
  #expect(try await store.inspectArchive().validCallIDs == [lifecycleCallID])
}
