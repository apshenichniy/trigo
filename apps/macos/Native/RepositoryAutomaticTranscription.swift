import Foundation
import TrigoContracts

public enum AutomaticTranscriptionLanguage: String, Sendable, CaseIterable {
  case russian = "ru"
  case english = "en"
  public static let preferenceKey = "initialTranscriptionLanguage"
}

public struct AutomaticTranscriptionState: Sendable {
  public let request: RequestTranscription
  public let operation: TranscriptionOperation?
  public let recoveryAttempted: Bool
  public let recoveryPending: Bool
}

extension LocalRepository {
  /// One initial logical request per call. Transport uncertainty replays these same IDs;
  /// an exhausted/permanent attempt is not replaced with another automatic operation.
  public func ensureAutomaticTranscription(
    callID: String,
    language: String
  ) async throws -> AutomaticTranscriptionState? {
    if let existing = try automaticTranscription(callID: callID) { return existing }
    let call = try await call(callID: callID)
    guard call.activeRevisionId == nil, call.captureState != "recording",
      try verifiedMasterReceipt(callID: callID) != nil,
      let observation = try observedReplica(callID: callID),
      try currentHash(callID) == observation.hash,
      language == "en" || language == "ru"
    else { return nil }
    let request = RequestTranscription(
      schemaVersion: 1,
      operationId: synchronizationIdentity("trigo-initial-transcription:\(archiveID):\(callID)"),
      revisionId: synchronizationIdentity("trigo-initial-revision:\(archiveID):\(callID)"),
      requestedLanguage: language,
      profileId: "nova3-wav-s16le-16000-stereo-stream-v1"
    )
    let bytes = try Contract.encode(request)
    let prepared = try await prepareOperation(
      .init(
        operationID: request.operationId,
        archiveID: archiveID,
        callID: callID,
        kind: .asr,
        payload: bytes
      )
    )
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        guard try currentHashLocked(callID) == observation.hash else {
          throw LocalPersistenceError.concurrentMutation
        }
        try commitOperation(prepared)
        try database.execute(
          "INSERT OR IGNORE INTO automatic_transcriptions(call_id,operation_id,revision_id,request_hash) VALUES (?,?,?,?)",
          [
            .text(callID), .text(request.operationId), .text(request.revisionId),
            .text(prepared.payloadHash),
          ]
        )
        try database.execute(
          "UPDATE lifecycle SET transcription='queued',transcription_failure=NULL,transcription_retry=NULL,state_version=state_version+1 WHERE call_id=?",
          [.text(callID)]
        )
      }
    }
    return try automaticTranscription(callID: callID)
  }

  public func automaticTranscription(callID: String) throws -> AutomaticTranscriptionState? {
    guard
      let row = try database.access({
        try database.rows(
          "SELECT request_hash,remote_hash,recovery_attempted,recovery_pending FROM automatic_transcriptions WHERE call_id=?",
          [.text(callID)]
        )
        .first
      })
    else { return nil }
    let request =
      try Contract.decode(RequestTranscription.self, bytes: documentBytes(row.string(0))).value
    let operation = try row.optionalString(1)
      .map { try Contract.decode(TranscriptionOperation.self, bytes: documentBytes($0)).value }
    return try .init(
      request: request,
      operation: operation,
      recoveryAttempted: row.int(2) == 1,
      recoveryPending: row.int(3) == 1
    )
  }

  /// This records provider-operation state only. It never acknowledges local import or replica.
  public func acceptTranscriptionOperation(
    _ input: TranscriptionOperation,
    callID: String
  ) async throws {
    let document = try Contract.decode(TranscriptionOperation.self, bytes: Contract.encode(input))
    guard input.archiveId == archiveID, input.callId == callID,
      (input.state == "result_available") == (input.result != nil),
      input.result == nil || input.result?.revisionId == input.revisionId,
      input.state != "failed" || input.failure != nil
    else { throw CanonicalSyncError.invalidResult }
    let failure = try input.failure.map {
      try LifecycleFailure(
        code: $0.code,
        retry: LifecycleRetryClassification(rawValue: $0.retry) ?? .afterCorrection
      )
    }
    if try observedTranscription(callID: callID) == input,
      try await lifecycle(callID: callID)?.transcription.failure == failure
    {
      return
    }
    let hash = try await stageDocument(document.storedBytes)
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        try database.execute(
          "INSERT INTO server_transcription_observations VALUES (?,?) ON CONFLICT(call_id) DO UPDATE SET hash=excluded.hash",
          [.text(callID), .text(hash)]
        )
        if let row =
          try database.rows(
            "SELECT operation_id,revision_id FROM automatic_transcriptions WHERE call_id=?",
            [.text(callID)]
          )
          .first
        {
          if try row.string(0) == input.operationId {
            guard try row.string(1) == input.revisionId else {
              throw CanonicalSyncError.invalidResult
            }
            try database.execute(
              "UPDATE automatic_transcriptions SET remote_hash=? WHERE call_id=?",
              [.text(hash), .text(callID)]
            )
            if input.state == "failed" || input.state == "result_available" {
              try database.execute(
                "UPDATE operations SET acknowledged=1 WHERE operation_id=?",
                [.text(input.operationId)]
              )
            }
          }
        }
        try database.execute(
          "UPDATE lifecycle SET transcription=?,transcription_failure=?,transcription_retry=?,state_version=state_version+1 WHERE call_id=?",
          [
            .text(input.state), .string(input.failure?.code), .string(input.failure?.retry),
            .text(callID),
          ]
        )
      }
    }
  }

  public func observedTranscription(callID: String) throws -> TranscriptionOperation? {
    let hash = try database.access {
      try database
        .rows("SELECT hash FROM server_transcription_observations WHERE call_id=?", [.text(callID)])
        .first?
        .string(0)
    }
    return try hash.map {
      try Contract.decode(TranscriptionOperation.self, bytes: documentBytes($0)).value
    }
  }

  public func reserveTranscriptionRecovery(
    callID: String,
    afterCorrection: Bool = false
  ) throws -> Bool {
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        guard
          let row =
            try database.rows(
              "SELECT recovery_attempted FROM automatic_transcriptions WHERE call_id=?",
              [.text(callID)]
            )
            .first, try row.int(0) == 0 || afterCorrection
        else { return false }
        try database.execute(
          "UPDATE automatic_transcriptions SET recovery_attempted=1,recovery_pending=1 WHERE call_id=?",
          [.text(callID)]
        )
        return true
      }
    }
  }

  public func acknowledgeTranscriptionRecovery(callID: String) throws {
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        try database.execute(
          "UPDATE automatic_transcriptions SET recovery_pending=0 WHERE call_id=?",
          [.text(callID)]
        )
      }
    }
  }
}
