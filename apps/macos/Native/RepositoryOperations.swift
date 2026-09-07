import Foundation
import TrigoContracts

extension LocalRepository {
  public func recordIntent(_ intent: OperationIntent) async throws -> JournaledOperation {
    let prepared = try await prepareOperation(intent)
    try database.access {
      try database.transaction(interruption: interruption) { try commitOperation(prepared) }
    }
    try interruption(.afterJournalIntentPersisted)
    return try requiredOperation(intent.operationID, includeAcknowledged: true)
  }

  public func operation(_ operationID: String) async throws -> JournaledOperation? {
    try readOperation(operationID, includeAcknowledged: false)
  }

  /// Uncertain running work remains replayable under the original identity. Paging bounds
  /// the SQL reader; payload integrity is checked after releasing the connection.
  public func pendingOperations() async throws -> [JournaledOperation] {
    let ids = try operationIDs()
    return try ids.compactMap { try readOperation($0, includeAcknowledged: false) }
  }

  public func inspectOperations() async throws -> RepositoryOperationReport {
    var report = RepositoryOperationReport()
    for id in try operationIDs() {
      do {
        if let operation = try readOperation(id, includeAcknowledged: false) {
          report.recoverableOperations.append(operation)
        }
      } catch { report.rejectedOperationIDs.append(id) }
    }
    return report
  }

  @discardableResult public func markRunning(
    _ operationID: String
  ) async throws
    -> JournaledOperation
  {
    try await changeOperation(operationID, phase: .running, incrementAttempt: true, failure: nil)
  }

  @discardableResult public func markBlocked(
    _ operationID: String,
    failure: LifecycleFailure
  )
    async throws -> JournaledOperation
  {
    try await changeOperation(
      operationID,
      phase: .blocked,
      incrementAttempt: false,
      failure: failure
    )
  }

  @discardableResult public func markFailed(
    _ operationID: String,
    failure: LifecycleFailure
  )
    async throws -> JournaledOperation
  {
    try await changeOperation(
      operationID,
      phase: .failed,
      incrementAttempt: false,
      failure: failure
    )
  }

  public func acknowledge(_ operationID: String) async throws {
    _ = try requiredOperation(operationID, includeAcknowledged: true)
    try interruption(.beforeJournalAcknowledgement)
    try database.access {
      try database.transaction(interruption: interruption) {
        // Retained tombstones prevent reusing an acknowledged immutable operation identity.
        try database.execute(
          "UPDATE operations SET acknowledged=1 WHERE operation_id=?",
          [.text(operationID)]
        )
      }
    }
    try interruption(.afterJournalAcknowledgement)
  }

  public func perform<Result: Sendable>(
    _ intent: OperationIntent,
    failureOnError: LifecycleFailure,
    sideEffect: @Sendable (JournaledOperation) async throws -> Result
  ) async throws -> Result {
    let recorded = try await recordIntent(intent)
    guard !recorded.acknowledged else {
      throw LocalPersistenceError.operationAlreadyAcknowledged(intent.operationID)
    }
    let running = try await markRunning(intent.operationID)
    let result: Result
    do { result = try await sideEffect(running) } catch {
      _ = try? await markFailed(intent.operationID, failure: failureOnError)
      throw error
    }
    try await acknowledge(intent.operationID)
    return result
  }

  func prepareOperation(_ intent: OperationIntent) async throws -> PreparedOperation {
    try requireCanonicalIdentifier(intent.operationID)
    try requireCanonicalIdentifier(intent.callID)
    try requireArchiveIdentity(intent.archiveID)
    let hash = try await stageDocument(intent.payload)
    return .init(intent: intent, payloadHash: hash, createdMs: millisecondsSinceEpoch())
  }

  func commitOperation(_ prepared: PreparedOperation) throws {
    let intent = prepared.intent
    if let row =
      try database.rows(
        "SELECT call_id,kind,payload_hash FROM operations WHERE operation_id=?",
        [.text(intent.operationID)]
      )
      .first
    {
      guard try row.string(0) == intent.callID, try row.string(1) == intent.kind.rawValue,
        try row.string(2) == prepared.payloadHash
      else {
        throw LocalPersistenceError.operationConflict(intent.operationID)
      }
      return
    }
    try database.execute(
      "INSERT INTO operations VALUES (?,?,?,?,'pending',?,?,0,NULL,NULL,0)",
      [
        .text(intent.operationID), .text(intent.callID), .text(intent.kind.rawValue),
        .text(prepared.payloadHash),
        .integer(prepared.createdMs), .integer(prepared.createdMs),
      ]
    )
  }

  private func operationIDs() throws -> [String] {
    var result: [String] = []
    var timestamp: Int64 = -1
    var id = ""
    while true {
      let page = try database.access {
        try database.rows(
          "SELECT operation_id,created_ms FROM operations WHERE acknowledged=0 AND (created_ms,operation_id)>(?,?) ORDER BY created_ms,operation_id LIMIT 128",
          [.integer(timestamp), .text(id)]
        )
      }
      for row in page { result.append(try row.string(0)) }
      if page.count < 128 { return result }
      id = try page.last!.string(0)
      timestamp = try page.last!.integer(1)
    }
  }

  private func readOperation(_ id: String, includeAcknowledged: Bool) throws -> JournaledOperation?
  {
    try requireCanonicalIdentifier(id)
    guard
      let storedRow = try database.access({
        try database.rows(
          "SELECT call_id,kind,payload_hash,phase,created_ms,updated_ms,attempt,failure,retry,acknowledged FROM operations WHERE operation_id=?",
          [.text(id)]
        )
        .first
      })
    else { return nil }
    let row = try resolveTextValues(storedRow)
    let acknowledged = try row.int(9) == 1
    if acknowledged && !includeAcknowledged { return nil }
    let callID = try row.string(0)
    try requireCanonicalIdentifier(callID)
    guard let kind = try OperationKind(rawValue: row.string(1)),
      let phase = try OperationPhase(rawValue: row.string(3)),
      try row.int(6) >= 0, try row.integer(4) <= row.integer(5)
    else { throw invalidRow() }
    let hash = try row.string(2)
    return try .init(
      schemaVersion: 1,
      operationID: id,
      archiveID: archiveID,
      callID: callID,
      kind: kind,
      payload: documentBytes(hash),
      payloadSHA256: hash,
      phase: phase,
      createdAtMilliseconds: row.integer(4),
      updatedAtMilliseconds: row.integer(5),
      attempt: row.int(6),
      lastFailure: failure(row, index: 7),
      acknowledged: acknowledged
    )
  }

  private func requiredOperation(
    _ id: String,
    includeAcknowledged: Bool = false
  ) throws
    -> JournaledOperation
  {
    guard let operation = try readOperation(id, includeAcknowledged: includeAcknowledged) else {
      throw LocalPersistenceError.operationNotFound(id)
    }
    return operation
  }

  private func changeOperation(
    _ id: String,
    phase: OperationPhase,
    incrementAttempt: Bool,
    failure: LifecycleFailure?
  ) async throws -> JournaledOperation {
    _ = try requiredOperation(id)
    if let failure, !isStableFailureCode(failure.code) {
      throw LocalPersistenceError.invalidFailureCode(failure.code)
    }
    let values = try await prepareTextValues([
      .text(phase.rawValue), .int(incrementAttempt ? 1 : 0), .integer(millisecondsSinceEpoch()),
      .string(failure?.code), .string(failure?.retry.rawValue), .text(id),
    ])
    try database.access {
      try database.transaction(interruption: interruption) {
        guard
          let row =
            try database.rows(
              "SELECT acknowledged FROM operations WHERE operation_id=?",
              [.text(id)]
            )
            .first,
          try row.int(0) == 0
        else { throw LocalPersistenceError.operationNotFound(id) }
        try database.execute(
          "UPDATE operations SET phase=?,attempt=attempt+?,updated_ms=max(updated_ms,?),failure=?,retry=? WHERE operation_id=?",
          values
        )
      }
    }
    return try requiredOperation(id)
  }
}

struct PreparedOperation: Sendable {
  let intent: OperationIntent
  let payloadHash: String
  let createdMs: Int64
}

public struct RepositoryOperationReport: Sendable {
  public var recoverableOperations: [JournaledOperation] = []
  public var rejectedOperationIDs: [String] = []
}

private func millisecondsSinceEpoch() -> Int64 {
  Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
}
