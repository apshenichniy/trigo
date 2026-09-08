import Foundation
import TrigoContracts

private struct ResolveSpeakerConflict: Codable {
  let operationID: String
  let callID: String
  let revisionID: String
  let serverDocumentVersion: Int
  let choice: SpeakerConflictChoice
}

extension LocalRepository {
  public func observedReplica(callID: String) throws -> (version: Int, hash: String)? {
    guard
      let row = try database.access({
        try database.rows(
          "SELECT document_version,snapshot_hash FROM replica_observations WHERE call_id=?",
          [.text(callID)]
        )
        .first
      })
    else { return nil }
    return try (row.int(0), row.string(1))
  }

  /// Unedited confirmed bases may advance from the server. Pending local work retains
  /// both alternatives and exposes an explicit annotation comparison instead.
  @discardableResult
  public func reconcileServerReplica(
    _ contents: ServerReplicaContents
  ) async throws -> PublicationResult {
    let remote = try Contract.decodeCallSnapshot(contents.document)
    let callID = remote.value.callId
    guard let hash = try currentHash(callID) else { return try await restoreReplica(contents) }
    if let observed = try observedReplica(callID: callID),
      observed.version > remote.value.documentVersion
    {
      return .alreadyPresent
    }
    if hash == remote.sha256 {
      let result = try await restoreReplica(contents)
      try database.access {
        try database.transaction(interruption: interruption) {
          try requireActiveCallLocked(callID)
          guard try currentHashLocked(callID) == remote.sha256 else {
            throw LocalPersistenceError.concurrentMutation
          }
          try supersedeReplicasLocked(callID: callID, through: remote.value.documentVersion)
        }
      }
      return result
    }
    let current = try callValue(hash: hash)
    if let observed = try observedReplica(callID: callID),
      observed.version == remote.value.documentVersion
    {
      guard observed.hash == remote.sha256 else { throw CanonicalSyncError.invalidReceipt }
      return .alreadyPresent
    }
    let pending = try pendingReplicas(callID: callID)
    // An exact retained publication also recovers a lost acknowledgement while a newer
    // local edit is pending. It confirms the old version without replacing the current one.
    if pending.contains(where: {
      $0.snapshotHash == remote.sha256 && $0.documentVersion == remote.value.documentVersion
    }) {
      let prepared = try await prepareServerReplica(contents)
      return try database.access {
        try database.transaction(interruption: interruption) {
          try requireActiveCallLocked(callID)
          try commitServerEvidence(prepared)
          try observeReplicaLocked(
            callID: callID,
            version: remote.value.documentVersion,
            hash: remote.sha256
          )
          try supersedeReplicasLocked(callID: callID, through: remote.value.documentVersion)
          try updateReplicaConfirmationLocked(callID)
          return .alreadyPresent
        }
      }
    }
    if pending.isEmpty, try observedReplica(callID: callID)?.hash == hash,
      remote.value.documentVersion > current.documentVersion
    {
      try validatePublication(
        from: current,
        to: remote.value,
        allowedAnnotationRevisionIDs: Set(remote.value.revisions.map(\.revisionId))
      )
      let prepared = try await prepareServerReplica(contents)
      return try database.access {
        try database.transaction(interruption: interruption) {
          try requireActiveCallLocked(callID)
          let result = try commitCall(remote.value, hash: remote.sha256, expected: hash)
          try commitServerEvidence(prepared)
          try observeReplicaLocked(
            callID: callID,
            version: remote.value.documentVersion,
            hash: remote.sha256
          )
          try database.execute(
            "UPDATE lifecycle SET import_state=?,state_version=state_version+1 WHERE call_id=?",
            [
              .text(remote.value.activeRevisionId == nil ? "not_available" : "imported"),
              .text(callID),
            ]
          )
          try updateReplicaConfirmationLocked(callID)
          return result
        }
      }
    }
    try await recordReplicaConflict(contents)
    return .committed
  }

  public func recordReplicaConflict(_ contents: ServerReplicaContents) async throws {
    let remote = try await prepareServerReplica(contents)
    let callID = remote.snapshot.value.callId
    guard let currentHash = try currentHash(callID) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    let current = try callValue(hash: currentHash)
    _ = try mergedConflictBase(current: current, remote: remote.snapshot.value)
    let pending = try pendingReplicas(callID: callID)
    guard !pending.isEmpty else { throw CanonicalSyncError.conflict }
    var scopes = Set(pending.flatMap(\.annotationRevisionIDs))
    for reference in current.revisions
    where speakerAnnotations(current, revisionID: reference.revisionId)
      != speakerAnnotations(remote.snapshot.value, revisionID: reference.revisionId)
    {
      scopes.insert(reference.revisionId)
    }
    // Even a revision-only compare-and-swap remains visible and requires an explicit choice.
    if scopes.isEmpty {
      scopes = Set(
        current.revisions.map(\.revisionId) + remote.snapshot.value.revisions.map(\.revisionId)
      )
    }
    if scopes.isEmpty {
      try await reconcileUnannotatedBase(remote, current: current, currentHash: currentHash)
      return
    }
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        guard try self.currentHashLocked(callID) == currentHash else {
          throw LocalPersistenceError.concurrentMutation
        }
        try commitServerEvidence(remote)
        try observeReplicaLocked(
          callID: callID,
          version: remote.snapshot.value.documentVersion,
          hash: remote.snapshot.sha256
        )
        for revisionID in scopes {
          try database.execute(
            "INSERT OR IGNORE INTO replica_conflict_revisions VALUES (?,?,?)",
            [.text(callID), .text(remote.snapshot.sha256), .text(revisionID)]
          )
        }
        try database.execute(
          "UPDATE canonical_replica_work SET conflict_remote_hash=? WHERE call_id=? AND superseded=0 AND receipt_hash IS NULL",
          [.text(remote.snapshot.sha256), .text(callID)]
        )
        try database.execute(
          "UPDATE lifecycle SET replica='conflict',replica_failure='sync_conflict',replica_retry='after_correction',state_version=state_version+1 WHERE call_id=?",
          [.text(callID)]
        )
      }
    }
  }

  /// With no revisions there are no annotations or active transcript to choose between.
  /// Immutable capture metadata has already matched. Adopt a newer current-format base,
  /// or author a new version above both sides and retry its ordinary version check.
  private func reconcileUnannotatedBase(
    _ remote: PreparedServerReplica,
    current: CallDocument,
    currentHash: String
  ) async throws {
    let callID = current.callId
    let currentFormat =
      try Contract.validateCallSnapshot(remote.snapshot.storedBytes).kind == "CallDocument"
    let mayAdopt = remote.snapshot.value.documentVersion > current.documentVersion && currentFormat
    let snapshot: StoredDocument<CallDocument>
    let operation: PreparedOperation?
    if mayAdopt {
      snapshot = remote.snapshot
      operation = nil
    } else {
      var value = current
      value.documentVersion =
        max(current.documentVersion, remote.snapshot.value.documentVersion) + 1
      snapshot = StoredDocument(value: value, storedBytes: try Contract.encode(value))
      try await stageCall(snapshot)
      operation = try await prepareOperation(
        .init(
          operationID: UUID().uuidString.lowercased(),
          archiveID: archiveID,
          callID: callID,
          kind: .replica,
          payload: snapshot.storedBytes
        )
      )
    }
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        guard try self.currentHashLocked(callID) == currentHash else {
          throw LocalPersistenceError.concurrentMutation
        }
        try commitServerEvidence(remote)
        try observeReplicaLocked(
          callID: callID,
          version: remote.snapshot.value.documentVersion,
          hash: remote.snapshot.sha256
        )
        try supersedeReplicasLocked(callID: callID, through: current.documentVersion)
        _ = try commitCall(snapshot.value, hash: snapshot.sha256, expected: currentHash)
        try database.execute(
          "UPDATE lifecycle SET replica='pending' WHERE call_id=?",
          [.text(callID)]
        )
        if let operation {
          try commitReplicaWork(operation, snapshot: snapshot, annotationRevisionIDs: [])
        }
        try updateReplicaConfirmationLocked(callID)
      }
    }
  }

  public func annotationConflicts(callID: String) async throws -> [SpeakerAnnotationConflict] {
    guard let remoteHash = try database.access({ try conflictRemoteHashLocked(callID) }) else {
      return []
    }
    let current = try await call(callID: callID)
    let remote = try callValue(hash: remoteHash)
    let revisions = try database.access {
      try database.rows(
        "SELECT r.revision_id FROM replica_conflict_revisions r WHERE r.call_id=? AND r.remote_hash=? AND NOT EXISTS(SELECT 1 FROM replica_conflict_choices c WHERE c.call_id=r.call_id AND c.remote_hash=r.remote_hash AND c.revision_id=r.revision_id) ORDER BY r.revision_id",
        [.text(callID), .text(remoteHash)]
      )
      .map { try $0.string(0) }
    }
    return revisions.map {
      .init(
        callID: callID,
        revisionID: $0,
        local: speakerAnnotations(current, revisionID: $0),
        server: speakerAnnotations(remote, revisionID: $0),
        serverDocumentVersion: remote.documentVersion
      )
    }
  }

  /// The choice applies to one revision against the latest local metadata. Other revisions,
  /// original evidence and a concurrent deletion remain under their existing owners.
  @discardableResult
  public func resolveSpeakerAnnotationConflict(
    callID: String,
    revisionID: String,
    serverDocumentVersion: Int,
    choice: SpeakerConflictChoice,
    operationID: String
  ) async throws -> StoredDocument<CallDocument> {
    try requireCanonicalIdentifier(operationID)
    let command = ResolveSpeakerConflict(
      operationID: operationID,
      callID: callID,
      revisionID: revisionID,
      serverDocumentVersion: serverDocumentVersion,
      choice: choice
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(command)
    let commandHash = Contract.hash(payload)
    try database.access { try requireActiveCallLocked(callID) }
    if let replay = try annotationReplay(operationID, commandHash: commandHash) { return replay }
    guard let priorHash = try currentHash(callID),
      let remoteHash = try database.access({ try conflictRemoteHashLocked(callID) })
    else { throw CanonicalSyncError.conflict }
    let current = try callValue(hash: priorHash)
    let remote = try callValue(hash: remoteHash)
    guard remote.documentVersion == serverDocumentVersion else { throw CanonicalSyncError.conflict }
    let scopes = try database.access {
      Set(
        try database.rows(
          "SELECT revision_id FROM replica_conflict_revisions WHERE call_id=? AND remote_hash=?",
          [.text(callID), .text(remoteHash)]
        )
        .map { try $0.string(0) }
      )
    }
    guard scopes.contains(revisionID) else { throw CanonicalSyncError.invalidAnnotation }
    var proposed = try mergedConflictBase(current: current, remote: remote)
    if choice == .useServer {
      proposed.speakerNames[revisionID] = remote.speakerNames[revisionID]
      proposed.speakerGroups[revisionID] = remote.speakerGroups[revisionID]
    } else {
      proposed.speakerNames[revisionID] = current.speakerNames[revisionID]
      proposed.speakerGroups[revisionID] = current.speakerGroups[revisionID]
    }
    proposed.documentVersion = max(current.documentVersion, remote.documentVersion) + 1
    let snapshot = try Contract.decode(CallDocument.self, bytes: Contract.encode(proposed))
    try await stageCall(snapshot)
    let operation = try await prepareOperation(
      .init(
        operationID: operationID,
        archiveID: archiveID,
        callID: callID,
        kind: .replica,
        payload: payload
      )
    )
    let result = try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        if let replay = try annotationReplayHashLocked(operationID, commandHash: commandHash) {
          return replay
        }
        guard try conflictRemoteHashLocked(callID) == remoteHash else {
          throw CanonicalSyncError.conflict
        }
        _ = try commitCall(proposed, hash: snapshot.sha256, expected: priorHash)
        try commitReplicaWork(operation, snapshot: snapshot, annotationRevisionIDs: scopes)
        try database.execute(
          "INSERT INTO annotation_edits VALUES (?,?,?)",
          [.text(operationID), .text(commandHash), .text(snapshot.sha256)]
        )
        try database.execute(
          "INSERT INTO replica_conflict_choices VALUES (?,?,?,?) ON CONFLICT(call_id,remote_hash,revision_id) DO UPDATE SET choice=excluded.choice",
          [.text(callID), .text(remoteHash), .text(revisionID), .text(choice.rawValue)]
        )
        let remaining = try database.rows(
          "SELECT r.revision_id FROM replica_conflict_revisions r WHERE r.call_id=? AND r.remote_hash=? AND NOT EXISTS(SELECT 1 FROM replica_conflict_choices c WHERE c.call_id=r.call_id AND c.remote_hash=r.remote_hash AND c.revision_id=r.revision_id) LIMIT 1",
          [.text(callID), .text(remoteHash)]
        )
        if remaining.isEmpty {
          try supersedeReplicasLocked(callID: callID, through: proposed.documentVersion - 1)
          try database.execute(
            "UPDATE lifecycle SET replica='pending',replica_failure=NULL,replica_retry=NULL,state_version=state_version+1 WHERE call_id=?",
            [.text(callID)]
          )
        } else {
          try database.execute(
            "UPDATE canonical_replica_work SET conflict_remote_hash=? WHERE operation_id=?",
            [.text(remoteHash), .text(operationID)]
          )
        }
        return snapshot.sha256
      }
    }
    return try storedCall(hash: result)
  }

  func conflictRemoteHashLocked(_ callID: String) throws -> String? {
    try database
      .rows(
        "SELECT w.conflict_remote_hash FROM canonical_replica_work w JOIN call_values v ON v.hash=w.conflict_remote_hash WHERE w.call_id=? AND w.superseded=0 AND w.receipt_hash IS NULL ORDER BY v.version DESC LIMIT 1",
        [.text(callID)]
      )
      .first?
      .string(0)
  }

  func supersedeReplicasLocked(callID: String, through version: Int) throws {
    try database.execute(
      "UPDATE operations SET acknowledged=1 WHERE operation_id IN(SELECT operation_id FROM canonical_replica_work WHERE call_id=? AND document_version<=?)",
      [.text(callID), .int(version)]
    )
    try database.execute(
      "UPDATE canonical_replica_work SET superseded=1 WHERE call_id=? AND document_version<=? AND receipt_hash IS NULL",
      [.text(callID), .int(version)]
    )
  }

  private func mergedConflictBase(
    current: CallDocument,
    remote: CallDocument
  ) throws -> CallDocument {
    guard current.callId == remote.callId, current.archiveId == remote.archiveId,
      current.startedAt == remote.startedAt, current.source == remote.source,
      !captureChanged(current, remote)
    else { throw CanonicalSyncError.incompatibleDocument }
    var merged = current
    for reference in remote.revisions {
      if let retained = current.revisions.first(where: { $0.revisionId == reference.revisionId }) {
        guard retained == reference else {
          throw LocalPersistenceError.immutableConflict(reference.revisionId)
        }
      } else {
        merged.revisions.append(reference)
        merged.speakerNames[reference.revisionId] = remote.speakerNames[reference.revisionId]
        merged.speakerGroups[reference.revisionId] = remote.speakerGroups[reference.revisionId]
      }
    }
    return merged
  }
}

private func speakerAnnotations(_ call: CallDocument, revisionID: String) -> SpeakerAnnotations {
  .init(names: call.speakerNames[revisionID] ?? [:], groups: call.speakerGroups[revisionID] ?? [])
}
