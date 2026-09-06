import Foundation
import TrigoContracts

public enum OperationKind: String, Codable, CaseIterable, Sendable {
  case capture
  case upload
  case asr
  case importRevision = "import"
  case replica
  case deletion
}

public enum OperationPhase: String, Codable, Sendable {
  case pending
  case running
  case blocked
  case failed
}

public struct OperationIntent: Sendable, Equatable {
  public let operationID: String
  public let archiveID: String
  public let callID: String
  public let kind: OperationKind
  public let payload: Data

  public init(
    operationID: String, archiveID: String, callID: String, kind: OperationKind,
    payload: Data = Data()
  ) {
    self.operationID = operationID
    self.archiveID = archiveID
    self.callID = callID
    self.kind = kind
    self.payload = payload
  }
}

public struct JournaledOperation: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let operationID: String
  public let archiveID: String
  public let callID: String
  public let kind: OperationKind
  public let payload: Data
  public let payloadSHA256: String
  public let phase: OperationPhase
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64
  public let attempt: Int
  public let lastFailure: LifecycleFailure?
}

public struct JournalReconciliationReport: Sendable, Equatable {
  public let recoverableOperations: [JournaledOperation]
  public let rejectedOperationIDs: [String]
  public let removedTemporaryFiles: Int
}

public actor OperationJournal {
  private let archiveID: String
  private let operationsDirectory: URL
  private let writer: AtomicFileWriter
  private let interruption: PersistenceInterruption

  public init(
    root: URL, archiveID: String,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) throws {
    try requireCanonicalIdentifier(archiveID)
    self.archiveID = archiveID
    self.operationsDirectory = root.appendingPathComponent("operations", isDirectory: true)
    self.writer = AtomicFileWriter(interruption: interruption)
    self.interruption = interruption
    try FileManager.default.createDirectory(
      at: operationsDirectory, withIntermediateDirectories: true)
  }

  /// Durably records intent before a caller is allowed to begin its side effect.
  /// Reusing an operation ID with an identical intent is idempotent; conflicting reuse fails.
  public func recordIntent(_ intent: OperationIntent) throws -> JournaledOperation {
    try validate(intent)
    let destination = operationURL(intent.operationID)
    if FileManager.default.fileExists(atPath: destination.path) {
      let existing = try readOperation(at: destination)
      guard existing.archiveID == intent.archiveID, existing.callID == intent.callID,
        existing.kind == intent.kind, existing.payload == intent.payload
      else {
        throw LocalPersistenceError.operationConflict(intent.operationID)
      }
      try interruption(.afterJournalIntentPersisted)
      return existing
    }

    let now = millisecondsSinceEpoch()
    let operation = JournaledOperation(
      schemaVersion: 1, operationID: intent.operationID, archiveID: intent.archiveID,
      callID: intent.callID, kind: intent.kind, payload: intent.payload,
      payloadSHA256: Contract.hash(intent.payload), phase: .pending,
      createdAtMilliseconds: now, updatedAtMilliseconds: now, attempt: 0,
      lastFailure: nil)
    try write(operation)
    try interruption(.afterJournalIntentPersisted)
    return operation
  }

  public func operation(_ operationID: String) throws -> JournaledOperation? {
    try requireCanonicalIdentifier(operationID)
    let destination = operationURL(operationID)
    guard FileManager.default.fileExists(atPath: destination.path) else { return nil }
    return try readOperation(at: destination)
  }

  /// Returns all valid unacknowledged operations, preserving uncertain `running` work for replay.
  /// A corrupt entry throws instead of being mistaken for an empty journal.
  public func pendingOperations() throws -> [JournaledOperation] {
    let urls = try operationURLs()
    return try urls.map(readOperation).sorted {
      ($0.createdAtMilliseconds, $0.operationID) < ($1.createdAtMilliseconds, $1.operationID)
    }
  }

  @discardableResult
  public func markRunning(_ operationID: String) throws -> JournaledOperation {
    let current = try requiredOperation(operationID)
    return try replace(
      current, phase: .running, attempt: current.attempt + 1, lastFailure: nil)
  }

  @discardableResult
  public func markBlocked(_ operationID: String, failure: LifecycleFailure) throws
    -> JournaledOperation
  {
    let current = try requiredOperation(operationID)
    return try replace(current, phase: .blocked, attempt: current.attempt, lastFailure: failure)
  }

  @discardableResult
  public func markFailed(_ operationID: String, failure: LifecycleFailure) throws
    -> JournaledOperation
  {
    let current = try requiredOperation(operationID)
    return try replace(current, phase: .failed, attempt: current.attempt, lastFailure: failure)
  }

  public func acknowledge(_ operationID: String) throws {
    _ = try requiredOperation(operationID)
    try interruption(.beforeJournalAcknowledgement)
    try writer.remove(operationURL(operationID))
    try interruption(.afterJournalAcknowledgement)
  }

  /// Runs a side effect only after intent and running state are durable.
  /// Success acknowledges the operation; failure remains durable and replayable.
  public func perform<Result: Sendable>(
    _ intent: OperationIntent, failureOnError: LifecycleFailure,
    sideEffect: @Sendable (JournaledOperation) async throws -> Result
  ) async throws -> Result {
    _ = try recordIntent(intent)
    let running = try markRunning(intent.operationID)
    let result: Result
    do {
      result = try await sideEffect(running)
    } catch {
      _ = try? markFailed(intent.operationID, failure: failureOnError)
      throw error
    }
    try acknowledge(intent.operationID)
    return result
  }

  /// Removes incomplete atomic writes and reports corrupt entries without deleting them.
  public func reconcile() throws -> JournalReconciliationReport {
    var removed = 0
    let allFiles = try FileManager.default.contentsOfDirectory(
      at: operationsDirectory, includingPropertiesForKeys: [.isRegularFileKey],
      options: [])
    for url in allFiles
    where url.lastPathComponent.hasPrefix(AtomicFileWriter.temporaryPrefix) {
      try writer.remove(url)
      removed += 1
    }

    var recoverable: [JournaledOperation] = []
    var rejected: [String] = []
    for url in try operationURLs() {
      do {
        recoverable.append(try readOperation(at: url))
      } catch {
        rejected.append(url.deletingPathExtension().lastPathComponent)
      }
    }
    recoverable.sort {
      ($0.createdAtMilliseconds, $0.operationID) < ($1.createdAtMilliseconds, $1.operationID)
    }
    return JournalReconciliationReport(
      recoverableOperations: recoverable, rejectedOperationIDs: rejected.sorted(),
      removedTemporaryFiles: removed)
  }

  private func validate(_ intent: OperationIntent) throws {
    try requireCanonicalIdentifier(intent.operationID)
    try requireCanonicalIdentifier(intent.archiveID)
    try requireCanonicalIdentifier(intent.callID)
    guard intent.archiveID == archiveID else {
      throw LocalPersistenceError.archiveIdentityMismatch(
        expected: archiveID, actual: intent.archiveID)
    }
  }

  private func operationURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: operationsDirectory, includingPropertiesForKeys: [.isRegularFileKey],
      options: []
    ).filter {
      $0.pathExtension == "json"
        && !$0.lastPathComponent.hasPrefix(AtomicFileWriter.temporaryPrefix)
    }
  }

  private func operationURL(_ operationID: String) -> URL {
    operationsDirectory.appendingPathComponent(operationID).appendingPathExtension("json")
  }

  private func requiredOperation(_ operationID: String) throws -> JournaledOperation {
    guard let operation = try operation(operationID) else {
      throw LocalPersistenceError.operationNotFound(operationID)
    }
    return operation
  }

  private func replace(
    _ current: JournaledOperation, phase: OperationPhase, attempt: Int,
    lastFailure: LifecycleFailure?
  ) throws -> JournaledOperation {
    let updated = JournaledOperation(
      schemaVersion: current.schemaVersion, operationID: current.operationID,
      archiveID: current.archiveID, callID: current.callID, kind: current.kind,
      payload: current.payload, payloadSHA256: current.payloadSHA256, phase: phase,
      createdAtMilliseconds: current.createdAtMilliseconds,
      updatedAtMilliseconds: millisecondsSinceEpoch(), attempt: attempt,
      lastFailure: lastFailure)
    try write(updated)
    return updated
  }

  private func write(_ operation: JournaledOperation) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try writer.write(
      encoder.encode(operation), to: operationURL(operation.operationID), domain: .journal)
  }

  private func readOperation(at url: URL) throws -> JournaledOperation {
    let bytes = try Data(contentsOf: url)
    let operation: JournaledOperation
    do {
      operation = try JSONDecoder().decode(JournaledOperation.self, from: bytes)
    } catch {
      throw LocalPersistenceError.invalidStoredDocument(
        "Operation journal entry cannot be decoded")
    }
    guard operation.schemaVersion == 1,
      operation.operationID == url.deletingPathExtension().lastPathComponent,
      operation.archiveID == archiveID, isCanonicalIdentifier(operation.operationID),
      isCanonicalIdentifier(operation.callID), operation.attempt >= 0,
      operation.createdAtMilliseconds <= operation.updatedAtMilliseconds,
      Contract.hash(operation.payload) == operation.payloadSHA256,
      operation.lastFailure.map({ isStableFailureCode($0.code) }) ?? true
    else {
      throw LocalPersistenceError.invalidStoredDocument(
        "Operation journal entry failed validation")
    }
    return operation
  }
}

private func millisecondsSinceEpoch() -> Int64 {
  Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
}
