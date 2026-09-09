import Foundation

/// Compact reader metadata. Listing calls never materializes audio intervals or transcript JSON.
public struct LibraryCall: Identifiable, Sendable, Equatable {
  public let callID: String
  public let documentVersion: Int
  public let startedAt: String
  public let durationMs: Int?
  public let applicationName: String
  public let bundleID: String
  public let windowTitle: String?
  public let activeRevisionID: String?
  public let lifecycle: CallLifecycleSnapshot
  public var id: String { callID }
  public var sourceDescription: String {
    if let windowTitle, !windowTitle.isEmpty { return "\(applicationName) · \(windowTitle)" }
    return applicationName
  }
  public var startedDate: Date { LibraryDate.date(startedAt) }
  public var interruptionExplanation: String {
    recordingInterruptionExplanation(lifecycle.capture.failure?.code)
  }
}

public struct LibraryRevision: Identifiable, Sendable, Equatable {
  public let revisionID: String
  public let createdAt: String
  public let sha256: String
  public let turnCount: Int
  public var id: String { revisionID }
}

extension LocalRepository {
  public func libraryCalls(
    after callID: String = "",
    limit: Int = 100
  ) async throws -> [LibraryCall] {
    guard (1...128).contains(limit) else { throw invalidRow() }
    return try libraryRows(predicate: "c.call_id>?", value: callID, limit: limit)
  }

  public func libraryCall(callID: String) async throws -> LibraryCall? {
    try requireCanonicalIdentifier(callID)
    return try libraryRows(predicate: "c.call_id=?", value: callID, limit: 1).first
  }

  public func libraryRevisions(callID: String) async throws -> [LibraryRevision] {
    guard let hash = try currentHash(callID) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    let rows = try projectionRows("call_revisions", hash: hash)
    return
      try rows.map { stored in
        let row = try resolveTextValues(stored)
        let count = try database.access {
          try database
            .rows("SELECT COUNT(*) FROM revision_turns WHERE hash=?", [.text(row.string(4))])
            .first?
            .int(0) ?? 0
        }
        return try LibraryRevision(
          revisionID: row.string(2),
          createdAt: row.string(3),
          sha256: row.string(4),
          turnCount: count
        )
      }
      .sorted { a, b in
        a.createdAt == b.createdAt ? a.revisionID > b.revisionID : a.createdAt > b.createdAt
      }
  }

  private func libraryRows(predicate: String, value: String, limit: Int) throws -> [LibraryCall] {
    let rows = try database.access {
      try database.rows(
        """
        SELECT c.call_id,v.version,v.started_at,v.duration_ms,v.application_name,v.bundle_id,v.window_title,v.active_revision_id
        FROM calls c JOIN call_values v ON v.hash=c.hash JOIN lifecycle l ON l.call_id=c.call_id
        WHERE \(predicate) AND l.deletion='active'
          AND NOT EXISTS(SELECT 1 FROM local_deletion_markers d WHERE d.call_id=c.call_id)
        ORDER BY c.call_id LIMIT ?
        """,
        [.text(value), .int(limit)]
      )
      .map { row in
        guard let lifecycle = try lifecycleRow(row.string(0)) else { throw invalidRow() }
        return (row, lifecycle)
      }
    }
    return try rows.map { stored, lifecycle in
      let row = try resolveTextValues(stored)
      return try LibraryCall(
        callID: row.string(0),
        documentVersion: row.int(1),
        startedAt: row.string(2),
        durationMs: row.optionalInt(3),
        applicationName: row.string(4),
        bundleID: row.string(5),
        windowTitle: row.optionalString(6),
        activeRevisionID: row.optionalString(7),
        lifecycle: decodeLifecycle(resolveTextValues(lifecycle), callID: row.string(0))
      )
    }
  }
}

public enum LibraryDate {
  public static func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) ?? .distantPast
  }

  public static func clock(_ milliseconds: Int) -> String {
    let seconds = max(0, milliseconds) / 1000
    if seconds >= 3600 {
      return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
