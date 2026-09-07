import Foundation
import TrigoContracts

public struct CaptureCompletion: Sendable, Equatable {
  public let call: LocalCallSummary
  public let master: FinalizedMediaMaster?
  public let snapshotSHA256: String
  public let snapshotByteLength: Int
}

extension LocalRepository {
  /// Finalization consumes admitted identity, issued external witness and bounded source rows.
  /// It does not re-import those trusted rows through the full public JSON document decoder.
  public func completeCapture(
    _ session: CaptureArchiveSession, master: FinalizedMediaMaster?, reason: String?,
    associatedWork: OperationIntent? = nil,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) async throws -> CaptureCompletion {
    guard try await captureSession(callID: session.callID) == session else {
      throw LocalPersistenceError.immutableConflict(session.callID)
    }
    let publication = try await prepareCapturePublication(
      callID: session.callID, reason: reason, associatedWork: associatedWork)
    let operation = publication.operation
    let effectiveReason = publication.reason
    if let existing = try captureCompletion(callID: session.callID) {
      guard existing.master == master, existing.call.interruptionReason == effectiveReason else {
        throw LocalPersistenceError.immutableConflict(session.masterID)
      }
      try database.access(capture: true) {
        try database.transaction {
          try validateSemanticWork("finalize:\(session.callID)", operation: operation)
        }
      }
      return existing
    }
    try validateCaptureMaster(master, session: session)
    guard let priorHash = try currentHash(session.callID) else {
      throw LocalPersistenceError.callNotFound(session.callID)
    }
    var call = try callValue(hash: priorHash)
    guard call.captureState == "recording", call.audioManifest == nil,
      call.tracks.allSatisfy({ $0.intervals.isEmpty }), call.revisions.isEmpty
    else {
      throw LocalPersistenceError.invalidMediaProgress
    }
    let audio = try session.audioBytes(master)
    let audioDocument = try Contract.decode(AudioManifest.self, bytes: audio)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    call.documentVersion += 1
    call.durationMs = master?.durationMs ?? 0
    call.endedAt = formatter.string(
      from: session.startedAt.addingTimeInterval(Double(call.durationMs!) / 1000))
    call.captureState = effectiveReason == nil ? "stopped" : "interrupted"
    call.interruptionReason = effectiveReason
    call.audioManifest = .init(manifestId: session.audioManifestID, sha256: audioDocument.sha256)
    try validatePublication(from: callValue(hash: priorHash), to: call)
    try validateAudioManifest(audioDocument.value, against: call)
    let snapshot = try CaptureSnapshotStream()
    try snapshot.encode(call) { channel, consume in
      var iterator = CaptureIntervalCursor(
        repository: self, callID: session.callID, cursor: master?.cursor, channel: channel)
      while let span = try iterator.next() { try consume(span) }
    }
    let hash = try snapshot.finish()
    try await stageSnapshot(snapshot, hash: hash)
    try await stageCallRows(call, hash: hash)
    for channel in 0..<2 {
      var iterator = CaptureIntervalCursor(
        repository: self, callID: session.callID, cursor: master?.cursor, channel: channel)
      var ordinal = 0
      while true {
        var rows: [[SQLValue]] = []
        while rows.count < 128, let span = try iterator.next() {
          rows.append([
            .text(hash), .int(channel), .int(ordinal), .int(span.startMs), .int(span.endMs),
            .text(span.state), .string(span.reason),
          ])
          ordinal += 1
        }
        if rows.isEmpty { break }
        try await stageRows("INSERT OR IGNORE INTO track_intervals VALUES (?,?,?,?,?,?,?)", rows)
      }
    }
    _ = try await stageDocument(audio)
    try await stageEvidence(
      hash: audioDocument.sha256, kind: "audio", callID: session.callID,
      identity: session.audioManifestID)
    try database.access(capture: true) {
      try database.transaction(interruption: { point in
        try self.interruption(point)
        try interruption(point)
      }) {
        _ = try commitEvidence(
          identity: session.audioManifestID, kind: "audio", callID: session.callID,
          hash: audioDocument.sha256)
        _ = try commitCall(call, hash: hash, expected: priorHash)
        if let master { try commitFinalMaster(master, callID: session.callID) }
        try commitSemanticWork("finalize:\(session.callID)", operation: operation)
      }
    }
    guard let result = try captureCompletion(callID: session.callID) else { throw invalidRow() }
    return result
  }

  /// Both trusted streaming publication and public exchange admission share the same
  /// issued witness checks. Absence cannot hide opened media or invent a zero master.
  func validateCaptureMaster(_ master: FinalizedMediaMaster?, session: CaptureArchiveSession) throws
  {
    if let master {
      guard master.cursor.identity == session.mediaMasterIdentity,
        master.cursor.frames % 16 == 0,
        master.cursor.frames <= MediaMasterProfile.maximumFrames,
        try
          (confirmedMediaCursor(callID: session.callID)
          ?? initialCursor(session.mediaMasterIdentity)) == master.cursor
      else {
        throw LocalPersistenceError.invalidMediaProgress
      }
      _ = try digestBytes(master.sha256)
      guard
        master.cursor.frames != 0
          || master.sha256 == MediaMasterProfile.header.masterSHA256.masterHex
      else {
        throw LocalPersistenceError.invalidMediaProgress
      }
    } else {
      guard try confirmedMediaCursor(callID: session.callID) == nil,
        !FileManager.default.fileExists(
          atPath: session.mediaDirectory.appendingPathComponent("master.caf").path),
        !FileManager.default.fileExists(
          atPath: session.mediaDirectory.appendingPathComponent("master.index").path)
      else {
        throw LocalPersistenceError.invalidMediaProgress
      }
    }
  }

  public func captureCompletion(callID: String) throws -> CaptureCompletion? {
    guard
      let stored = try database.access({
        try database.rows(
          """
          SELECT v.call_id,v.version,v.started_at,v.duration_ms,v.capture_state,v.reason,c.hash,d.byte_count
          FROM calls c JOIN call_values v ON v.hash=c.hash JOIN documents d ON d.hash=c.hash
          WHERE c.call_id=? AND v.capture_state!='recording'
          """, [.text(callID)]
        ).first
      })
    else { return nil }
    let row = try resolveTextValues(stored)
    return try .init(
      call: .init(
        callID: row.string(0), documentVersion: row.int(1), startedAt: row.string(2),
        durationMs: row.optionalInt(3), captureState: captureState(row.string(4)),
        interruptionReason: row.optionalString(5)),
      master: finalizedMaster(callID: callID), snapshotSHA256: row.string(6),
      snapshotByteLength: row.int(7))
  }

  private func stageSnapshot(_ file: CaptureSnapshotStream, hash: String) async throws {
    let reader = try FileHandle(forReadingFrom: file.url)
    defer { try? reader.close() }
    try await stageDocumentChunks(hash: hash, byteCount: file.byteCount) {
      try reader.readMasterBytes(upToCount: repositoryDocumentChunkBytes)
    }
  }

  /// Exact retained exchange bytes, one bounded chunk at a time; no regeneration or JSON rewrite.
  public func forEachSnapshotChunk(callID: String, version: Int, consume: (Data) throws -> Void)
    throws
  {
    guard
      let row = try database.access({
        try database.rows(
          "SELECT h.hash FROM snapshot_history h JOIN documents d ON d.hash=h.hash WHERE h.call_id=? AND h.version=? AND d.complete=1",
          [.text(callID), .int(version)]
        ).first
      })
    else { throw LocalPersistenceError.callNotFound(callID) }
    try forEachDocumentChunk(hash: row.string(0), consume: consume)
  }
}
