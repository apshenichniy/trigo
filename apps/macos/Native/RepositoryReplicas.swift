import Foundation
import TrigoContracts

extension LocalRepository {
  /// Finalized metadata is confirmed before the initial ASR command. That base makes a
  /// result completed while this Mac is away restorable without inventing capture metadata.
  public func ensureCanonicalReplica(callID: String) async throws {
    guard let hash = try currentHash(callID) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    let snapshot = try storedCall(hash: hash)
    guard snapshot.value.captureState != "recording",
      try verifiedMasterReceipt(callID: callID) != nil
    else { return }
    if try observedReplica(callID: callID)?.hash == hash { return }
    let exists = try database.access {
      try
        !database.rows(
          "SELECT operation_id FROM canonical_replica_work WHERE call_id=? AND document_version=?",
          [.text(callID), .int(snapshot.value.documentVersion)]
        )
        .isEmpty
    }
    if exists { return }
    let operation = try await prepareOperation(
      .init(
        operationID: synchronizationIdentity("trigo-replica:\(archiveID):\(callID):\(hash)"),
        archiveID: archiveID,
        callID: callID,
        kind: .replica,
        payload: snapshot.storedBytes
      )
    )
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        guard try currentHashLocked(callID) == hash else {
          throw LocalPersistenceError.concurrentMutation
        }
        try commitReplicaWork(operation, snapshot: snapshot, annotationRevisionIDs: [])
      }
    }
  }

  func commitReplicaWork(
    _ prepared: PreparedOperation,
    snapshot: StoredDocument<CallDocument>,
    annotationRevisionIDs: Set<String>
  ) throws {
    let id = prepared.intent.operationID
    try requireActiveCallLocked(snapshot.value.callId)
    guard prepared.intent.kind == .replica, prepared.intent.callID == snapshot.value.callId else {
      throw LocalPersistenceError.operationConflict(id)
    }
    try commitOperation(prepared)
    if let prior =
      try database.rows(
        "SELECT snapshot_hash FROM canonical_replica_work WHERE operation_id=?",
        [.text(id)]
      )
      .first
    {
      guard try prior.string(0) == snapshot.sha256 else {
        throw LocalPersistenceError.operationConflict(id)
      }
      return
    }
    try database.execute(
      "INSERT INTO canonical_replica_work(operation_id,call_id,snapshot_hash,document_version) VALUES (?,?,?,?)",
      [
        .text(id), .text(snapshot.value.callId), .text(snapshot.sha256),
        .int(snapshot.value.documentVersion),
      ]
    )
    for revisionID in annotationRevisionIDs.sorted() {
      try database.execute(
        "INSERT INTO replica_annotation_revisions VALUES (?,?)",
        [.text(id), .text(revisionID)]
      )
      if let remoteHash = try conflictRemoteHashLocked(snapshot.value.callId) {
        try database.execute(
          "INSERT OR IGNORE INTO replica_conflict_revisions VALUES (?,?,?)",
          [.text(snapshot.value.callId), .text(remoteHash), .text(revisionID)]
        )
      }
    }
    try database.execute(
      "UPDATE lifecycle SET replica=CASE WHEN replica='conflict' THEN replica ELSE 'pending' END,replica_failure=CASE WHEN replica='conflict' THEN replica_failure ELSE NULL END,replica_retry=CASE WHEN replica='conflict' THEN replica_retry ELSE NULL END,state_version=state_version+1 WHERE call_id=?",
      [.text(snapshot.value.callId)]
    )
  }

  public func pendingReplicas(callID: String? = nil) throws -> [CanonicalReplicaWork] {
    var result: [CanonicalReplicaWork] = []
    var afterCall = ""
    var afterVersion = 0
    while true {
      let rows = try database.access {
        try database.rows(
          """
          SELECT w.operation_id,w.call_id,w.snapshot_hash,w.document_version,w.request_bound,w.expected_server_version,w.conflict_remote_hash
          FROM canonical_replica_work w JOIN operations o ON o.operation_id=w.operation_id JOIN lifecycle l ON l.call_id=w.call_id
          WHERE o.acknowledged=0 AND w.superseded=0 AND l.deletion='active'
            AND (? IS NULL OR w.call_id=?) AND (w.call_id,w.document_version)>(?,?)
          ORDER BY w.call_id,w.document_version LIMIT 100
          """,
          [.string(callID), .string(callID), .text(afterCall), .int(afterVersion)]
        )
      }
      for row in rows { result.append(try replicaWork(row)) }
      if rows.count < 100 { return result }
      afterCall = try rows.last!.string(1)
      afterVersion = try rows.last!.int(3)
    }
  }

  /// Bind the compare-and-swap version once, before the first request. Later local edits
  /// cannot change either this body or an uncertain operation's replay identity.
  public func bindReplicaRequest(operationID: String) async throws -> PublishCallReplica {
    let work = try requiredReplicaWork(operationID)
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(work.callID)
        guard
          let state =
            try database.rows("SELECT replica FROM lifecycle WHERE call_id=?", [.text(work.callID)])
            .first,
          try state.string(0) != "conflict",
          try database.rows(
            "SELECT operation_id FROM canonical_replica_work WHERE call_id=? AND superseded=0 AND receipt_hash IS NULL AND document_version<?",
            [.text(work.callID), .int(work.documentVersion)]
          )
          .isEmpty
        else { throw CanonicalSyncError.conflict }
        let version = try database
          .rows(
            "SELECT document_version FROM replica_observations WHERE call_id=?",
            [.text(work.callID)]
          )
          .first?
          .int(0)
        try database.execute(
          "UPDATE canonical_replica_work SET request_bound=1,expected_server_version=? WHERE operation_id=? AND request_bound=0 AND superseded=0 AND receipt_hash IS NULL",
          [.int(version), .text(operationID)]
        )
      }
    }
    let bound = try requiredReplicaWork(operationID)
    guard bound.requestBound,
      let document = String(data: try documentBytes(bound.snapshotHash), encoding: .utf8)
    else { throw CanonicalSyncError.incompatibleDocument }
    return .init(
      schemaVersion: 1,
      operationId: operationID,
      expectedDocumentVersion: bound.expectedServerVersion,
      document: document,
      annotationRevisionIds: bound.annotationRevisionIDs
    )
  }

  public func acceptReplicaReceipt(_ input: StoredDocument<ReplicaReceipt>) async throws {
    let receipt = try Contract.decode(ReplicaReceipt.self, bytes: input.storedBytes)
    guard receipt.value == input.value else { throw CanonicalSyncError.invalidReceipt }
    let value = receipt.value
    let work = try requiredReplicaWork(value.operationId)
    let bytes = try documentBytes(work.snapshotHash)
    guard value.archiveId == archiveID, value.callId == work.callID,
      value.documentVersion == work.documentVersion,
      value.sha256 == work.snapshotHash, value.byteLength == bytes.count, work.requestBound
    else { throw CanonicalSyncError.invalidReceipt }
    let receiptHash = try await stageDocument(receipt.storedBytes)
    try interruption(.beforeJournalAcknowledgement)
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(work.callID)
        guard
          let row =
            try database.rows(
              "SELECT receipt_hash,superseded FROM canonical_replica_work WHERE operation_id=?",
              [.text(work.operationID)]
            )
            .first,
          try row.int(1) == 0
        else { return }
        if let prior = try row.optionalString(0), prior != receiptHash {
          throw CanonicalSyncError.invalidReceipt
        }
        try database.execute(
          "UPDATE canonical_replica_work SET receipt_hash=? WHERE operation_id=?",
          [.text(receiptHash), .text(work.operationID)]
        )
        try database.execute(
          "UPDATE operations SET acknowledged=1 WHERE operation_id=?",
          [.text(work.operationID)]
        )
        try observeReplicaLocked(
          callID: work.callID,
          version: work.documentVersion,
          hash: work.snapshotHash
        )
        try updateReplicaConfirmationLocked(work.callID)
      }
    }
    try interruption(.afterJournalAcknowledgement)
  }

  func requiredReplicaWork(_ operationID: String) throws -> CanonicalReplicaWork {
    try requireCanonicalIdentifier(operationID)
    guard
      let row = try database.access({
        try database.rows(
          "SELECT operation_id,call_id,snapshot_hash,document_version,request_bound,expected_server_version,conflict_remote_hash FROM canonical_replica_work WHERE operation_id=?",
          [.text(operationID)]
        )
        .first
      })
    else { throw LocalPersistenceError.operationNotFound(operationID) }
    return try replicaWork(row)
  }

  private func replicaWork(_ row: SQLRow) throws -> CanonicalReplicaWork {
    let operationID = try row.string(0)
    let revisions = try database.access {
      try database.rows(
        "SELECT revision_id FROM replica_annotation_revisions WHERE operation_id=? ORDER BY revision_id",
        [.text(operationID)]
      )
      .map { try $0.string(0) }
    }
    return try .init(
      operationID: operationID,
      callID: row.string(1),
      snapshotHash: row.string(2),
      documentVersion: row.int(3),
      requestBound: row.int(4) == 1,
      expectedServerVersion: row.optionalInt(5),
      annotationRevisionIDs: revisions,
      conflictRemoteHash: row.optionalString(6)
    )
  }

  func observeReplicaLocked(callID: String, version: Int, hash: String) throws {
    if let prior =
      try database.rows(
        "SELECT document_version,snapshot_hash FROM replica_observations WHERE call_id=?",
        [.text(callID)]
      )
      .first,
      try prior.int(0) == version, try prior.string(1) != hash
    {
      throw CanonicalSyncError.invalidReceipt
    }
    try database.execute(
      "INSERT INTO replica_observations VALUES (?,?,?) ON CONFLICT(call_id) DO UPDATE SET document_version=excluded.document_version,snapshot_hash=excluded.snapshot_hash WHERE excluded.document_version>replica_observations.document_version",
      [.text(callID), .int(version), .text(hash)]
    )
  }

  func updateReplicaConfirmationLocked(_ callID: String) throws {
    try database.execute(
      """
      UPDATE lifecycle SET replica=CASE WHEN EXISTS(
        SELECT 1 FROM calls c JOIN replica_observations r ON r.call_id=c.call_id WHERE c.call_id=? AND c.hash=r.snapshot_hash
      ) THEN 'confirmed' ELSE 'pending' END,replica_failure=NULL,replica_retry=NULL,state_version=state_version+1
      WHERE call_id=? AND deletion='active' AND replica<>'conflict'
      """,
      [.text(callID), .text(callID)]
    )
  }

  /// Ready reads durable receipts and the exact current pointer, not a server-only result.
  public func isCallSavedOnMacAndServer(callID: String) async throws -> Bool {
    guard let lifecycle = try await lifecycle(callID: callID), lifecycle.deletion.state == .active,
      lifecycle.importState.state == .imported, lifecycle.upload.state == .stored,
      lifecycle.replica.state == .confirmed, try verifiedMasterReceipt(callID: callID) != nil
    else { return false }
    return try database.access {
      try
        !database.rows(
          "SELECT c.call_id FROM calls c JOIN replica_observations r ON r.call_id=c.call_id JOIN call_values v ON v.hash=c.hash WHERE c.call_id=? AND c.hash=r.snapshot_hash AND v.active_revision_id IS NOT NULL",
          [.text(callID)]
        )
        .isEmpty
    }
  }
}
