import Foundation
import TrigoContracts

extension LocalRepository {
  public func beginCapture(
    _ session: CaptureArchiveSession, associatedWork: OperationIntent? = nil,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) async throws -> PublicationResult {
    try requireArchiveIdentity(session.archiveID)
    guard try canonicalRepositoryRoot(session.root).path == root.path else {
      throw LocalPersistenceError.unsafeStore("Capture namespace differs")
    }
    let operation = try await associatedWork.mapAsync { try await prepareOperation($0) }
    if let operation, operation.intent.callID != session.callID { throw ContractError.reference }
    if let existing = try await captureSession(callID: session.callID) {
      guard existing == session else {
        throw LocalPersistenceError.immutableConflict(session.callID)
      }
      try database.access {
        try database.transaction {
          try validateSemanticWork("begin:\(session.callID)", operation: operation)
        }
      }
      return .alreadyPresent
    }
    let document = try Contract.decode(
      CallDocument.self,
      bytes: session.callBytes(media: nil, reason: nil, version: 1, reference: nil))
    try await stageCall(document)
    let result = try database.access(capture: true) {
      try database.transaction(interruption: { point in
        try self.interruption(point)
        try interruption(point)
      }) {
        let result = try commitCall(document.value, hash: document.sha256, expected: nil)
        if try !database.rows(
          "SELECT call_id FROM sessions WHERE call_id=?", [.text(session.callID)]
        ).isEmpty {
          throw LocalPersistenceError.concurrentMutation
        }
        try database.execute(
          "INSERT INTO sessions VALUES (?,?,?,?,?,?,?,0,NULL)",
          [
            .text(session.callID), .text(session.microphoneTrackID),
            .text(session.applicationTrackID),
            .text(session.audioManifestID), .text(session.masterID),
            .real(session.startedAt.timeIntervalSinceReferenceDate),
            .real(session.source.processLaunchDate.timeIntervalSinceReferenceDate),
          ])
        try commitSemanticWork("begin:\(session.callID)", operation: operation)
        return result
      }
    }
    return result
  }

  public func captureSession(callID: String) async throws -> CaptureArchiveSession? {
    try requireCanonicalIdentifier(callID)
    guard
      let row = try database.access({
        try database.rows(
          """
          SELECT s.microphone_track_id,s.application_track_id,s.audio_manifest_id,s.master_id,
          s.started_reference,s.process_launch_reference,c.hash FROM sessions s JOIN calls c ON c.call_id=s.call_id
          WHERE s.call_id=?
          """, [.text(callID)]
        ).first
      })
    else { return nil }
    let call = try callValue(hash: row.string(6))
    guard call.callId == callID,
      let microphoneTrack = call.tracks.first(where: { $0.role == "microphone" }),
      let applicationTrack = call.tracks.first(where: { $0.role == "application" }),
      try row.string(0) == microphoneTrack.trackId, try row.string(1) == applicationTrack.trackId,
      let processID = Int32(exactly: call.source.processId),
      let storedWindowID = call.source.windowId,
      let windowID = UInt32(exactly: storedWindowID)
    else { throw invalidRow() }
    let masterID = try row.string(3)
    let manifestID = try row.string(2)
    try requireCanonicalIdentifier(masterID)
    try requireCanonicalIdentifier(manifestID)
    return try .init(
      root: root, archiveID: archiveID, callID: callID,
      microphoneTrackID: microphoneTrack.trackId, applicationTrackID: applicationTrack.trackId,
      audioManifestID: manifestID, masterID: masterID,
      startedAt: Date(timeIntervalSinceReferenceDate: row.real(4)),
      source: .init(
        applicationName: call.source.applicationName, bundleID: call.source.bundleId,
        processID: processID, windowID: windowID, windowTitle: call.source.windowTitle,
        processLaunchDate: Date(timeIntervalSinceReferenceDate: row.real(5))),
      microphone: microphoneTrack.inputDevice.map { .init(id: $0.id, name: $0.name) })
  }

  /// Stop intent is an operational fact needed across the external media boundary. It is
  /// not another writable capture state. A known cause survives a subsequent process death.
  public func requestCaptureStop(callID: String, reason: String?) async throws {
    try requireCaptureInterruptionReason(reason)
    try database.access(capture: true) {
      try database.transaction(interruption: self.interruption) {
        guard
          let row = try database.rows(
            "SELECT stop_requested,stop_reason FROM sessions WHERE call_id=?", [.text(callID)]
          ).first
        else {
          throw LocalPersistenceError.callNotFound(callID)
        }
        if try row.int(0) == 1 { return }
        try database.execute(
          "UPDATE sessions SET stop_requested=1,stop_reason=? WHERE call_id=?",
          [.string(reason), .text(callID)])
      }
    }
  }

  public func captureStopRequest(callID: String) async throws -> CaptureStopRequest? {
    try database.access {
      guard
        let row = try database.rows(
          "SELECT stop_requested,stop_reason FROM sessions WHERE call_id=?", [.text(callID)]
        ).first,
        try row.int(0) == 1
      else { return nil }
      return try .init(reason: row.optionalString(1))
    }
  }

  public func finalizeCapture(
    _ session: CaptureArchiveSession, media: CapturedMedia, reason: String?,
    associatedWork: OperationIntent? = nil,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) async throws -> LocalCallAggregate {
    guard let retained = try await captureSession(callID: session.callID), retained == session
    else {
      throw LocalPersistenceError.immutableConflict(session.callID)
    }
    let prior = try await call(callID: session.callID)
    let audio = try session.audioBytes(media)
    let snapshot = try session.callBytes(
      media: media, reason: reason, version: prior.documentVersion + 1,
      reference: .init(manifestId: session.audioManifestID, sha256: Contract.hash(audio)))
    let sealed = try await retainLegacyCaptureSeal(
      callSnapshot: snapshot, audioManifest: audio, associatedWork: associatedWork)
    return try await finalizeCapture(
      callSnapshot: sealed.call, audioManifest: sealed.audio,
      associatedWork: sealed.operation, interruption: interruption)
  }

  /// The transitional WAV writer can allocate a new object ID every time it recovers an
  /// active PCM file. Retain its first sealed result before canonical publication so an
  /// uncertain publication reuses exactly those bytes. #53 removes this transitional
  /// receipt when the production writer uses the session's stable master identity.
  private func retainLegacyCaptureSeal(
    callSnapshot: Data, audioManifest: Data, associatedWork: OperationIntent?
  ) async throws -> LegacyCaptureSeal {
    let document = try Contract.decode(CallDocument.self, bytes: callSnapshot)
    let audio = try Contract.decode(AudioManifest.self, bytes: audioManifest)
    let callID = document.value.callId
    if let associatedWork, associatedWork.callID != callID { throw ContractError.reference }
    let preparedWork = try await associatedWork.mapAsync { try await prepareOperation($0) }
    if let retained = try legacyCaptureSeal(callID: callID) {
      guard retained.audio == audioManifest,
        !captureChanged(try callValue(hash: retained.callHash), document.value)
      else { throw LocalPersistenceError.immutableConflict(callID) }
      if let associatedWork, retained.operation != associatedWork {
        throw LocalPersistenceError.operationConflict(associatedWork.operationID)
      }
      return retained
    }
    try validateAudioManifest(audio.value, against: document.value)
    _ = try Contract.validateArchive(
      callSnapshot, references: [audio.value.manifestId: audioManifest])
    let priorHash = try currentHash(callID)
    guard let priorHash else { throw LocalPersistenceError.callNotFound(callID) }
    try validatePublication(from: callValue(hash: priorHash), to: document.value)
    try await stageDocument(audioManifest)
    try await stageCall(document)
    try database.access(capture: true) {
      try database.transaction {
        guard try currentHashLocked(callID) == priorHash else {
          throw LocalPersistenceError.concurrentMutation
        }
        try database.execute(
          "INSERT OR IGNORE INTO legacy_capture_seals VALUES (?,?,?,?,?,?)",
          [
            .text(callID), .text(document.sha256), .text(audio.sha256),
            .string(preparedWork?.intent.operationID), .string(preparedWork?.intent.kind.rawValue),
            .string(preparedWork?.payloadHash),
          ])
        guard
          let row = try database.rows(
            "SELECT call_hash,audio_hash,work_id,work_kind,work_payload_hash FROM legacy_capture_seals WHERE call_id=?",
            [.text(callID)]
          ).first,
          try row.string(0) == document.sha256, try row.string(1) == audio.sha256,
          try row.optionalString(2) == preparedWork?.intent.operationID,
          try row.optionalString(3) == preparedWork?.intent.kind.rawValue,
          try row.optionalString(4) == preparedWork?.payloadHash
        else { throw LocalPersistenceError.immutableConflict(callID) }
      }
    }
    return .init(
      callHash: document.sha256, call: callSnapshot, audio: audioManifest, operation: associatedWork
    )
  }

  func resumeLegacyCaptureSeal(callID: String) async throws -> LocalCallAggregate? {
    guard let retained = try legacyCaptureSeal(callID: callID) else { return nil }
    return try await finalizeCapture(
      callSnapshot: retained.call, audioManifest: retained.audio, associatedWork: retained.operation
    )
  }

  private func legacyCaptureSeal(callID: String) throws -> LegacyCaptureSeal? {
    guard
      let row = try database.access({
        try database.rows(
          "SELECT call_hash,audio_hash,work_id,work_kind,work_payload_hash FROM legacy_capture_seals WHERE call_id=?",
          [.text(callID)]
        ).first
      })
    else { return nil }
    let operation: OperationIntent?
    if let id = try row.optionalString(2) {
      guard let kind = try OperationKind(rawValue: row.string(3)) else { throw invalidRow() }
      operation = try .init(
        operationID: id, archiveID: archiveID, callID: callID, kind: kind,
        payload: documentBytes(row.string(4)))
    } else {
      operation = nil
    }
    return try .init(
      callHash: row.string(0), call: documentBytes(row.string(0)),
      audio: documentBytes(row.string(1)), operation: operation)
  }

  /// Atomic canonical snapshot, immutable audio reference, master witness, lifecycle and
  /// caller-associated work. #53 supplies its selected-profile exchange snapshots here.
  /// The selected #51 certificate is optional only for the temporary legacy writer path.
  public func finalizeCapture(
    callSnapshot: Data, audioManifest: Data, verifiedMaster: FinalizedMediaMaster? = nil,
    associatedWork: OperationIntent? = nil,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) async throws -> LocalCallAggregate {
    let document = try Contract.decode(CallDocument.self, bytes: callSnapshot)
    let audio = try Contract.decode(AudioManifest.self, bytes: audioManifest)
    let callID = document.value.callId
    try requireArchiveIdentity(document.value.archiveId)
    guard let session = try await captureSession(callID: callID),
      let priorHash = try currentHash(callID)
    else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    let prior = try callValue(hash: priorHash)
    guard audio.value.manifestId == session.audioManifestID,
      document.value.audioManifest
        == .init(manifestId: session.audioManifestID, sha256: audio.sha256)
    else { throw ContractError.reference }
    try validateAudioManifest(audio.value, against: document.value)
    _ = try Contract.validateArchive(
      callSnapshot, references: [session.audioManifestID: audioManifest])
    if let master = verifiedMaster {
      guard master.cursor.identity == session.mediaMasterIdentity,
        document.value.durationMs == Int(master.cursor.frames / 16), master.cursor.frames % 16 == 0
      else { throw LocalPersistenceError.invalidMediaProgress }
      _ = try digestBytes(master.sha256)
      if master.cursor.frames > 0 {
        guard audio.value.mediaProfileId == master.profileID, audio.value.objects.count == 1,
          let object = audio.value.objects.first, object.objectId == session.masterID,
          object.byteLength == master.cursor.stableBytes, object.sha256 == master.sha256
        else { throw ContractError.reference }
      } else {
        guard master.cursor == initialCursor(session.mediaMasterIdentity),
          audio.value.objects.isEmpty
        else { throw LocalPersistenceError.invalidMediaProgress }
      }
    } else if try confirmedMediaCursor(callID: callID) != nil {
      throw LocalPersistenceError.invalidMediaProgress
    }
    let operation = try await associatedWork.mapAsync { try await prepareOperation($0) }
    if let operation, operation.intent.callID != callID { throw ContractError.reference }
    if let reference = prior.audioManifest {
      guard reference == document.value.audioManifest, !captureChanged(prior, document.value),
        try documentBytes(reference.sha256) == audioManifest
      else { throw LocalPersistenceError.immutableConflict(session.audioManifestID) }
      try database.access {
        try database.transaction {
          try validateSemanticWork("finalize:\(callID)", operation: operation)
          if let verifiedMaster { try commitFinalMaster(verifiedMaster, callID: callID) }
        }
      }
      return try await loadCall(callID: callID)
    }
    try validatePublication(from: prior, to: document.value)
    try await stageDocument(audioManifest)
    try await stageEvidence(
      hash: audio.sha256, kind: "audio", callID: callID, identity: audio.value.manifestId)
    try await stageCall(document)
    try database.access(capture: true) {
      try database.transaction(interruption: { point in
        try self.interruption(point)
        try interruption(point)
      }) {
        _ = try commitEvidence(
          identity: session.audioManifestID, kind: "audio", callID: callID, hash: audio.sha256)
        _ = try commitCall(document.value, hash: document.sha256, expected: priorHash)
        if let verifiedMaster { try commitFinalMaster(verifiedMaster, callID: callID) }
        try commitSemanticWork("finalize:\(callID)", operation: operation)
      }
    }
    return try await loadCall(callID: callID)
  }

  func hasSession(_ callID: String) throws -> Bool {
    try database.access {
      try !database.rows("SELECT call_id FROM sessions WHERE call_id=?", [.text(callID)]).isEmpty
    }
  }
}

public struct CaptureStopRequest: Sendable, Equatable { public let reason: String? }

extension Optional {
  func mapAsync<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
    guard let value = self else { return nil }
    return try await transform(value)
  }
}

private struct LegacyCaptureSeal {
  let callHash: String
  let call: Data
  let audio: Data
  let operation: OperationIntent?
}
