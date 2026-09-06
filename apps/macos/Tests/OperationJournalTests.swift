import Foundation
import Testing

@testable import TrigoNative

private let journalArchiveID = "00000000-0000-4000-8000-000000000012"
private let journalCallID = "00000000-0000-4000-8000-000000000001"

private struct JournalSideEffectFailure: Error {}
private struct JournalInjectedInterruption: Error {}

private final class JournalFailOnce: @unchecked Sendable {
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
      throw JournalInjectedInterruption()
    }
  }
}

private func journalRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("trigo-journal-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func intent(_ kind: OperationKind, suffix: Int) -> OperationIntent {
  OperationIntent(
    operationID: String(format: "00000000-0000-4000-8000-%012d", suffix),
    archiveID: journalArchiveID,
    callID: journalCallID,
    kind: kind,
    payload: Data("{\"fixture\":\(suffix)}".utf8))
}

@Test func everyLifecycleOwnsAnIndependentDurableStateAcrossRelaunch() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let journal = try OperationJournal(root: root, archiveID: journalArchiveID)
  let kinds = OperationKind.allCases

  for (index, kind) in kinds.enumerated() {
    let operation = try await journal.recordIntent(intent(kind, suffix: index + 1))
    switch index % 4 {
    case 0: _ = try await journal.markRunning(operation.operationID)
    case 1:
      _ = try await journal.markBlocked(
        operation.operationID,
        failure: LifecycleFailure(code: "offline", retry: .retryable))
    case 2:
      _ = try await journal.markFailed(
        operation.operationID,
        failure: LifecycleFailure(code: "provider_failed", retry: .retryable))
    default: break
    }
  }

  let relaunched = try OperationJournal(root: root, archiveID: journalArchiveID)
  let operations = try await relaunched.pendingOperations()
  #expect(Set(operations.map(\.kind)) == Set(kinds))
  #expect(
    Dictionary(uniqueKeysWithValues: operations.map { ($0.kind, $0.phase) })[.capture] == .running)
  #expect(
    Dictionary(uniqueKeysWithValues: operations.map { ($0.kind, $0.phase) })[.upload] == .blocked)
  #expect(Dictionary(uniqueKeysWithValues: operations.map { ($0.kind, $0.phase) })[.asr] == .failed)
  #expect(
    Dictionary(uniqueKeysWithValues: operations.map { ($0.kind, $0.phase) })[.importRevision]
      == .pending)
}

@Test func sideEffectsRunOnlyAfterIntentIsDurableAndFailuresRemainRecoverable() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let journal = try OperationJournal(root: root, archiveID: journalArchiveID)
  let operationIntent = intent(.deletion, suffix: 20)
  let stableFailure = try LifecycleFailure(code: "side_effect_failed", retry: .retryable)

  await #expect(throws: JournalSideEffectFailure.self) {
    try await journal.perform(operationIntent, failureOnError: stableFailure) { recorded in
      let visible = try await journal.operation(recorded.operationID)
      #expect(visible?.phase == .running)
      throw JournalSideEffectFailure()
    }
  }

  let relaunched = try OperationJournal(root: root, archiveID: journalArchiveID)
  let retained = try #require(try await relaunched.operation(operationIntent.operationID))
  #expect(retained.phase == .failed)
  #expect(retained.lastFailure == stableFailure)
}

@Test func interruptionBeforeAcknowledgementLeavesReplayableWork() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let failOnce = JournalFailOnce(at: .beforeJournalAcknowledgement)
  let interrupted = try OperationJournal(
    root: root, archiveID: journalArchiveID, interruption: failOnce.callAsFunction)
  let operationIntent = intent(.replica, suffix: 21)
  let stableFailure = try LifecycleFailure(code: "replica_failed", retry: .retryable)

  await #expect(throws: JournalInjectedInterruption.self) {
    try await interrupted.perform(operationIntent, failureOnError: stableFailure) { _ in
      "replicated"
    }
  }

  let relaunched = try OperationJournal(root: root, archiveID: journalArchiveID)
  #expect(try await relaunched.operation(operationIntent.operationID)?.phase == .running)
  let result = try await relaunched.perform(operationIntent, failureOnError: stableFailure) {
    operation in
    #expect(operation.attempt == 2)
    return "replicated"
  }
  #expect(result == "replicated")
  #expect(try await relaunched.operation(operationIntent.operationID) == nil)
}

@Test func interruptionAfterIntentPersistencePreventsTheSideEffect() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let failOnce = JournalFailOnce(at: .afterJournalIntentPersisted)
  let journal = try OperationJournal(
    root: root, archiveID: journalArchiveID, interruption: failOnce.callAsFunction)
  let operationIntent = intent(.upload, suffix: 22)
  let sideEffectRan = LockedFlag()
  let stableFailure = try LifecycleFailure(code: "upload_failed", retry: .retryable)

  await #expect(throws: JournalInjectedInterruption.self) {
    try await journal.perform(operationIntent, failureOnError: stableFailure) { _ in
      sideEffectRan.set()
      return ()
    }
  }

  #expect(!sideEffectRan.value)
  let relaunched = try OperationJournal(root: root, archiveID: journalArchiveID)
  #expect(try await relaunched.operation(operationIntent.operationID)?.phase == .pending)
}

@Test func relaunchDiscardsAnIncompleteJournalFileBeforeIntentPublication() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let failOnce = JournalFailOnce(at: .afterJournalTemporaryFileSynced)
  let interrupted = try OperationJournal(
    root: root, archiveID: journalArchiveID, interruption: failOnce.callAsFunction)

  await #expect(throws: JournalInjectedInterruption.self) {
    try await interrupted.recordIntent(intent(.capture, suffix: 23))
  }

  let relaunched = try OperationJournal(root: root, archiveID: journalArchiveID)
  let report = try await relaunched.reconcile()
  #expect(report.removedTemporaryFiles == 1)
  #expect(report.recoverableOperations.isEmpty)
}

@Test func interruptionAfterAcknowledgementDoesNotCreatePhantomPendingWork() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let failOnce = JournalFailOnce(at: .afterJournalAcknowledgement)
  let interrupted = try OperationJournal(
    root: root, archiveID: journalArchiveID, interruption: failOnce.callAsFunction)
  let operationIntent = intent(.importRevision, suffix: 24)
  let stableFailure = try LifecycleFailure(code: "import_failed", retry: .afterCorrection)

  await #expect(throws: JournalInjectedInterruption.self) {
    try await interrupted.perform(operationIntent, failureOnError: stableFailure) { _ in () }
  }

  let relaunched = try OperationJournal(root: root, archiveID: journalArchiveID)
  #expect(try await relaunched.operation(operationIntent.operationID) == nil)
}

@Test func corruptJournalEntryIsRejectedWithoutHidingOtherPendingWork() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let journal = try OperationJournal(root: root, archiveID: journalArchiveID)
  let valid = intent(.asr, suffix: 25)
  let corrupted = intent(.upload, suffix: 26)
  _ = try await journal.recordIntent(valid)
  _ = try await journal.recordIntent(corrupted)

  let corruptedURL = root.appendingPathComponent("operations", isDirectory: true)
    .appendingPathComponent(corrupted.operationID).appendingPathExtension("json")
  var object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: corruptedURL)) as? [String: Any])
  object["payloadSHA256"] = String(repeating: "0", count: 64)
  try JSONSerialization.data(withJSONObject: object).write(to: corruptedURL)

  await #expect(throws: LocalPersistenceError.self) {
    try await journal.pendingOperations()
  }
  let report = try await journal.reconcile()
  #expect(report.recoverableOperations.map(\.operationID) == [valid.operationID])
  #expect(report.rejectedOperationIDs == [corrupted.operationID])
  #expect(try Data(contentsOf: corruptedURL).isEmpty == false)
}

@Test func malformedOperationFilenameIsReportedInsteadOfSilentlyIgnored() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let journal = try OperationJournal(root: root, archiveID: journalArchiveID)
  let malformedURL = root.appendingPathComponent("operations", isDirectory: true)
    .appendingPathComponent("unknown.json")
  try Data("{}".utf8).write(to: malformedURL)

  await #expect(throws: LocalPersistenceError.self) {
    try await journal.pendingOperations()
  }
  let report = try await journal.reconcile()
  #expect(report.rejectedOperationIDs == ["unknown"])
  #expect(FileManager.default.fileExists(atPath: malformedURL.path))
}

@Test func operationIdentityIsIdempotentButCannotBeReusedForAnotherIntent() async throws {
  let root = try journalRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let journal = try OperationJournal(root: root, archiveID: journalArchiveID)
  let original = intent(.upload, suffix: 27)
  let first = try await journal.recordIntent(original)
  let duplicate = try await journal.recordIntent(original)
  #expect(duplicate == first)

  let conflict = OperationIntent(
    operationID: original.operationID, archiveID: original.archiveID,
    callID: original.callID, kind: .deletion, payload: original.payload)
  await #expect(throws: LocalPersistenceError.self) {
    try await journal.recordIntent(conflict)
  }
  #expect(try await journal.operation(original.operationID) == first)
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false

  var value: Bool {
    lock.withLock { storage }
  }

  func set() {
    lock.withLock { storage = true }
  }
}
