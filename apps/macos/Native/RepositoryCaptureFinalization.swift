import Foundation
import TrigoContracts

extension LocalRepository {
  /// Retain caller work as part of the session's finalization intent, before external
  /// final sync when supplied by the caller. It is not runnable until final publication.
  /// Only operation identity/payload are retained; media and canonical metadata have one owner.
  public func prepareCaptureFinalization(
    callID: String,
    reason: String?,
    associatedWork: OperationIntent? = nil
  ) async throws {
    try requireCaptureInterruptionReason(reason)
    if let associatedWork, associatedWork.callID != callID { throw ContractError.reference }
    let prepared = try await associatedWork.mapAsync { try await prepareOperation($0) }
    try database.access(capture: true) {
      try database.transaction {
        guard
          let row =
            try database.rows(
              "SELECT final_work_id,final_work_kind,final_work_payload_hash,final_work_prepared FROM sessions WHERE call_id=?",
              [.text(callID)]
            )
            .first
        else { throw LocalPersistenceError.callNotFound(callID) }
        if try row.int(3) == 1 {
          if let prepared {
            guard try row.optionalString(0) == prepared.intent.operationID,
              try row.optionalString(1) == prepared.intent.kind.rawValue,
              try row.optionalString(2) == prepared.payloadHash
            else {
              throw LocalPersistenceError.operationConflict(prepared.intent.operationID)
            }
          }
        } else {
          try database.execute(
            "UPDATE sessions SET final_work_id=?,final_work_kind=?,final_work_payload_hash=?,final_work_prepared=1 WHERE call_id=?",
            [
              .string(prepared?.intent.operationID), .string(prepared?.intent.kind.rawValue),
              .string(prepared?.payloadHash), .text(callID),
            ]
          )
        }
        try database.execute(
          "UPDATE sessions SET stop_requested=1,stop_reason=? WHERE call_id=? AND stop_requested=0",
          [.string(reason), .text(callID)]
        )
      }
    }
  }

  func prepareCapturePublication(
    callID: String,
    reason: String?,
    associatedWork: OperationIntent?
  ) async throws -> (operation: PreparedOperation?, reason: String?) {
    try await prepareCaptureFinalization(
      callID: callID,
      reason: reason,
      associatedWork: associatedWork
    )
    let retained = try captureFinalizationWork(callID: callID)
    let operation = try await retained.mapAsync { try await prepareOperation($0) }
    let effectiveReason =
      try captureStopRequest(callID: callID)?.reason ?? captureMediaFailure(callID: callID)
    return (operation, effectiveReason)
  }

  func captureFinalizationWork(callID: String) throws -> OperationIntent? {
    guard
      let row = try database.access({
        try database.rows(
          "SELECT final_work_id,final_work_kind,final_work_payload_hash FROM sessions WHERE call_id=?",
          [.text(callID)]
        )
        .first
      })
    else { throw LocalPersistenceError.callNotFound(callID) }
    guard let id = try row.optionalString(0) else { return nil }
    guard let kind = try OperationKind(rawValue: row.string(1)) else { throw invalidRow() }
    return try .init(
      operationID: id,
      archiveID: archiveID,
      callID: callID,
      kind: kind,
      payload: documentBytes(row.string(2))
    )
  }

  public func finalizeCapture(
    _ session: CaptureArchiveSession,
    master: FinalizedMediaMaster?,
    reason: String?,
    associatedWork: OperationIntent? = nil,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) async throws -> LocalCallAggregate {
    _ = try await completeCapture(
      session,
      master: master,
      reason: reason,
      associatedWork: associatedWork,
      interruption: interruption
    )
    return try await loadCall(callID: session.callID)
  }

  /// One-time exchange projection. Capture progress never calls this or retains its result.
  /// Reads release the capture scheduler per bounded commit and merge adjacent equal states.
  func captureIntervals(
    callID: String,
    through cursor: MediaMasterCursor?
  ) throws
    -> [[CaptureInterval]]
  {
    var result: [[CaptureInterval]] = [[], []]
    guard let cursor else { return result }
    guard
      try (confirmedMediaCursor(callID: callID) ?? initialCursor(masterIdentity(callID))) == cursor
    else {
      throw LocalPersistenceError.invalidMediaProgress
    }
    for sequence in 1..<(cursor.commitCount + 1) {
      guard let commit = try mediaCommit(callID: callID, sequence: sequence) else {
        throw LocalPersistenceError.invalidMediaProgress
      }
      for span in commit.microphoneIntervals { mergeCaptureInterval(span, into: &result[0]) }
      for span in commit.applicationIntervals { mergeCaptureInterval(span, into: &result[1]) }
    }
    return result
  }
}
