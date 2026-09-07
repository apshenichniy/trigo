import Foundation

extension LocalRepository {
  public func lifecycle(callID: String) async throws -> CallLifecycleSnapshot? {
    try requireCanonicalIdentifier(callID)
    guard let row = try database.access({ try lifecycleRow(callID) }) else { return nil }
    return try decodeLifecycle(resolveTextValues(row), callID: callID)
  }

  /// The five processing axes may change independently. Capture is read-only here; only
  /// canonical admission/finalization mutations can change its state or failure reason.
  public func updateLifecycle(
    callID: String,
    _ change: @Sendable (inout CallLifecycleSnapshot) throws -> Void
  ) async throws -> CallLifecycleSnapshot {
    guard var value = try await lifecycle(callID: callID) else {
      throw LocalPersistenceError.lifecycleNotFound(callID)
    }
    let prior = value
    try change(&value)
    guard value.capture == prior.capture else {
      throw LocalPersistenceError.captureStateOwnedByRepository
    }
    let proposed = value.advancingVersion(to: prior.stateVersion + 1)
    _ = try await publishLifecycle(proposed)
    return proposed
  }

  public func publishLifecycle(_ proposed: CallLifecycleSnapshot) async throws -> PublicationResult
  {
    try requireArchiveIdentity(proposed.archiveID)
    try requireCanonicalIdentifier(proposed.callID)
    guard proposed.schemaVersion == 1, proposed.stateVersion > 0 else { throw invalidRow() }
    try validateFailures(proposed)
    guard let current = try await lifecycle(callID: proposed.callID) else {
      throw LocalPersistenceError.lifecycleNotFound(proposed.callID)
    }
    if proposed == current { return .alreadyPresent }
    guard proposed.capture == current.capture else {
      throw LocalPersistenceError.captureStateOwnedByRepository
    }
    guard proposed.stateVersion == current.stateVersion + 1 else {
      throw LocalPersistenceError.staleDocumentVersion(
        current: current.stateVersion,
        proposed: proposed.stateVersion
      )
    }
    let values = try await prepareTextValues(lifecycleValues(proposed))
    return try database.access {
      try database.transaction(interruption: interruption) {
        guard let row = try lifecycleRow(proposed.callID), try row.int(0) == current.stateVersion
        else { throw LocalPersistenceError.concurrentMutation }
        try database.execute("DELETE FROM lifecycle WHERE call_id=?", [.text(proposed.callID)])
        try database.execute(
          "INSERT INTO lifecycle VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
          values
        )
        return .committed
      }
    }
  }

  func insertLifecycle(_ value: CallLifecycleSnapshot) throws {
    try database.execute(
      "INSERT INTO lifecycle VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      lifecycleValues(value)
    )
  }

  private func lifecycleValues(_ value: CallLifecycleSnapshot) -> [SQLValue] {
    [
      .text(value.callID), .int(value.stateVersion),
    ] + axis(value.upload.state.rawValue, value.upload.failure)
      + axis(value.transcription.state.rawValue, value.transcription.failure)
      + axis(value.importState.state.rawValue, value.importState.failure)
      + axis(value.replica.state.rawValue, value.replica.failure)
      + axis(value.deletion.state.rawValue, value.deletion.failure)
  }

  private func lifecycleRow(_ callID: String) throws -> SQLRow? {
    try database.rows(
      """
      SELECT l.state_version,v.capture_state,v.reason,
      l.upload,l.upload_failure,l.upload_retry,
      l.transcription,l.transcription_failure,l.transcription_retry,
      l.import_state,l.import_failure,l.import_retry,
      l.replica,l.replica_failure,l.replica_retry,
      l.deletion,l.deletion_failure,l.deletion_retry
      FROM lifecycle l JOIN calls c ON c.call_id=l.call_id JOIN call_values v ON v.hash=c.hash
      WHERE l.call_id=?
      """,
      [.text(callID)]
    )
    .first
  }

  private func decodeLifecycle(_ row: SQLRow, callID: String) throws -> CallLifecycleSnapshot {
    guard let upload = try UploadLifecycleState(rawValue: row.string(3)),
      let transcription = try TranscriptionLifecycleState(rawValue: row.string(6)),
      let importState = try ImportLifecycleState(rawValue: row.string(9)),
      let replica = try ReplicaLifecycleState(rawValue: row.string(12)),
      let deletion = try DeletionLifecycleState(rawValue: row.string(15))
    else { throw invalidRow() }
    return try .init(
      archiveID: archiveID,
      callID: callID,
      stateVersion: row.int(0),
      capture: .init(
        state: captureState(row.string(1)),
        failure: row.optionalString(2).map { try LifecycleFailure(code: $0, retry: .never) }
      ),
      upload: .init(state: upload, failure: failure(row, index: 4)),
      transcription: .init(state: transcription, failure: failure(row, index: 7)),
      importState: .init(state: importState, failure: failure(row, index: 10)),
      replica: .init(state: replica, failure: failure(row, index: 13)),
      deletion: .init(state: deletion, failure: failure(row, index: 16))
    )
  }

  private func validateFailures(_ value: CallLifecycleSnapshot) throws {
    for failure in [
      value.capture.failure, value.upload.failure, value.transcription.failure,
      value.importState.failure, value.replica.failure, value.deletion.failure,
    ]
    .compactMap({ $0 }) {
      guard isStableFailureCode(failure.code) else {
        throw LocalPersistenceError.invalidFailureCode(failure.code)
      }
    }
  }
}

func axis(_ state: String, _ failure: LifecycleFailure?) -> [SQLValue] {
  [.text(state), .string(failure?.code), .string(failure?.retry.rawValue)]
}

func failure(_ row: SQLRow, index: Int) throws -> LifecycleFailure? {
  let code = try row.optionalString(index)
  let retry = try row.optionalString(index + 1)
  guard let code else {
    guard retry == nil else { throw invalidRow() }
    return nil
  }
  guard let retry, let classification = LifecycleRetryClassification(rawValue: retry) else {
    throw invalidRow()
  }
  return try LifecycleFailure(code: code, retry: classification)
}
