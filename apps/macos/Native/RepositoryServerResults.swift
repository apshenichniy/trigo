import Foundation
import TrigoContracts

struct PreparedServerResult: Sendable {
  let result: CatalogTranscriptResult
  let operation: PreparedOperation
}

extension LocalRepository {
  func validateServerResult(
    _ result: CatalogTranscriptResult,
    revision: StoredDocument<TranscriptRevision>,
    provenance: Data
  ) throws {
    _ = try Contract.decode(CatalogTranscriptResult.self, bytes: Contract.encode(result))
    guard result.result.revisionId == revision.value.revisionId,
      result.result.createdAt == revision.value.createdAt,
      result.result.sha256 == revision.sha256,
      result.result.byteLength == revision.storedBytes.count,
      result.result.provenanceSHA256 == Contract.hash(provenance),
      result.result.provenanceByteLength == provenance.count
    else { throw CanonicalSyncError.invalidResult }
  }

  func serverResultImportIdentity(callID: String, revisionID: String) -> String {
    "server-import:\(callID):\(revisionID)"
  }

  func serverResultImportIntent(
    _ result: CatalogTranscriptResult,
    callID: String
  ) throws -> OperationIntent {
    .init(
      operationID: synchronizationIdentity(
        "trigo-result-import:\(archiveID):\(callID):\(result.result.revisionId)"
      ),
      archiveID: archiveID,
      callID: callID,
      kind: .importRevision,
      payload: try Contract.encode(result)
    )
  }

  func serverResultMetadata(revisionID: String) throws -> CatalogTranscriptResult? {
    let hash = try database.access {
      try database
        .rows(
          "SELECT o.payload_hash FROM imported_server_results r JOIN operations o ON o.operation_id=r.operation_id WHERE r.revision_id=?",
          [.text(revisionID)]
        )
        .first?
        .string(0)
    }
    return try hash.map {
      try Contract.decode(CatalogTranscriptResult.self, bytes: documentBytes($0)).value
    }
  }

  /// Association is local work, separate from any publication command. Restoration uses
  /// the same transaction boundary without changing the confirmed document or its hash.
  func commitServerResultLocked(
    _ result: CatalogTranscriptResult,
    callID: String,
    operation: PreparedOperation
  ) throws {
    let revisionID = result.result.revisionId
    let semanticID = serverResultImportIdentity(callID: callID, revisionID: revisionID)
    if try semanticWorkExists(semanticID) {
      try validateSemanticWork(semanticID, operation: operation)
    } else {
      try commitSemanticWork(semanticID, operation: operation)
    }
    if let previous =
      try database.rows(
        "SELECT server_operation_id,generation,operation_id FROM imported_server_results WHERE revision_id=?",
        [.text(revisionID)]
      )
      .first
    {
      guard try previous.string(0) == result.operationId,
        try previous.int(1) == result.generation,
        try previous.string(2) == operation.intent.operationID
      else { throw CanonicalSyncError.invalidResult }
    }
    guard
      try database.rows(
        "SELECT r.revision_id FROM imported_server_results r JOIN evidence e ON e.identity=r.revision_id WHERE e.call_id=? AND r.generation=? AND r.revision_id<>?",
        [.text(callID), .int(result.generation), .text(revisionID)]
      )
      .isEmpty
    else { throw CanonicalSyncError.invalidResult }
    try database.execute(
      "INSERT OR IGNORE INTO imported_server_results VALUES (?,?,?,?)",
      [
        .text(revisionID), .text(operation.intent.operationID), .text(result.operationId),
        .int(result.generation),
      ]
    )
    try database.execute(
      "UPDATE operations SET acknowledged=1 WHERE operation_id=?",
      [.text(operation.intent.operationID)]
    )
  }

  func commitTranscriptProvenanceLocked(revisionID: String, hash: String) throws {
    if let previous =
      try database.rows(
        "SELECT hash FROM transcript_provenance WHERE revision_id=?",
        [.text(revisionID)]
      )
      .first, try previous.string(0) != hash
    {
      throw CanonicalSyncError.invalidResult
    }
    try database.execute(
      "INSERT OR IGNORE INTO transcript_provenance VALUES (?,?)",
      [.text(revisionID), .text(hash)]
    )
  }
}
