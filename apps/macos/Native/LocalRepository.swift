import Foundation
import TrigoContracts

/// Canonical archive, lifecycle and durable operations share this semantic transaction owner.
/// Instances in the same namespace share one scheduled SQLite connection. Media and effects
/// stay outside its transactions; immutable preparation is invisible until publication.
public final class LocalRepository: Sendable {
  let database: SQLiteDatabase
  let interruption: PersistenceInterruption
  public var archiveID: String { database.archiveID }
  public var root: URL { database.root }

  public init(
    root: URL,
    archiveID: String,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) throws {
    database = try SQLiteDatabase.open(root: root, archiveID: archiveID)
    self.interruption = interruption
  }

  public func publishManifest(_ bytes: Data) async throws -> PublicationResult {
    let proposed = try Contract.decodeCallSnapshot(bytes)
    try requireArchiveIdentity(proposed.value.archiveId)
    if let retained = try database.access({
      try database
        .rows(
          "SELECT hash FROM snapshot_history WHERE call_id=? AND version=?",
          [.text(proposed.value.callId), .int(proposed.value.documentVersion)]
        )
        .first?
        .string(0)
    }) {
      guard retained == proposed.sha256, try documentBytes(retained) == bytes else {
        throw LocalPersistenceError.immutableConflict(
          "\(proposed.value.callId):\(proposed.value.documentVersion)"
        )
      }
      return .alreadyPresent
    }
    let priorHash = try currentHash(proposed.value.callId)
    if priorHash == proposed.sha256 {
      guard try documentBytes(priorHash!) == bytes else {
        throw LocalPersistenceError.immutableConflict(proposed.value.callId)
      }
      return .alreadyPresent
    }
    if let priorHash {
      guard try Contract.validateCallSnapshot(bytes).kind != "LegacyCallDocument" else {
        throw CanonicalSyncError.incompatibleDocument
      }
      let current = try callValue(hash: priorHash)
      try validatePublication(from: current, to: proposed.value)
      if try hasSession(proposed.value.callId), captureChanged(current, proposed.value) {
        throw LocalPersistenceError.captureStateOwnedByRepository
      }
    }
    _ = try Contract.validateArchive(bytes, references: referenceBytes(proposed.value))
    try await stageCall(proposed)
    let upgrade =
      try await
      (Contract.validateCallSnapshot(bytes).kind == "LegacyCallDocument"
      ? prepareLegacyUpgrade(proposed) : nil)
    return try database.access {
      try database.transaction(interruption: interruption) {
        let result = try commitCall(proposed.value, hash: proposed.sha256, expected: priorHash)
        if let upgrade {
          _ = try commitCall(
            upgrade.snapshot.value,
            hash: upgrade.snapshot.sha256,
            expected: proposed.sha256
          )
          if let operation = upgrade.operation {
            try commitReplicaWork(operation, snapshot: upgrade.snapshot, annotationRevisionIDs: [])
          }
        }
        return result
      }
    }
  }

  /// Exchange export retains the originally published bytes for every concrete version.
  public func snapshotBytes(callID: String, version: Int) async throws -> Data {
    try requireCanonicalIdentifier(callID)
    let hash = try database.access {
      try database
        .rows(
          "SELECT hash FROM snapshot_history WHERE call_id=? AND version=?",
          [.text(callID), .int(version)]
        )
        .first?
        .string(0)
    }
    guard let hash else { throw LocalPersistenceError.callNotFound(callID) }
    return try documentBytes(hash)
  }

  /// Pinned immutable projection reads release SQL access after each bounded page. They do
  /// not decode or validate JSON. Exact bytes are fetched only for the requested aggregate.
  public func loadCall(callID: String) async throws -> LocalCallAggregate {
    guard let hash = try currentHash(callID) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    let value = try callValue(hash: hash)
    return LocalCallAggregate(
      manifest: StoredDocument(value: value, storedBytes: try documentBytes(hash)),
      transcriptRevisions: try Dictionary(
        uniqueKeysWithValues: value.revisions.map {
          ($0.revisionId, try documentBytes($0.sha256))
        }
      ),
      audioManifest: try value.audioManifest.map { try documentBytes($0.sha256) }
    )
  }

  public func call(callID: String) async throws -> CallDocument {
    guard let hash = try currentHash(callID) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    return try callValue(hash: hash)
  }

  /// Keyset pagination is the normal list projection, capped per query, with no long reader.
  public func calls(
    after callID: String? = nil,
    limit: Int = 100
  ) async throws
    -> [LocalCallSummary]
  {
    guard (1...128).contains(limit) else {
      throw LocalPersistenceError.invalidStoredDocument("Invalid projection page size")
    }
    let rows = try database.access {
      try database.rows(
        """
        SELECT c.call_id, v.version, v.started_at, v.duration_ms, v.capture_state, v.reason
        FROM calls c JOIN call_values v ON v.hash=c.hash JOIN lifecycle l ON l.call_id=c.call_id
        WHERE c.call_id>? AND l.deletion='active' AND NOT EXISTS(SELECT 1 FROM local_deletion_markers d WHERE d.call_id=c.call_id)
        ORDER BY c.call_id LIMIT ?
        """,
        [.text(callID ?? ""), .int(limit)]
      )
    }
    return try rows.map { try resolveTextValues($0) }
      .map {
        try LocalCallSummary(
          callID: $0.string(0),
          documentVersion: $0.int(1),
          startedAt: $0.string(2),
          durationMs: $0.optionalInt(3),
          captureState: captureState($0.string(4)),
          interruptionReason: $0.optionalString(5)
        )
      }
  }

  public func callIDs() async throws -> [String] {
    var result: [String] = []
    while true {
      let page = try await calls(after: result.last)
      result.append(contentsOf: page.map(\.callID))
      if page.count < 100 { return result }
    }
  }

  /// Reports corrupt retained entities; there is no metadata-publication repair or cleanup.
  public func inspectArchive() async throws -> ArchiveReconciliationReport {
    var valid: [String] = []
    var rejected: [String] = []
    for id in try await callIDs() {
      do {
        _ = try await loadCall(callID: id)
        guard try await lifecycle(callID: id) != nil else { throw invalidRow() }
        valid.append(id)
      } catch { rejected.append(id) }
    }
    return .init(validCallIDs: valid, rejectedCallIDs: rejected)
  }

  public func publishAudioManifest(_ bytes: Data) async throws -> PublicationResult {
    let document = try Contract.decode(AudioManifest.self, bytes: bytes)
    let current = try await call(callID: document.value.callId)
    try validateAudioManifest(document.value, against: current)
    try await stageDocument(bytes)
    try await stageEvidence(
      hash: document.sha256,
      kind: "audio",
      callID: document.value.callId,
      identity: document.value.manifestId
    )
    return try database.access {
      try database.transaction(interruption: interruption) {
        try commitEvidence(
          identity: document.value.manifestId,
          kind: "audio",
          callID: document.value.callId,
          hash: document.sha256
        )
      }
    }
  }

  /// Staging an immutable revision is explicit and does not claim local import completion.
  /// Production import callers use importRevision with their durable associated work.
  public func publishTranscriptRevision(_ bytes: Data) async throws -> PublicationResult {
    let document = try Contract.decode(TranscriptRevision.self, bytes: bytes)
    _ = try await call(callID: document.value.callId)
    try validateRevisionAudioReference(document.value)
    try await stageRevision(document)
    return try database.access {
      try database.transaction(interruption: interruption) {
        try commitEvidence(
          identity: document.value.revisionId,
          kind: "revision",
          callID: document.value.callId,
          hash: document.sha256
        )
      }
    }
  }

  public func transcriptRevisionBytes(callID: String, revisionID: String) async throws -> Data {
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(revisionID)
    return try documentBytes(
      requiredEvidence(identity: revisionID, kind: "revision", callID: callID)
    )
  }

  /// Bounded typed transcript query; staged and unreferenced revisions remain unreachable.
  public func turns(
    callID: String,
    revisionID: String,
    after ordinal: Int = -1,
    limit: Int = 100
  )
    async throws -> [LocalTurn]
  {
    guard (1...128).contains(limit), ordinal >= -1 else { throw invalidRow() }
    guard let hash = try currentHash(callID) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    let revisionRows = try database.access {
      try database.rows(
        "SELECT revision_hash FROM call_revisions WHERE hash=? AND revision_id=?",
        [.text(hash), .text(revisionID)]
      )
    }
    guard let revisionHash = try revisionRows.first?.string(0) else { return [] }
    try await ensurePassages(hash: revisionHash)
    let rows = try database.access {
      try database.rows(
        """
        SELECT p.ordinal,t.turn_id,t.track_id,t.speaker_id,p.start_ms,p.end_ms,p.text,coalesce(g.display_name,n.name),
          p.approximate,p.first_word_ordinal
        FROM call_revisions r JOIN revision_passages p ON p.hash=r.revision_hash
        JOIN revision_turns t ON t.hash=p.hash AND t.ordinal=p.turn_ordinal
        LEFT JOIN speaker_names n ON n.hash=r.hash AND n.revision_id=r.revision_id AND n.speaker_id=t.speaker_id
        LEFT JOIN call_group_members m ON m.hash=r.hash AND m.revision_id=r.revision_id AND m.speaker_id=t.speaker_id
        LEFT JOIN call_speaker_groups g ON g.hash=m.hash AND g.group_id=m.group_id
        WHERE r.hash=? AND r.revision_id=? AND p.ordinal>? ORDER BY p.ordinal LIMIT ?
        """,
        [.text(hash), .text(revisionID), .int(ordinal), .int(limit)]
      )
    }
    return try rows.map { try resolveTextValues($0) }
      .map {
        try LocalTurn(
          ordinal: $0.int(0),
          turnID: $0.string(1),
          trackID: $0.string(2),
          speakerID: $0.optionalString(3),
          startMs: $0.int(4),
          endMs: $0.int(5),
          text: $0.string(6),
          speakerName: $0.optionalString(7),
          hasApproximateTiming: $0.int(8) == 1,
          firstWordOrdinal: $0.int(9)
        )
      }
  }

  func currentHash(_ callID: String) throws -> String? {
    try requireCanonicalIdentifier(callID)
    return try database.access {
      try requireActiveCallLocked(callID)
      return try currentHashLocked(callID)
    }
  }

  func currentHashLocked(_ callID: String) throws -> String? {
    try database.rows("SELECT hash FROM calls WHERE call_id=?", [.text(callID)]).first?.string(0)
  }

  func requireArchiveIdentity(_ actual: String) throws {
    guard actual == archiveID else {
      throw LocalPersistenceError.archiveIdentityMismatch(expected: archiveID, actual: actual)
    }
  }

  func referenceBytes(_ call: CallDocument) throws -> [String: Data] {
    var result: [String: Data] = [:]
    if let audio = call.audioManifest {
      let hash = try requiredEvidence(
        identity: audio.manifestId,
        kind: "audio",
        callID: call.callId
      )
      guard hash == audio.sha256 else { throw ContractError.checksum }
      result[audio.manifestId] = try documentBytes(hash)
    }
    for revision in call.revisions {
      let hash = try requiredEvidence(
        identity: revision.revisionId,
        kind: "revision",
        callID: call.callId
      )
      guard hash == revision.sha256 else { throw ContractError.checksum }
      result[revision.revisionId] = try documentBytes(hash)
    }
    return result
  }

  func requiredEvidence(identity: String, kind: String, callID: String) throws -> String {
    guard
      let row = try database.access({
        try database.rows(
          "SELECT kind,call_id,hash FROM evidence WHERE identity=?",
          [.text(identity)]
        )
        .first
      }), try row.string(0) == kind, try row.string(1) == callID
    else { throw ContractError.reference }
    return try row.string(2)
  }

  func validateRevisionAudioReference(_ revision: TranscriptRevision) throws {
    let hash = try requiredEvidence(
      identity: revision.audioManifest.manifestId,
      kind: "audio",
      callID: revision.callId
    )
    guard hash == revision.audioManifest.sha256 else { throw ContractError.checksum }
  }

  func validatePublication(
    from current: CallDocument,
    to proposed: CallDocument,
    allowedAnnotationRevisionIDs: Set<String> = []
  ) throws {
    guard proposed.documentVersion > current.documentVersion else {
      throw LocalPersistenceError.staleDocumentVersion(
        current: current.documentVersion,
        proposed: proposed.documentVersion
      )
    }
    guard current.callId == proposed.callId, current.archiveId == proposed.archiveId,
      current.startedAt == proposed.startedAt, current.source == proposed.source,
      current.tracks.map(\.trackId) == proposed.tracks.map(\.trackId),
      zip(current.tracks, proposed.tracks)
        .allSatisfy({
          $0.role == $1.role && $0.inputDevice == $1.inputDevice
            && $0.mediaProfileId == $1.mediaProfileId
        })
    else { throw LocalPersistenceError.immutableConflict(current.callId) }
    try validateEvolution(
      from: current,
      to: proposed,
      allowedAnnotationRevisionIDs: allowedAnnotationRevisionIDs
    )
  }

  func captureChanged(_ a: CallDocument, _ b: CallDocument) -> Bool {
    a.captureState != b.captureState || a.interruptionReason != b.interruptionReason
      || a.durationMs != b.durationMs
      || a.endedAt != b.endedAt || a.tracks != b.tracks || a.audioManifest != b.audioManifest
  }

  /// Called only while the connection owner holds a semantic transaction.
  func commitCall(_ call: CallDocument, hash: String, expected: String?) throws -> PublicationResult
  {
    try requireActiveCallLocked(call.callId)
    let current = try currentHashLocked(call.callId)
    if current == hash { return .alreadyPresent }
    guard current == expected else { throw LocalPersistenceError.concurrentMutation }
    if let prior =
      try database.rows(
        "SELECT hash FROM snapshot_history WHERE call_id=? AND version=?",
        [.text(call.callId), .int(call.documentVersion)]
      )
      .first
    {
      guard try prior.string(0) == hash else {
        throw LocalPersistenceError.immutableConflict("\(call.callId):\(call.documentVersion)")
      }
    }
    try database.execute(
      "INSERT INTO calls VALUES (?,?) ON CONFLICT(call_id) DO UPDATE SET hash=excluded.hash",
      [.text(call.callId), .text(hash)]
    )
    try database.execute(
      "INSERT OR IGNORE INTO snapshot_history VALUES (?,?,?)",
      [.text(call.callId), .int(call.documentVersion), .text(hash)]
    )
    if current == nil {
      try insertLifecycle(.initial(archiveID: archiveID, callID: call.callId))
    } else {
      try database.execute(
        "UPDATE lifecycle SET state_version=state_version+1 WHERE call_id=?",
        [.text(call.callId)]
      )
    }
    try retainGroupHistoryLocked(call)
    return .committed
  }

  func commitEvidence(
    identity: String,
    kind: String,
    callID: String,
    hash: String
  ) throws
    -> PublicationResult
  {
    if let row =
      try database.rows(
        "SELECT kind,call_id,hash FROM evidence WHERE identity=?",
        [.text(identity)]
      )
      .first
    {
      guard try row.string(0) == kind, try row.string(1) == callID, try row.string(2) == hash else {
        throw LocalPersistenceError.immutableConflict(identity)
      }
      return .alreadyPresent
    }
    try database.execute(
      "INSERT INTO evidence VALUES (?,?,?,?)",
      [.text(identity), .text(kind), .text(callID), .text(hash)]
    )
    return .committed
  }
}

public struct LocalCallSummary: Sendable, Equatable {
  public let callID: String
  public let documentVersion: Int
  public let startedAt: String
  public let durationMs: Int?
  public let captureState: CaptureLifecycleState
  public let interruptionReason: String?
}

public struct LocalTurn: Sendable, Equatable {
  public let ordinal: Int
  public let turnID: String
  public let trackID: String
  public let speakerID: String?
  public let startMs: Int
  public let endMs: Int
  public let text: String
  public let speakerName: String?
  public let hasApproximateTiming: Bool
  public let firstWordOrdinal: Int
  public var passageID: String { firstWordOrdinal == 0 ? turnID : "\(turnID):\(firstWordOrdinal)" }

  public init(
    ordinal: Int,
    turnID: String,
    trackID: String,
    speakerID: String?,
    startMs: Int,
    endMs: Int,
    text: String,
    speakerName: String?,
    hasApproximateTiming: Bool = false,
    firstWordOrdinal: Int = 0
  ) {
    self.ordinal = ordinal
    self.turnID = turnID
    self.trackID = trackID
    self.speakerID = speakerID
    self.startMs = startMs
    self.endMs = endMs
    self.text = text
    self.speakerName = speakerName
    self.hasApproximateTiming = hasApproximateTiming
    self.firstWordOrdinal = firstWordOrdinal
  }
}

func captureState(_ value: String) throws -> CaptureLifecycleState {
  guard let state = CaptureLifecycleState(rawValue: value) else { throw invalidRow() }
  return state
}
