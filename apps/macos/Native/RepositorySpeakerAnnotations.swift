import Foundation
import TrigoContracts

extension LocalRepository {
  /// Replay precedes the expected-version check, including an uncertain commit acknowledgement.
  /// The immutable snapshot and pending replication become visible in the same transaction.
  @discardableResult
  public func editSpeakerAnnotations(
    _ edit: SpeakerAnnotationEdit
  ) async throws -> StoredDocument<CallDocument> {
    try requireCanonicalIdentifier(edit.operationID)
    try requireCanonicalIdentifier(edit.callID)
    try requireCanonicalIdentifier(edit.revisionID)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let command = try encoder.encode(edit)
    let commandHash = Contract.hash(command)
    try database.access { try requireActiveCallLocked(edit.callID) }
    if let replay = try annotationReplay(edit.operationID, commandHash: commandHash) {
      return replay
    }
    guard let priorHash = try currentHash(edit.callID) else {
      throw LocalPersistenceError.callNotFound(edit.callID)
    }
    let current = try callValue(hash: priorHash)
    guard current.documentVersion == edit.expectedDocumentVersion else {
      throw LocalPersistenceError.staleDocumentVersion(
        current: current.documentVersion,
        proposed: edit.expectedDocumentVersion
      )
    }
    guard let reference = current.revisions.first(where: { $0.revisionId == edit.revisionID })
    else {
      throw CanonicalSyncError.invalidAnnotation
    }
    let speakers = try speakerIDs(revisionHash: reference.sha256)
    var proposed = current
    try apply(edit.mutation, revisionID: edit.revisionID, speakers: speakers, to: &proposed)
    proposed.documentVersion += 1
    try validatePublication(
      from: current,
      to: proposed,
      allowedAnnotationRevisionIDs: [edit.revisionID]
    )
    let snapshot = StoredDocument(value: proposed, storedBytes: try Contract.encode(proposed))
    let prepared = try await prepareOperation(
      .init(
        operationID: edit.operationID,
        archiveID: archiveID,
        callID: edit.callID,
        kind: .replica,
        payload: command
      )
    )
    try await stageCall(snapshot)
    let resultHash = try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(edit.callID)
        if let replay = try annotationReplayHashLocked(edit.operationID, commandHash: commandHash) {
          return replay
        }
        try validateGroupHistoryLocked(from: current, to: proposed)
        _ = try commitCall(proposed, hash: snapshot.sha256, expected: priorHash)
        try commitReplicaWork(
          prepared,
          snapshot: snapshot,
          annotationRevisionIDs: [edit.revisionID]
        )
        if let remoteHash = try conflictRemoteHashLocked(edit.callID) {
          try database.execute(
            "DELETE FROM replica_conflict_choices WHERE call_id=? AND remote_hash=? AND revision_id=?",
            [.text(edit.callID), .text(remoteHash), .text(edit.revisionID)]
          )
        }
        try database.execute(
          "INSERT INTO annotation_edits VALUES (?,?,?)",
          [.text(edit.operationID), .text(commandHash), .text(snapshot.sha256)]
        )
        return snapshot.sha256
      }
    }
    return try storedCall(hash: resultHash)
  }

  /// The compatibility convenience has the same durable semantic owner as the reader API.
  public func setSpeakerName(
    _ name: String?,
    callID: String,
    revisionID: String,
    speakerID: String
  ) async throws -> LocalCallAggregate {
    let current = try await call(callID: callID)
    _ = try await editSpeakerAnnotations(
      .init(
        operationID: UUID().uuidString.lowercased(),
        callID: callID,
        revisionID: revisionID,
        expectedDocumentVersion: current.documentVersion,
        mutation: .rename(speakerID: speakerID, name: name)
      )
    )
    return try await loadCall(callID: callID)
  }

  func annotationReplay(
    _ operationID: String,
    commandHash: String
  ) throws -> StoredDocument<CallDocument>? {
    let hash = try database.access {
      try annotationReplayHashLocked(operationID, commandHash: commandHash)
    }
    return try hash.map { try storedCall(hash: $0) }
  }

  func annotationReplayHashLocked(_ operationID: String, commandHash: String) throws -> String? {
    guard
      let row =
        try database.rows(
          "SELECT command_hash,result_hash FROM annotation_edits WHERE operation_id=?",
          [.text(operationID)]
        )
        .first
    else { return nil }
    guard try row.string(0) == commandHash else {
      throw LocalPersistenceError.operationConflict(operationID)
    }
    return try row.string(1)
  }

  func speakerIDs(revisionHash: String) throws -> Set<String> {
    Set(try projectionRows("revision_speakers", hash: revisionHash).map { try $0.string(1) })
  }

  func storedCall(hash: String) throws -> StoredDocument<CallDocument> {
    try .init(value: callValue(hash: hash), storedBytes: documentBytes(hash))
  }

  private func apply(
    _ mutation: SpeakerAnnotationMutation,
    revisionID: String,
    speakers: Set<String>,
    to call: inout CallDocument
  ) throws {
    var groups = call.speakerGroups[revisionID] ?? []
    switch mutation {
    case .rename(let speakerID, let name):
      guard speakers.contains(speakerID) else {
        throw LocalPersistenceError.invalidSpeakerReference(
          revisionID: revisionID,
          speakerID: speakerID
        )
      }
      if let index = groups.firstIndex(where: { $0.speakerIds.contains(speakerID) }) {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw CanonicalSyncError.invalidAnnotation
        }
        groups[index].displayName = name
      } else {
        var names = call.speakerNames[revisionID] ?? [:]
        names[speakerID] = name.flatMap {
          $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        call.speakerNames[revisionID] = names.isEmpty ? nil : names
      }
    case .group(let groupID, let displayName, let selected):
      try requireCanonicalIdentifier(groupID)
      guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        Set(selected).count == selected.count, Set(selected).isSubset(of: speakers)
      else { throw CanonicalSyncError.invalidAnnotation }
      var members = Set(selected)
      if let target = groups.first(where: { $0.groupId == groupID }) {
        members.formUnion(target.speakerIds)
      }
      let included = groups.filter { !$0.speakerIds.allSatisfy { !members.contains($0) } }
      for group in included { members.formUnion(group.speakerIds) }
      guard members.count >= 2 else { throw CanonicalSyncError.invalidAnnotation }
      groups.removeAll { included.map(\.groupId).contains($0.groupId) }
      groups.append(.init(groupId: groupID, displayName: displayName, speakerIds: members.sorted()))
    case .removeMembers(let groupID, let selected):
      guard let index = groups.firstIndex(where: { $0.groupId == groupID }),
        Set(selected).count == selected.count,
        Set(selected).isSubset(of: Set(groups[index].speakerIds))
      else { throw CanonicalSyncError.invalidAnnotation }
      groups[index].speakerIds.removeAll { selected.contains($0) }
      if groups[index].speakerIds.count < 2 { groups.remove(at: index) }
    case .ungroup(let groupID):
      guard groups.contains(where: { $0.groupId == groupID }) else {
        throw CanonicalSyncError.invalidAnnotation
      }
      groups.removeAll { $0.groupId == groupID }
    }
    call.speakerGroups[revisionID] = groups.isEmpty ? nil : groups
  }

  func validateGroupHistoryLocked(from current: CallDocument, to proposed: CallDocument) throws {
    let currentIDs = Set(current.speakerGroups.values.flatMap { $0.map(\.groupId) })
    for (revisionID, groups) in proposed.speakerGroups {
      for group in groups {
        if let prior =
          try database.rows(
            "SELECT revision_id FROM speaker_group_history WHERE call_id=? AND group_id=?",
            [.text(proposed.callId), .text(group.groupId)]
          )
          .first
        {
          guard try prior.string(0) == revisionID, currentIDs.contains(group.groupId) else {
            throw CanonicalSyncError.groupIdentityReused(group.groupId)
          }
        }
      }
    }
  }

  func retainGroupHistoryLocked(_ call: CallDocument) throws {
    for (revisionID, groups) in call.speakerGroups {
      for group in groups {
        if let row =
          try database.rows(
            "SELECT revision_id FROM speaker_group_history WHERE call_id=? AND group_id=?",
            [.text(call.callId), .text(group.groupId)]
          )
          .first,
          try row.string(0) != revisionID
        {
          throw CanonicalSyncError.groupIdentityReused(group.groupId)
        }
        try database.execute(
          "INSERT OR IGNORE INTO speaker_group_history VALUES (?,?,?)",
          [.text(call.callId), .text(group.groupId), .text(revisionID)]
        )
      }
    }
  }
}
