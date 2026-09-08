import Foundation
import TrigoContracts

extension LocalRepository {
  /// The finalized capture snapshot is immutable even after later local annotations/imports.
  /// Replaying this operation therefore uses the exact original metadata and audio evidence.
  public func prepareMasterFinalization(callID: String) async throws -> FinalizeMasterUpload {
    let state = try requiredMasterUpload(callID)
    if let existing = try await operation(state.finalizeOperationID) {
      return try Contract.decode(FinalizeMasterUpload.self, bytes: existing.payload).value
    }
    guard let completion = try captureCompletion(callID: callID), let master = completion.master
    else {
      throw LocalPersistenceError.invalidMediaProgress
    }
    let call = try callValue(
      hash: masterUploadSnapshotHash(callID: callID),
      includeIntervals: false
    )
    guard let reference = call.audioManifest,
      let audioSize = try database.access({
        try database
          .rows(
            "SELECT byte_count FROM documents WHERE hash=? AND complete=1",
            [.text(reference.sha256)]
          )
          .first?
          .int(0)
      }), audioSize <= 16_384,
      let audioText = try String(data: documentBytes(reference.sha256), encoding: .utf8)
    else { throw MasterUploadError.invalidReceipt }
    let sourceStates = try await masterUploadSourceStates(callID: callID, master: master)
    let sourceHash = Contract.hash(sourceStates)
    let input = FinalizeMasterUpload(
      schemaVersion: 1,
      operationId: state.finalizeOperationID,
      uploadId: state.uploadID,
      captureState: call.captureState,
      durationMs: master.durationMs,
      sourceStates: .init(
        encoding: "source-states-2bit-ms-v1",
        data: sourceStates.base64EncodedString()
      ),
      audioManifest: audioText,
      masterSHA256: master.sha256
    )
    let prepared = try await prepareOperation(
      .init(
        operationID: state.finalizeOperationID,
        archiveID: archiveID,
        callID: callID,
        kind: .upload,
        payload: Contract.encode(input)
      )
    )
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveMasterUpload(callID)
        try commitOperation(prepared)
        try database.execute(
          "UPDATE master_uploads SET source_states_hash=? WHERE call_id=?",
          [.text(sourceHash), .text(callID)]
        )
      }
    }
    try interruption(.afterJournalIntentPersisted)
    return input
  }

  public func verifiedMasterReceipt(callID: String) throws -> StoredDocument<VerifiedMasterReceipt>?
  {
    try requireCanonicalIdentifier(callID)
    guard
      let hash = try database.access({
        try database
          .rows("SELECT hash FROM server_storage_receipts WHERE call_id=?", [.text(callID)])
          .first?
          .optionalString(0)
      })
    else { return nil }
    let receipt = try Contract.decode(VerifiedMasterReceipt.self, bytes: documentBytes(hash))
    if let state = try masterUpload(callID: callID) {
      try validateVerifiedMaster(receipt.value, state: state)
    } else {
      guard let current = try currentHash(callID) else { throw CanonicalSyncError.invalidReceipt }
      try validateRestoredMasterReceipt(receipt.value, call: callValue(hash: current))
    }
    return receipt
  }

  /// This receipt, the stored upload axis, and both journal acknowledgements commit together.
  public func acceptVerifiedMasterReceipt(
    _ receipt: StoredDocument<VerifiedMasterReceipt>,
    callID: String,
    interruption: MasterUploadInterruption = { _ in }
  ) async throws {
    let decoded = try Contract.decode(VerifiedMasterReceipt.self, bytes: receipt.storedBytes)
    guard decoded.value == receipt.value else { throw MasterUploadError.invalidReceipt }
    let state = try requiredMasterUpload(callID)
    try validateVerifiedMaster(decoded.value, state: state)
    if let prior = try verifiedMasterReceipt(callID: callID) {
      guard prior.value == decoded.value else { throw MasterUploadError.invalidReceipt }
      return
    }
    let parts = try masterUploadParts(callID: callID)
    guard
      parts.count == (decoded.value.byteLength + MediaMasterProfile.maximumRequestBytes - 1)
        / MediaMasterProfile.maximumRequestBytes,
      parts.enumerated()
        .allSatisfy({ index, part in
          part.receipt != nil && part.descriptor.index == index
            && part.descriptor.byteLength
              == min(
                MediaMasterProfile.maximumRequestBytes,
                decoded.value.byteLength - index * MediaMasterProfile.maximumRequestBytes
              )
        }),
      try await operation(state.finalizeOperationID) != nil
    else { throw MasterUploadError.invalidReceipt }
    let hash = try await stageDocument(decoded.storedBytes)
    try database.access {
      try database.transaction(interruption: self.interruption) {
        try requireActiveMasterUpload(callID)
        try interruption(.beforeReceiptCommit)
        try database.execute(
          "UPDATE master_uploads SET storage_receipt_hash=? WHERE call_id=? AND storage_receipt_hash IS NULL",
          [.text(hash), .text(callID)]
        )
        try database.execute(
          "INSERT INTO server_storage_receipts VALUES (?,?) ON CONFLICT(call_id) DO NOTHING",
          [.text(callID), .text(hash)]
        )
        try database.execute(
          "UPDATE lifecycle SET upload='stored',upload_failure=NULL,upload_retry=NULL,state_version=state_version+1 WHERE call_id=?",
          [.text(callID)]
        )
        try database.execute(
          "UPDATE operations SET acknowledged=1 WHERE operation_id IN (?,?)",
          [.text(state.operationID), .text(state.finalizeOperationID)]
        )
      }
    }
    try interruption(.afterReceiptCommit)
  }

  /// Crash-safe, idempotent removal of this session's two temporary master files only.
  /// A persisted part receipt, ETag or upload lifecycle value cannot enter this method.
  public func cleanupVerifiedMaster(
    callID: String,
    interruption: MasterUploadInterruption = { _ in }
  ) async throws {
    guard try verifiedMasterReceipt(callID: callID) != nil,
      let session = try await captureSession(callID: callID)
    else { throw MasterUploadError.invalidReceipt }
    let state = try requiredMasterUpload(callID)
    if state.cleanupComplete { return }
    try database.access { try requireActiveMasterUpload(callID) }
    try interruption(.beforeMediaCleanup)
    try requireSafePath(session.mediaDirectory.deletingLastPathComponent(), directory: true)
    try requireSafePath(session.mediaDirectory, directory: true, mayBeAbsent: true)
    let files = FileManager.default
    if files.fileExists(atPath: session.mediaDirectory.path) {
      for name in ["master.caf", "master.index"] {
        let file = session.mediaDirectory.appendingPathComponent(name)
        try requireSafePath(file, directory: false, mayBeAbsent: true)
        if files.fileExists(atPath: file.path) { try files.removeItem(at: file) }
        if name == "master.caf" { try interruption(.afterMasterRemoval) }
      }
      try MediaMasterIO.syncDirectory(session.mediaDirectory)
    }
    try interruption(.afterMediaCleanup)
    try database.access {
      try database.transaction(interruption: self.interruption) {
        try database.execute(
          "UPDATE master_uploads SET cleanup_complete=1 WHERE call_id=? AND storage_receipt_hash IS NOT NULL",
          [.text(callID)]
        )
      }
    }
  }

  private func validateVerifiedMaster(
    _ receipt: VerifiedMasterReceipt,
    state: MasterUploadState
  ) throws {
    let snapshotHash = try masterUploadSnapshotHash(callID: state.callID)
    guard let completion = try captureCompletion(callID: state.callID),
      let master = completion.master,
      let row = try database.access({
        try database.rows(
          "SELECT c.audio_id,c.audio_hash,u.source_states_hash FROM call_values c JOIN master_uploads u ON u.call_id=c.call_id WHERE c.hash=?",
          [.text(snapshotHash)]
        )
        .first
      })
    else { throw MasterUploadError.invalidReceipt }
    let identity = master.cursor.identity
    guard receipt.archiveId == archiveID, receipt.callId == state.callID,
      receipt.uploadId == state.uploadID, receipt.operationId == state.finalizeOperationID,
      receipt.masterId == identity.masterID.uuidString.lowercased(),
      receipt.masterSHA256 == master.sha256, receipt.byteLength == master.cursor.stableBytes,
      receipt.durationMs == master.durationMs, receipt.mediaProfileId == MediaMasterProfile.id,
      receipt.verification == "complete-master-sha256-v1",
      try receipt.audioManifest.manifestId == row.string(0),
      try receipt.audioManifest.sha256 == row.string(1),
      try receipt.sourceStatesSHA256 == row.string(2),
      receipt.channelMap == [
        .init(channelIndex: 0, trackId: identity.microphoneTrackID.uuidString.lowercased()),
        .init(channelIndex: 1, trackId: identity.applicationTrackID.uuidString.lowercased()),
      ]
    else { throw MasterUploadError.invalidReceipt }
  }
}
