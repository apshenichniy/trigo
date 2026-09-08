import Foundation
import TrigoContracts

public struct LocalSpeaker: Sendable, Equatable, Identifiable {
  public let revisionID: String
  public let speakerID: String
  public let ordinal: Int
  public let trackID: String
  public let trackRole: String
  public let diarizationScopeID: String
  public let providerLabel: String?
  public let individualName: String?
  public let groupID: String?
  public let groupName: String?
  public let excerpt: LocalTurn?
  public var id: String { speakerID }
  public var neutralLabel: String { "Speaker \(ordinal + 1)" }
  public var displayName: String { groupName ?? individualName ?? neutralLabel }
}

extension LocalRepository {
  func stageSpeakerDetails(_ revision: TranscriptRevision, hash: String) async throws {
    try await stageRows(
      "INSERT OR IGNORE INTO speaker_details VALUES (?,?,?,?,?,?)",
      revision.speakers.enumerated()
        .map { ordinal, speaker in
          [
            .text(hash), .text(speaker.speakerId), .int(ordinal), .text(speaker.trackId),
            .text(speaker.diarizationScopeId), .string(speaker.providerLabel),
          ]
        }
    )
  }

  /// Older stores gain this rebuildable projection lazily from exact retained evidence.
  /// Speaker order belongs to the immutable revision, so labels survive every name/group edit.
  public func speakers(
    callID: String,
    revisionID: String,
    after ordinal: Int = -1,
    limit: Int = 100
  ) async throws -> [LocalSpeaker] {
    guard (1...128).contains(limit), ordinal >= -1, let hash = try currentHash(callID) else {
      throw CanonicalSyncError.invalidAnnotation
    }
    let revisionHash = try requiredEvidence(identity: revisionID, kind: "revision", callID: callID)
    let missing = try database.access {
      try
        !database.rows(
          "SELECT r.speaker_id FROM revision_speakers r LEFT JOIN speaker_details d ON d.hash=r.hash AND d.speaker_id=r.speaker_id WHERE r.hash=? AND d.speaker_id IS NULL LIMIT 1",
          [.text(revisionHash)]
        )
        .isEmpty
    }
    if missing {
      let revision =
        try Contract.decode(TranscriptRevision.self, bytes: documentBytes(revisionHash)).value
      try await stageSpeakerDetails(revision, hash: revisionHash)
    }
    let rows = try database.access {
      try database.rows(
        """
        SELECT s.speaker_id,s.ordinal,s.track_id,t.role,s.scope_id,s.provider_label,n.name,g.group_id,g.display_name,
          x.ordinal,x.turn_id,x.track_id,x.speaker_id,x.start_ms,x.end_ms,x.text
        FROM call_revisions r JOIN speaker_details s ON s.hash=r.revision_hash
        JOIN call_tracks t ON t.hash=r.hash AND t.track_id=s.track_id
        LEFT JOIN speaker_names n ON n.hash=r.hash AND n.revision_id=r.revision_id AND n.speaker_id=s.speaker_id
        LEFT JOIN call_group_members m ON m.hash=r.hash AND m.revision_id=r.revision_id AND m.speaker_id=s.speaker_id
        LEFT JOIN call_speaker_groups g ON g.hash=m.hash AND g.group_id=m.group_id
        LEFT JOIN revision_turns x ON x.hash=s.hash AND x.ordinal=(SELECT MIN(e.ordinal) FROM revision_turns e WHERE e.hash=s.hash AND e.speaker_id=s.speaker_id)
        WHERE r.hash=? AND r.revision_id=? AND s.ordinal>? ORDER BY s.ordinal LIMIT ?
        """,
        [.text(hash), .text(revisionID), .int(ordinal), .int(limit)]
      )
    }
    return try rows.map { stored in
      let row = try resolveTextValues(stored)
      let groupName = try row.optionalString(8)
      let individual = try row.optionalString(6)
      let excerpt: LocalTurn?
      if let ordinal = try row.optionalInt(9) {
        excerpt = try .init(
          ordinal: ordinal,
          turnID: row.string(10),
          trackID: row.string(11),
          speakerID: row.optionalString(12),
          startMs: row.int(13),
          endMs: row.int(14),
          text: row.string(15),
          speakerName: groupName ?? individual
        )
      } else {
        excerpt = nil
      }
      return try .init(
        revisionID: revisionID,
        speakerID: row.string(0),
        ordinal: row.int(1),
        trackID: row.string(2),
        trackRole: row.string(3),
        diarizationScopeID: row.string(4),
        providerLabel: row.optionalString(5),
        individualName: individual,
        groupID: row.optionalString(7),
        groupName: groupName,
        excerpt: excerpt
      )
    }
  }

  func presentationVersion() throws -> [Int] {
    try database.access {
      guard
        let row = try database.rows("SELECT COUNT(*),COALESCE(SUM(state_version),0) FROM lifecycle")
          .first
      else { return [] }
      let syncVersion =
        try database.rows("SELECT state_version FROM archive_sync_status WHERE singleton=1").first?
        .int(0) ?? 0
      return try [row.int(0), row.int(1), syncVersion]
    }
  }
}
