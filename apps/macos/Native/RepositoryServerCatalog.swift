import Foundation
import TrigoContracts

public struct ArchiveSynchronizationStatus: Sendable, Equatable {
  public let hasCatalog: Bool
  public let pendingRestorationCount: Int
  public let failure: LifecycleFailure?
}

extension LocalRepository {
  public func synchronizationStatus() throws -> ArchiveSynchronizationStatus {
    let hasCatalog = try syncCursor() != nil
    let result = try database.access {
      let count =
        try database
        .rows(
          "SELECT COUNT(*) FROM server_catalog_entries s LEFT JOIN calls c ON c.call_id=s.call_id LEFT JOIN local_deletion_markers d ON d.call_id=s.call_id WHERE c.call_id IS NULL AND d.call_id IS NULL"
        )
        .first?
        .int(0) ?? 0
      let row = try database.rows("SELECT failure,retry FROM archive_sync_status WHERE singleton=1")
        .first
      return (count, row)
    }
    let failure: LifecycleFailure?
    if let code = try result.1?.optionalString(0), let retry = try result.1?.optionalString(1),
      let classification = LifecycleRetryClassification(rawValue: retry)
    {
      failure = try .init(code: code, retry: classification)
    } else {
      failure = nil
    }
    return .init(hasCatalog: hasCatalog, pendingRestorationCount: result.0, failure: failure)
  }

  func recordSynchronizationStatus(_ failure: LifecycleFailure?) throws {
    try database.access {
      try database.execute(
        "INSERT INTO archive_sync_status VALUES (1,?,?,1) ON CONFLICT(singleton) DO UPDATE SET failure=excluded.failure,retry=excluded.retry,state_version=archive_sync_status.state_version+1 WHERE archive_sync_status.failure IS NOT excluded.failure OR archive_sync_status.retry IS NOT excluded.retry",
        [.string(failure?.code), .string(failure?.retry.rawValue)]
      )
    }
  }

  /// Retain remote work descriptions before advancing a change cursor. Downloads, validation
  /// failures and interrupted restoration can then resume without another server change.
  public func retainCatalogEntry(_ entry: CallCatalogEntry) async throws {
    let document = try Contract.decode(CallCatalogEntry.self, bytes: Contract.encode(entry))
    guard
      entry.audio == nil
        || (entry.audio?.archiveId == archiveID && entry.audio?.callId == entry.callId),
      entry.deletion == nil || entry.deletion?.callId == entry.callId
    else { throw CanonicalSyncError.invalidResult }
    let hash = try await stageDocument(document.storedBytes)
    if let marker = entry.deletion { try await acceptDeletionMarker(marker) }
    try database.access {
      try database.transaction(interruption: interruption) {
        try database.execute(
          "INSERT INTO server_catalog_entries(call_id,hash) VALUES (?,?) ON CONFLICT(call_id) DO UPDATE SET hash=excluded.hash,refresh_operation=1",
          [.text(entry.callId), .text(hash)]
        )
      }
    }
  }

  public func serverCatalogEntries(after: String = "") throws -> [CallCatalogEntry] {
    let rows = try database.access {
      try database.rows(
        "SELECT call_id,hash FROM server_catalog_entries WHERE call_id>? ORDER BY call_id LIMIT 100",
        [.text(after)]
      )
    }
    return try rows.map { row in
      let entry = try Contract.decode(CallCatalogEntry.self, bytes: documentBytes(row.string(1)))
        .value
      guard try entry.callId == row.string(0) else { throw CanonicalSyncError.invalidResult }
      return entry
    }
  }

  public func serverCatalogEntry(callID: String) throws -> CallCatalogEntry? {
    let hash = try database.access {
      try database.rows("SELECT hash FROM server_catalog_entries WHERE call_id=?", [.text(callID)])
        .first?
        .string(0)
    }
    return try hash.map {
      try Contract.decode(CallCatalogEntry.self, bytes: documentBytes($0)).value
    }
  }

  func catalogOperationNeedsRefresh(callID: String) throws -> Bool {
    try database.access {
      try database
        .rows(
          "SELECT refresh_operation FROM server_catalog_entries WHERE call_id=?",
          [.text(callID)]
        )
        .first?
        .int(0) == 1
    }
  }

  func acknowledgeCatalogOperation(callID: String, operationID: String) throws {
    guard let entry = try serverCatalogEntry(callID: callID),
      entry.latestTranscriptionOperationId == operationID
    else { return }
    let hash = try Contract.hash(Contract.encode(entry))
    try database.access {
      try database.execute(
        "UPDATE server_catalog_entries SET refresh_operation=0 WHERE call_id=? AND hash=?",
        [.text(callID), .text(hash)]
      )
    }
  }

  public func isServerResultImported(revisionID: String) throws -> Bool {
    try database.access {
      try
        !database.rows(
          "SELECT revision_id FROM imported_server_results WHERE revision_id=?",
          [.text(revisionID)]
        )
        .isEmpty
    }
  }

  public func importedServerResultCount(callID: String) throws -> Int {
    try database.access {
      try database
        .rows(
          "SELECT COUNT(*) FROM imported_server_results r JOIN evidence e ON e.identity=r.revision_id WHERE e.call_id=?",
          [.text(callID)]
        )
        .first?
        .int(0) ?? 0
    }
  }
}
