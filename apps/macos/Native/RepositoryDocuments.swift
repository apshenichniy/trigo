import Foundation
import TrigoContracts

extension LocalRepository {
  func stageCall(_ document: StoredDocument<CallDocument>) async throws {
    let hash = try await stageDocument(document.storedBytes)
    try await stageCallRows(document.value, hash: hash)
  }

  func stageCallRows(_ call: CallDocument, hash: String) async throws {
    let source = call.source
    try await stageRows(
      "INSERT OR IGNORE INTO call_values VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
      [
        [
          .text(hash), .text(call.callId), .int(call.documentVersion), .text(call.startedAt),
          .string(call.endedAt),
          .int(call.durationMs), .text(call.captureState), .string(call.interruptionReason),
          .text(source.applicationName),
          .text(source.bundleId), .int(source.processId), .int(source.windowId),
          .string(source.windowTitle),
          .string(call.audioManifest?.manifestId), .string(call.audioManifest?.sha256),
          .string(call.activeRevisionId),
        ]
      ]
    )
    try await stageRows(
      "INSERT OR IGNORE INTO call_tracks VALUES (?,?,?,?,?,?,?)",
      call.tracks.enumerated()
        .map { ordinal, track in
          [
            .text(hash), .int(ordinal), .text(track.trackId), .text(track.role),
            .string(track.inputDevice?.id),
            .string(track.inputDevice?.name), .text(track.mediaProfileId),
          ]
        }
    )
    for (trackOrdinal, track) in call.tracks.enumerated() {
      try await stageRows(
        "INSERT OR IGNORE INTO track_intervals VALUES (?,?,?,?,?,?,?)",
        track.intervals.enumerated()
          .map { ordinal, span in
            [
              .text(hash), .int(trackOrdinal), .int(ordinal), .int(span.startMs), .int(span.endMs),
              .text(span.state), .string(span.reason),
            ]
          }
      )
    }
    try await stageRows(
      "INSERT OR IGNORE INTO call_revisions VALUES (?,?,?,?,?)",
      call.revisions.enumerated()
        .map { ordinal, revision in
          [
            .text(hash), .int(ordinal), .text(revision.revisionId), .text(revision.createdAt),
            .text(revision.sha256),
          ]
        }
    )
    try await stageRows(
      "INSERT OR IGNORE INTO speaker_names VALUES (?,?,?,?)",
      call.speakerNames.sorted(by: { $0.key < $1.key })
        .flatMap { revisionID, names in
          names.sorted(by: { $0.key < $1.key })
            .map { speakerID, name in
              [.text(hash), .text(revisionID), .text(speakerID), .text(name)]
            }
        }
    )
    try interruption(.afterRepositoryStaging)
  }

  func stageRevision(_ document: StoredDocument<TranscriptRevision>) async throws {
    let hash = try await stageDocument(document.storedBytes)
    try await stageEvidence(
      hash: hash,
      kind: "revision",
      callID: document.value.callId,
      identity: document.value.revisionId
    )
    try await stageRows(
      "INSERT OR IGNORE INTO revision_speakers VALUES (?,?)",
      document.value.speakers.map {
        [.text(hash), .text($0.speakerId)]
      }
    )
    try await stageRows(
      "INSERT OR IGNORE INTO revision_turns VALUES (?,?,?,?,?,?,?,?)",
      document.value.turns.enumerated()
        .map { ordinal, turn in
          [
            .text(hash), .int(ordinal), .text(turn.turnId), .text(turn.trackId),
            .string(turn.speakerId),
            .int(turn.startMs), .int(turn.endMs), .text(turn.text),
          ]
        }
    )
    for (turnOrdinal, turn) in document.value.turns.enumerated() where !turn.words.isEmpty {
      try await stageRows(
        "INSERT OR IGNORE INTO revision_words VALUES (?,?,?,?,?,?,?)",
        turn.words.enumerated()
          .map { ordinal, word in
            [
              .text(hash), .int(turnOrdinal), .int(ordinal), .text(word.text), .int(word.startMs),
              .int(word.endMs),
              word.confidence.map(SQLValue.real) ?? .null,
            ]
          }
      )
    }
  }

  func stageEvidence(hash: String, kind: String, callID: String, identity: String) async throws {
    try await stageRows(
      "INSERT OR IGNORE INTO evidence_values VALUES (?,?,?,?)",
      [[.text(hash), .text(kind), .text(callID), .text(identity)]]
    )
  }

  func stageRows(_ sql: String, _ rows: [[SQLValue]]) async throws {
    var offset = 0
    while offset < rows.count {
      var end = offset
      var bytes = 0
      var prepared: [[SQLValue]] = []
      while end < rows.count && end - offset < 128 {
        let row = try await prepareTextValues(rows[end])
        let size = row.reduce(0) { result, value in
          result + value.boundByteCount
        }
        if end > offset && bytes + size > 256 * 1024 { break }
        guard size <= 256 * 1024 else { throw invalidRow() }
        prepared.append(row)
        bytes += size
        end += 1
      }
      try database.access {
        try database.transaction {
          for row in prepared { try database.execute(sql, row) }
        }
      }
      offset = end
      await Task.yield()
    }
  }

  func callValue(hash: String, includeIntervals: Bool = true) throws -> CallDocument {
    let storedRow = try database.access {
      guard
        let row =
          try database.rows(
            """
            SELECT call_id,version,started_at,ended_at,duration_ms,capture_state,reason,
            application_name,bundle_id,process_id,window_id,window_title,audio_id,audio_hash,active_revision_id
            FROM call_values WHERE hash=?
            """,
            [.text(hash)]
          )
          .first
      else { throw invalidRow() }
      return row
    }
    let row = try resolveTextValues(storedRow)
    let tracks = try projectionRows("call_tracks", hash: hash).sorted { try $0.int(1) < $1.int(1) }
    var audioTracks: [AudioTrack] = []
    for track in tracks {
      let ordinal = try track.int(1)
      var cursor = -1
      var intervals: [TrackInterval] = []
      while includeIntervals {
        let page = try database.access {
          try database.rows(
            "SELECT ordinal,start_ms,end_ms,state,reason FROM track_intervals WHERE hash=? AND track_ordinal=? AND ordinal>? ORDER BY ordinal LIMIT 128",
            [.text(hash), .int(ordinal), .int(cursor)]
          )
        }
        for storedSpan in page {
          let span = try resolveTextValues(storedSpan)
          intervals.append(
            try .init(
              startMs: span.int(1),
              endMs: span.int(2),
              state: span.string(3),
              reason: span.optionalString(4)
            )
          )
        }
        if page.count < 128 { break }
        cursor = try page.last!.int(0)
      }
      let deviceID = try track.optionalString(4)
      audioTracks.append(
        try .init(
          trackId: track.string(2),
          role: track.string(3),
          inputDevice: deviceID.map { .init(id: $0, name: try track.string(5)) },
          mediaProfileId: track.string(6),
          intervals: intervals
        )
      )
    }
    let revisions = try projectionRows("call_revisions", hash: hash)
      .sorted {
        try $0.int(1) < $1.int(1)
      }
      .map {
        try RevisionReference(
          revisionId: $0.string(2),
          createdAt: $0.string(3),
          sha256: $0.string(4)
        )
      }
    var names: [String: [String: String]] = [:]
    for name in try projectionRows("speaker_names", hash: hash) {
      names[try name.string(1), default: [:]][try name.string(2)] = try name.string(3)
    }
    let audioID = try row.optionalString(12)
    return try .init(
      schemaVersion: 1,
      archiveId: archiveID,
      callId: row.string(0),
      documentVersion: row.int(1),
      startedAt: row.string(2),
      endedAt: row.optionalString(3),
      durationMs: row.optionalInt(4),
      captureState: row.string(5),
      interruptionReason: row.optionalString(6),
      source: .init(
        applicationName: row.string(7),
        bundleId: row.string(8),
        processId: row.int(9),
        windowId: row.optionalInt(10),
        windowTitle: row.optionalString(11)
      ),
      tracks: audioTracks,
      audioManifest: audioID.map { .init(manifestId: $0, sha256: try row.string(13)) },
      revisions: revisions,
      activeRevisionId: row.optionalString(14),
      speakerNames: names
    )
  }

  /// Tables are fixed internal identifiers, never caller input. Content hashes pin immutable
  /// sets between pages, so releasing the reader cannot mix concurrent snapshot versions.
  func projectionRows(_ table: String, hash: String) throws -> [SQLRow] {
    var result: [SQLRow] = []
    var cursor: Int64 = 0
    while true {
      let page = try database.access {
        try database.rows(
          "SELECT rowid,* FROM \(table) WHERE hash=? AND rowid>? ORDER BY rowid LIMIT 128",
          [.text(hash), .integer(cursor)]
        )
      }
      result.append(
        contentsOf: try page.map {
          try resolveTextValues(SQLRow(values: Array($0.values.dropFirst())))
        }
      )
      if page.count < 128 { return result }
      cursor = try page.last!.integer(0)
    }
  }

  /// Variable-size relational strings remain UTF-8 values, never JSON. Large cells use the
  /// same bounded immutable chunk store; a reserved literal prefix is escaped the same way.
  func prepareTextValues(_ values: [SQLValue]) async throws -> [SQLValue] {
    var result: [SQLValue] = []
    for value in values {
      if case .text(let text) = value,
        text.utf8.count > 4096 || text.hasPrefix(repositoryTextPrefix)
      {
        let hash = try await stageDocument(Data(text.utf8))
        result.append(.text(repositoryTextPrefix + hash))
      } else {
        result.append(value)
      }
    }
    return result
  }

  func resolveTextValues(_ row: SQLRow) throws -> SQLRow {
    try SQLRow(
      values: row.values.map { value in
        guard case .text(let text) = value, text.hasPrefix(repositoryTextPrefix) else {
          return value
        }
        let bytes = try documentBytes(String(text.dropFirst(repositoryTextPrefix.count)))
        guard let decoded = String(data: bytes, encoding: .utf8) else { throw invalidRow() }
        return .text(decoded)
      }
    )
  }
}

private let repositoryTextPrefix = "@trigo-text-v1:"

extension SQLValue {
  var boundByteCount: Int {
    switch self {
    case .text(let value): value.utf8.count
    case .blob(let value): value.count
    default: 8
    }
  }
}
