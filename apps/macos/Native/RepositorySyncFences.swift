import Foundation
import TrigoContracts

extension LocalRepository {
  func requireActiveCallLocked(_ callID: String) throws {
    guard
      try database.rows(
        "SELECT call_id FROM local_deletion_markers WHERE call_id=?",
        [.text(callID)]
      )
      .isEmpty
    else { throw CanonicalSyncError.deleted }
    if let row =
      try database.rows("SELECT deletion FROM lifecycle WHERE call_id=?", [.text(callID)]).first,
      try row.string(0) != "active"
    {
      throw CanonicalSyncError.deleted
    }
  }

  /// Retained independently of a call row. A paginated restore can never resurrect a call
  /// whose marker was observed first, including after a reset of the server change cursor.
  public func acceptDeletionMarker(_ marker: CallDeletionMarker) async throws {
    _ = try Contract.decode(CallDeletionMarker.self, bytes: Contract.encode(marker))
    try database.access {
      try database.transaction(interruption: interruption) {
        let phases = ["requested", "draining", "deleting", "complete"]
        let prior = try database
          .rows("SELECT phase FROM local_deletion_markers WHERE call_id=?", [.text(marker.callId)])
          .first?
          .string(0)
        let phase = phases[
          max(
            phases.firstIndex(of: prior ?? "requested") ?? 0,
            phases.firstIndex(of: marker.phase) ?? 0
          )
        ]
        try database.execute(
          "INSERT INTO local_deletion_markers VALUES (?,?,?) ON CONFLICT(call_id) DO UPDATE SET phase=excluded.phase",
          [.text(marker.callId), .text(marker.markedAt), .text(phase)]
        )
        try database.execute(
          "UPDATE lifecycle SET deletion=?,state_version=state_version+1 WHERE call_id=? AND deletion<>?",
          [.text(phase), .text(marker.callId), .text(phase)]
        )
        try database.execute(
          "UPDATE canonical_replica_work SET superseded=1 WHERE call_id=?",
          [.text(marker.callId)]
        )
        try database.execute(
          "UPDATE operations SET phase='blocked',failure='call_deleted',retry='never' WHERE call_id=? AND acknowledged=0",
          [.text(marker.callId)]
        )
      }
    }
  }

  public func syncCursor() throws -> String? {
    try database.access {
      try database.rows("SELECT cursor FROM archive_sync_cursor WHERE singleton=1").first?.string(0)
    }
  }

  /// Advance only after every entry in a page has been retained durably. Downloads can then
  /// retry independently from that retained work; an interrupted page is safe to replay.
  public func advanceSyncCursor(_ cursor: String) throws {
    guard !cursor.isEmpty, cursor.utf8.count <= 4096 else { throw CanonicalSyncError.cursorReset }
    try database.access {
      try database.transaction(interruption: interruption) {
        try database.execute(
          "INSERT INTO archive_sync_cursor VALUES (1,?) ON CONFLICT(singleton) DO UPDATE SET cursor=excluded.cursor",
          [.text(cursor)]
        )
      }
    }
  }
}
