import Foundation
import TrigoContracts

/// Opaque preparation binds a validated revision, its new snapshot and caller-owned work to
/// the observed canonical version. It can be committed or retried, never partially published.
public struct PreparedRevisionImport: Sendable {
  let root: URL
  let archiveID: String
  let priorHash: String
  let revision: StoredDocument<TranscriptRevision>
  let snapshot: StoredDocument<CallDocument>
  let operation: PreparedOperation
  let publication: PreparedOperation?
  let provenanceHash: String?
  let serverResult: CatalogTranscriptResult?
}

extension LocalRepository {
  public func prepareRevisionImport(
    _ bytes: Data,
    associatedWork: OperationIntent,
    provenance: Data? = nil,
    serverResult: CatalogTranscriptResult? = nil
  ) async throws
    -> PreparedRevisionImport
  {
    let revision = try Contract.decode(TranscriptRevision.self, bytes: bytes)
    if let serverResult {
      guard let provenance else { throw CanonicalSyncError.invalidResult }
      try validateServerResult(serverResult, revision: revision, provenance: provenance)
    }
    guard associatedWork.callID == revision.value.callId else { throw ContractError.reference }
    try requireArchiveIdentity(associatedWork.archiveID)
    guard let priorHash = try currentHash(revision.value.callId) else {
      throw LocalPersistenceError.callNotFound(revision.value.callId)
    }
    var call = try callValue(hash: priorHash)
    try validateRevisionAudioReference(revision.value)
    try validateImportReferences(revision.value, against: call)
    if let retained = call.revisions.first(where: { $0.revisionId == revision.value.revisionId }) {
      guard retained.sha256 == revision.sha256,
        try documentBytes(retained.sha256) == bytes
      else { throw LocalPersistenceError.immutableConflict(revision.value.revisionId) }
      if serverResult == nil, associatedWork.kind == .replica { call.documentVersion += 1 }
    } else {
      call.revisions.append(
        .init(
          revisionId: revision.value.revisionId,
          createdAt: revision.value.createdAt,
          sha256: revision.sha256
        )
      )
      if let serverResult {
        // Only proven newer results advance the active pointer. Restoration retains this
        // ordering metadata; an unknown legacy generation is not guessed from timestamps.
        let activeGeneration = try call.activeRevisionId.flatMap {
          try serverResultMetadata(revisionID: $0)?.generation
        }
        if call.activeRevisionId == nil
          || activeGeneration.map({ serverResult.generation > $0 }) == true
        {
          call.activeRevisionId = revision.value.revisionId
        }
      } else {
        call.activeRevisionId = revision.value.revisionId
      }
      call.documentVersion += 1
    }
    let prior = try storedCall(hash: priorHash)
    let snapshot =
      call.documentVersion == prior.value.documentVersion
      ? prior : StoredDocument(value: call, storedBytes: try Contract.encode(call))
    try await stageRevision(revision)
    try await stageCall(snapshot)
    let operation = try await prepareOperation(associatedWork)
    let publication: PreparedOperation?
    if serverResult != nil, snapshot.sha256 != priorHash {
      // The local result association is replayable by revision; a publication is a distinct
      // durable command authored by this installation against its own canonical snapshot.
      publication = try await prepareOperation(
        .init(
          operationID: UUID().uuidString.lowercased(),
          archiveID: archiveID,
          callID: call.callId,
          kind: .replica,
          payload: snapshot.storedBytes
        )
      )
    } else if serverResult == nil, associatedWork.kind == .replica {
      publication = operation
    } else {
      publication = nil
    }
    let provenanceHash = try await provenance.mapAsync { try await stageDocument($0) }
    return .init(
      root: root,
      archiveID: archiveID,
      priorHash: priorHash,
      revision: revision,
      snapshot: snapshot,
      operation: operation,
      publication: publication,
      provenanceHash: provenanceHash,
      serverResult: serverResult
    )
  }

  /// Incoming bytes have passed Contract.decode. Retained evidence has already passed that
  /// boundary, so preserve its identity/hash and compare typed projections instead of
  /// rebuilding and validating every historical JSON document on each import.
  private func validateImportReferences(
    _ revision: TranscriptRevision,
    against call: CallDocument
  )
    throws
  {
    guard revision.callId == call.callId, revision.audioManifest == call.audioManifest,
      let duration = call.durationMs, let audio = call.audioManifest
    else { throw ContractError.reference }
    _ = try documentBytes(audio.sha256)
    let trackIDs = Set(call.tracks.map(\.trackId))
    guard revision.speakers.allSatisfy({ trackIDs.contains($0.trackId) }),
      revision.turns.allSatisfy({ trackIDs.contains($0.trackId) && $0.endMs <= duration })
    else { throw ContractError.reference }
    let speakerIDs = Set(revision.speakers.map(\.speakerId))
    let turnIDs = Set(revision.turns.map(\.turnId))
    for retained in call.revisions {
      let hash = try requiredEvidence(
        identity: retained.revisionId,
        kind: "revision",
        callID: call.callId
      )
      guard hash == retained.sha256 else { throw ContractError.checksum }
      _ = try documentBytes(hash)
      if retained.revisionId == revision.revisionId { continue }
      var speakerCursor = ""
      while true {
        let page = try database.access {
          try database.rows(
            "SELECT speaker_id FROM revision_speakers WHERE hash=? AND speaker_id>? ORDER BY speaker_id LIMIT 128",
            [.text(hash), .text(speakerCursor)]
          )
        }
        for row in page where try speakerIDs.contains(row.string(0)) {
          throw ContractError.reference
        }
        if page.count < 128 { break }
        speakerCursor = try page.last!.string(0)
      }
      var turnCursor = -1
      while true {
        let page = try database.access {
          try database.rows(
            "SELECT ordinal,turn_id FROM revision_turns WHERE hash=? AND ordinal>? ORDER BY ordinal LIMIT 128",
            [.text(hash), .int(turnCursor)]
          )
        }
        for row in page where try turnIDs.contains(row.string(1)) { throw ContractError.reference }
        if page.count < 128 { break }
        turnCursor = try page.last!.int(0)
      }
    }
  }

  @discardableResult
  public func commitRevisionImport(
    _ prepared: PreparedRevisionImport
  ) async throws
    -> PublicationResult
  {
    try requireArchiveIdentity(prepared.archiveID)
    guard prepared.root == root else {
      throw LocalPersistenceError.unsafeStore("Prepared import namespace differs")
    }
    let revision = prepared.revision
    let semanticID =
      prepared.serverResult == nil
      ? "import:\(revision.value.callId):\(revision.value.revisionId)"
      : serverResultImportIdentity(
        callID: revision.value.callId,
        revisionID: revision.value.revisionId
      )
    return try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(revision.value.callId)
        if try semanticWorkExists(semanticID) {
          try validateSemanticWork(semanticID, operation: prepared.operation)
          // Immutable revision identity, even when another revision has since become active.
          _ = try commitEvidence(
            identity: revision.value.revisionId,
            kind: "revision",
            callID: revision.value.callId,
            hash: revision.sha256
          )
          return .alreadyPresent
        }
        guard try currentHashLocked(revision.value.callId) == prepared.priorHash else {
          throw LocalPersistenceError.concurrentMutation
        }
        _ = try commitEvidence(
          identity: revision.value.revisionId,
          kind: "revision",
          callID: revision.value.callId,
          hash: revision.sha256
        )
        // A legacy-staged already-retained revision needs no reconstructed-byte publication.
        let priorVersion = try database
          .rows("SELECT version FROM call_values WHERE hash=?", [.text(prepared.priorHash)]).first?
          .int(0)
        if priorVersion != prepared.snapshot.value.documentVersion {
          _ = try commitCall(
            prepared.snapshot.value,
            hash: prepared.snapshot.sha256,
            expected: prepared.priorHash
          )
        } else {
          try database.execute(
            "UPDATE lifecycle SET state_version=state_version+1 WHERE call_id=?",
            [.text(revision.value.callId)]
          )
        }
        try database.execute(
          "UPDATE lifecycle SET import_state='imported',import_failure=NULL,import_retry=NULL WHERE call_id=?",
          [.text(revision.value.callId)]
        )
        if prepared.serverResult == nil {
          try commitSemanticWork(semanticID, operation: prepared.operation)
        }
        if let publication = prepared.publication {
          try commitReplicaWork(
            publication,
            snapshot: prepared.snapshot,
            annotationRevisionIDs: []
          )
        }
        if let hash = prepared.provenanceHash {
          try commitTranscriptProvenanceLocked(revisionID: revision.value.revisionId, hash: hash)
        }
        if let result = prepared.serverResult {
          try commitServerResultLocked(
            result,
            callID: revision.value.callId,
            operation: prepared.operation
          )
        }
        return .committed
      }
    }
  }

  @discardableResult
  public func importRevision(
    _ bytes: Data,
    associatedWork: OperationIntent
  ) async throws
    -> PublicationResult
  {
    let prepared = try await prepareRevisionImport(bytes, associatedWork: associatedWork)
    return try await commitRevisionImport(prepared)
  }

  @discardableResult
  public func importAvailableResult(
    _ result: CatalogTranscriptResult,
    callID: String,
    revision: Data,
    provenance: Data
  ) async throws -> PublicationResult {
    let intent = try serverResultImportIntent(result, callID: callID)
    let prepared = try await prepareRevisionImport(
      revision,
      associatedWork: intent,
      provenance: provenance,
      serverResult: result
    )
    return try await commitRevisionImport(prepared)
  }

  public func transcriptProvenanceBytes(revisionID: String) throws -> Data? {
    let hash = try database.access {
      try database
        .rows("SELECT hash FROM transcript_provenance WHERE revision_id=?", [.text(revisionID)])
        .first?
        .string(0)
    }
    return try hash.map { try documentBytes($0) }
  }

  func semanticWorkExists(_ identity: String) throws -> Bool {
    try !database.rows("SELECT identity FROM semantic_work WHERE identity=?", [.text(identity)])
      .isEmpty
  }

  func commitSemanticWork(_ identity: String, operation: PreparedOperation?) throws {
    if let operation { try commitOperation(operation) }
    try database.execute(
      "INSERT INTO semantic_work VALUES (?,?)",
      [.text(identity), .string(operation?.intent.operationID)]
    )
  }

  func validateSemanticWork(_ identity: String, operation: PreparedOperation?) throws {
    guard let operation else { return }
    guard
      let row =
        try database.rows(
          "SELECT operation_id FROM semantic_work WHERE identity=?",
          [.text(identity)]
        )
        .first,
      try row.optionalString(0) == operation.intent.operationID
    else {
      throw LocalPersistenceError.operationConflict(operation.intent.operationID)
    }
    try commitOperation(operation)
  }
}
