import Foundation

extension LocalRepository {
  /// Synchronous for #51's serialized append/recovery callback. The certificate must come
  /// from successful external media+index synchronization, never a file-length observation.
  /// At most one second and 2,000 source intervals enter this bounded transaction.
  @discardableResult
  public func commitMediaProgress(_ commit: MediaMasterCommit) throws -> PublicationResult {
    let callID = commit.cursor.identity.callID.uuidString.lowercased()
    let identity = try masterIdentity(callID)
    guard identity == commit.cursor.identity else { throw MediaMasterError.identityMismatch }
    if let existing = try mediaCommit(callID: callID, sequence: commit.cursor.commitCount) {
      guard existing == commit else {
        throw LocalPersistenceError.immutableConflict(
          "media:\(callID):\(commit.cursor.commitCount)")
      }
      return .alreadyPresent
    }
    let prior = try confirmedMediaCursor(callID: callID) ?? initialCursor(identity)
    try validateMediaCommit(commit, after: prior)
    return try database.access(capture: true) {
      try database.transaction(interruption: interruption) {
        let row = try database.rows(
          "SELECT sequence,finalized_hash FROM capture_progress WHERE call_id=?", [.text(callID)]
        ).first
        let current = try row?.optionalInt(0) ?? 0
        guard current == prior.commitCount, try row?.optionalString(1) == nil else {
          throw LocalPersistenceError.concurrentMutation
        }
        guard
          let state = try database.rows(
            "SELECT v.capture_state FROM calls c JOIN call_values v ON v.hash=c.hash WHERE c.call_id=?",
            [.text(callID)]
          ).first,
          try state.string(0) == "recording"
        else { throw LocalPersistenceError.invalidMediaProgress }
        try database.execute(
          "INSERT INTO media_commits VALUES (?,?,?,?,?,?,?)",
          [
            .text(callID), .integer(commit.cursor.commitCount), .integer(commit.startFrame),
            .integer(commit.cursor.frames),
            .integer(commit.cursor.stableBytes), .text(commit.cursor.integritySHA256),
            .text(commit.pcmSHA256),
          ])
        for (channel, intervals) in [commit.microphoneIntervals, commit.applicationIntervals]
          .enumerated()
        {
          for (ordinal, interval) in intervals.enumerated() {
            try database.execute(
              "INSERT INTO media_intervals VALUES (?,?,?,?,?,?,?)",
              [
                .text(callID), .integer(commit.cursor.commitCount), .int(channel), .int(ordinal),
                .int(interval.startMs), .int(interval.endMs), .text(interval.state.rawValue),
              ])
          }
        }
        try database.execute(
          "INSERT INTO capture_progress VALUES (?,?,NULL) ON CONFLICT(call_id) DO UPDATE SET sequence=excluded.sequence",
          [.text(callID), .integer(commit.cursor.commitCount)])
        return .committed
      }
    }
  }

  public func confirmedMediaCursor(callID: String) throws -> MediaMasterCursor? {
    let identity = try masterIdentity(callID)
    return try database.access(capture: true) {
      guard
        let row = try database.rows(
          """
          SELECT m.frames,m.stable_bytes,m.sequence,m.integrity_hash,p.finalized_hash
          FROM capture_progress p LEFT JOIN media_commits m ON m.call_id=p.call_id AND m.sequence=p.sequence
          WHERE p.call_id=?
          """, [.text(callID)]
        ).first
      else { return nil }
      if try row.optionalInt(2) == nil {
        guard let hash = try row.optionalString(4) else { throw invalidRow() }
        _ = try digestBytes(hash)
        return initialCursor(identity)
      }
      return try .init(
        identity: identity, frames: row.integer(0), stableBytes: row.integer(1),
        commitCount: row.integer(2), integritySHA256: row.string(3))
    }
  }

  public func mediaCommit(callID: String, sequence: Int64) throws -> MediaMasterCommit? {
    let identity = try masterIdentity(callID)
    return try database.access(capture: true) {
      guard
        let row = try database.rows(
          "SELECT start_frame,frames,stable_bytes,integrity_hash,pcm_hash FROM media_commits WHERE call_id=? AND sequence=?",
          [.text(callID), .integer(sequence)]
        ).first
      else { return nil }
      let spans = try database.rows(
        "SELECT channel,start_ms,end_ms,state FROM media_intervals WHERE call_id=? AND sequence=? ORDER BY channel,ordinal LIMIT 2001",
        [.text(callID), .integer(sequence)])
      guard spans.count <= 2000 else { throw invalidRow() }
      var intervals: [[CaptureInterval]] = [[], []]
      for span in spans {
        let channel = try span.int(0)
        guard (0...1).contains(channel),
          let state = try CaptureIntervalState(rawValue: span.string(3))
        else { throw invalidRow() }
        intervals[channel].append(try .init(startMs: span.int(1), endMs: span.int(2), state: state))
      }
      return try .init(
        cursor: .init(
          identity: identity, frames: row.integer(1), stableBytes: row.integer(2),
          commitCount: sequence, integritySHA256: row.string(3)), startFrame: row.integer(0),
        pcmSHA256: row.string(4),
        microphoneIntervals: intervals[0], applicationIntervals: intervals[1])
    }
  }

  func masterIdentity(_ callID: String) throws -> MediaMasterIdentity {
    try requireCanonicalIdentifier(callID)
    return try database.access(capture: true) {
      guard
        let row = try database.rows(
          "SELECT master_id,microphone_track_id,application_track_id FROM sessions WHERE call_id=?",
          [.text(callID)]
        ).first,
        let call = UUID(uuidString: callID), let master = try UUID(uuidString: row.string(0)),
        let microphone = try UUID(uuidString: row.string(1)),
        let application = try UUID(uuidString: row.string(2))
      else { throw invalidRow() }
      return .init(
        masterID: master, callID: call, microphoneTrackID: microphone,
        applicationTrackID: application)
    }
  }

  func validateMediaCommit(_ commit: MediaMasterCommit, after prior: MediaMasterCursor) throws {
    let cursor = commit.cursor
    let frames = cursor.frames - commit.startFrame
    guard commit.startFrame == prior.frames, cursor.commitCount == prior.commitCount + 1,
      cursor.identity == prior.identity, (1...16000).contains(frames), frames % 16 == 0,
      cursor.frames <= MediaMasterProfile.maximumFrames,
      cursor.stableBytes == Int64(MediaMasterProfile.headerBytes) + cursor.frames * 4,
      commit.microphoneIntervals.count <= 1000, commit.applicationIntervals.count <= 1000
    else { throw LocalPersistenceError.invalidMediaProgress }
    let mic = try MediaMasterIndex.states(
      commit.microphoneIntervals, startMs: Int(prior.frames / 16), countMs: Int(frames / 16),
      microphone: true)
    let app = try MediaMasterIndex.states(
      commit.applicationIntervals, startMs: Int(prior.frames / 16), countMs: Int(frames / 16),
      microphone: false)
    var states = Data()
    for index in mic.indices {
      states.append(mic[index])
      states.append(app[index])
    }
    let record = try MediaMasterIndex.record(
      final: false, frames: cursor.frames, bytes: cursor.stableBytes,
      hash: digestBytes(commit.pcmSHA256), previous: digestBytes(prior.integritySHA256),
      states: states)
    guard record.suffix(32).masterHex == cursor.integritySHA256 else {
      throw LocalPersistenceError.invalidMediaProgress
    }
  }

  func initialCursor(_ identity: MediaMasterIdentity) -> MediaMasterCursor {
    .init(
      identity: identity, frames: 0, stableBytes: 68, commitCount: 0,
      integritySHA256: MediaMasterIndex.header(identity).suffix(32).masterHex)
  }

  /// Called inside the same finalization transaction as the canonical pointer and work.
  func commitFinalMaster(_ master: FinalizedMediaMaster, callID: String) throws {
    if master.cursor.commitCount == 0 {
      if let row = try database.rows(
        "SELECT sequence,finalized_hash FROM capture_progress WHERE call_id=?", [.text(callID)]
      ).first {
        guard try row.optionalInt(0) == nil, try row.optionalString(1) == master.sha256 else {
          throw LocalPersistenceError.invalidMediaProgress
        }
        return
      }
      try database.execute(
        "INSERT INTO capture_progress VALUES (?,NULL,?)", [.text(callID), .text(master.sha256)])
      return
    }
    let row = try database.rows(
      """
      SELECT m.frames,m.stable_bytes,m.sequence,m.integrity_hash,p.finalized_hash
      FROM capture_progress p JOIN media_commits m ON m.call_id=p.call_id AND m.sequence=p.sequence WHERE p.call_id=?
      """, [.text(callID)]
    ).first
    guard let row, try row.integer(0) == master.cursor.frames,
      try row.integer(1) == master.cursor.stableBytes,
      try row.integer(2) == master.cursor.commitCount,
      try row.string(3) == master.cursor.integritySHA256,
      try row.optionalString(4).map({ $0 == master.sha256 }) ?? true
    else { throw LocalPersistenceError.invalidMediaProgress }
    try database.execute(
      "UPDATE capture_progress SET finalized_hash=? WHERE call_id=?",
      [.text(master.sha256), .text(callID)])
  }

  public func finalizedMaster(callID: String) throws -> FinalizedMediaMaster? {
    guard let cursor = try confirmedMediaCursor(callID: callID) else { return nil }
    guard
      let hash = try database.access({
        try database.rows(
          "SELECT finalized_hash FROM capture_progress WHERE call_id=?", [.text(callID)]
        ).first?.optionalString(0)
      })
    else { return nil }
    return .init(cursor: cursor, sha256: hash)
  }
}

func digestBytes(_ value: String) throws -> Data {
  guard value.utf8.count == 64 else { throw LocalPersistenceError.invalidMediaProgress }
  let chars = Array(value.utf8)
  var result = Data()
  func digit(_ byte: UInt8) throws -> UInt8 {
    switch byte {
    case 48...57: byte - 48
    case 97...102: byte - 87
    default: throw LocalPersistenceError.invalidMediaProgress
    }
  }
  for index in stride(from: 0, to: 64, by: 2) {
    result.append(try digit(chars[index]) * 16 + digit(chars[index + 1]))
  }
  return result
}
