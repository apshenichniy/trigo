import Foundation
import TrigoContracts

extension LocalRepository {
  /// Persist all operation identities before any server admission. Capture uses its own scheduler.
  public func ensureMasterUpload(_ session: CaptureArchiveSession) async throws -> MasterUploadState
  {
    if let current = try masterUpload(callID: session.callID) { return current }
    guard try await captureSession(callID: session.callID) == session else {
      throw LocalPersistenceError.immutableConflict(session.callID)
    }
    let uploadID = UUID().uuidString.lowercased()
    let operationID = UUID().uuidString.lowercased()
    let finalizeID = UUID().uuidString.lowercased()
    let initial = try await snapshotBytes(callID: session.callID, version: 1)
    guard let text = String(data: initial, encoding: .utf8) else { throw ContractError.structure }
    let request = RegisterMasterUpload(
      schemaVersion: 1,
      uploadId: uploadID,
      masterId: session.masterID,
      callDocument: text
    )
    let operation = try await prepareOperation(
      .init(
        operationID: operationID,
        archiveID: archiveID,
        callID: session.callID,
        kind: .upload,
        payload: Contract.encode(request)
      )
    )
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveMasterUpload(session.callID)
        if try database.rows(
          "SELECT call_id FROM master_uploads WHERE call_id=?",
          [.text(session.callID)]
        )
        .isEmpty {
          try commitOperation(operation)
          try database.execute(
            "INSERT INTO master_uploads(call_id,upload_id,operation_id,finalize_operation_id) VALUES (?,?,?,?)",
            [.text(session.callID), .text(uploadID), .text(operationID), .text(finalizeID)]
          )
        }
      }
    }
    return try requiredMasterUpload(session.callID)
  }

  public func masterUpload(callID: String) throws -> MasterUploadState? {
    try requireCanonicalIdentifier(callID)
    guard
      let row = try database.access({
        try database.rows(
          "SELECT upload_id,operation_id,finalize_operation_id,registration_receipt_hash,cleanup_complete FROM master_uploads WHERE call_id=?",
          [.text(callID)]
        )
        .first
      })
    else { return nil }
    let state = try MasterUploadState(
      callID: callID,
      uploadID: row.string(0),
      operationID: row.string(1),
      finalizeOperationID: row.string(2),
      registered: row.optionalString(3) != nil,
      cleanupComplete: row.int(4) == 1
    )
    for id in [state.uploadID, state.operationID, state.finalizeOperationID] {
      try requireCanonicalIdentifier(id)
    }
    if let hash = try row.optionalString(3) {
      let receipt = try Contract.decode(MasterUploadSession.self, bytes: documentBytes(hash))
      try validateMasterSession(receipt.value, state: state)
    }
    return state
  }

  public func masterUploadRegistration(callID: String) async throws -> RegisterMasterUpload {
    let state = try requiredMasterUpload(callID)
    guard let operation = try await operation(state.operationID) else {
      throw LocalPersistenceError.operationNotFound(state.operationID)
    }
    let request = try Contract.decode(RegisterMasterUpload.self, bytes: operation.payload).value
    guard request.uploadId == state.uploadID,
      try request.masterId == masterIdentity(callID).masterID.uuidString.lowercased()
    else {
      throw LocalPersistenceError.operationConflict(state.operationID)
    }
    return request
  }

  public func acceptMasterUploadSession(
    _ receipt: StoredDocument<MasterUploadSession>,
    callID: String
  ) async throws {
    let decoded = try Contract.decode(MasterUploadSession.self, bytes: receipt.storedBytes)
    guard decoded.value == receipt.value else { throw MasterUploadError.invalidReceipt }
    let state = try requiredMasterUpload(callID)
    try validateMasterSession(decoded.value, state: state)
    let hash = try await stageDocument(decoded.storedBytes)
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveMasterUpload(callID)
        try database.execute(
          "UPDATE master_uploads SET registration_receipt_hash=? WHERE call_id=? AND registration_receipt_hash IS NULL",
          [.text(hash), .text(callID)]
        )
      }
    }
  }

  /// Content identity is durable before its HTTP request, independently of a part receipt.
  public func prepareMasterUploadPart(callID: String, descriptor: UploadPartDescriptor) throws {
    _ = try Contract.encode(descriptor)
    guard let cursor = try confirmedMediaCursor(callID: callID),
      descriptor.byteOffset == descriptor.index * MediaMasterProfile.maximumRequestBytes,
      descriptor.byteOffset + descriptor.byteLength <= cursor.stableBytes,
      try descriptor.byteLength == MediaMasterProfile.maximumRequestBytes
        || finalizedMaster(callID: callID) != nil
    else { throw MasterUploadError.invalidPart }
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveMasterUpload(callID)
        if let existing =
          try database.rows(
            "SELECT byte_length,sha256 FROM master_upload_parts WHERE call_id=? AND part_index=?",
            [.text(callID), .int(descriptor.index)]
          )
          .first
        {
          guard try existing.int(0) == descriptor.byteLength,
            try existing.string(1) == descriptor.sha256
          else {
            throw LocalPersistenceError.immutableConflict("upload:\(callID):\(descriptor.index)")
          }
        } else {
          try database.execute(
            "INSERT INTO master_upload_parts(call_id,part_index,byte_length,sha256) VALUES (?,?,?,?)",
            [
              .text(callID), .int(descriptor.index), .int(descriptor.byteLength),
              .text(descriptor.sha256),
            ]
          )
        }
      }
    }
  }

  public func masterUploadParts(callID: String) throws -> [MasterUploadPart] {
    let state = try requiredMasterUpload(callID)
    let rows = try database.access {
      try database.rows(
        "SELECT part_index,byte_length,sha256,receipt_hash FROM master_upload_parts WHERE call_id=? ORDER BY part_index LIMIT 84",
        [.text(callID)]
      )
    }
    guard rows.count <= 83 else { throw MasterUploadError.invalidPart }
    return try rows.map { row in
      let descriptor = try UploadPartDescriptor(
        index: row.int(0),
        byteOffset: row.int(0) * MediaMasterProfile.maximumRequestBytes,
        byteLength: row.int(1),
        sha256: row.string(2)
      )
      _ = try Contract.encode(descriptor)
      let receipt = try row.optionalString(3)
        .map { hash in
          try Contract.decode(UploadPartReceipt.self, bytes: documentBytes(hash))
        }
      if let receipt {
        try validatePartReceipt(receipt.value, state: state, descriptor: descriptor)
      }
      return .init(descriptor: descriptor, receipt: receipt)
    }
  }

  public func acceptMasterUploadPart(
    _ receipt: StoredDocument<UploadPartReceipt>,
    callID: String
  ) async throws {
    let decoded = try Contract.decode(UploadPartReceipt.self, bytes: receipt.storedBytes)
    guard decoded.value == receipt.value,
      let part = try masterUploadParts(callID: callID)
        .first(where: { $0.descriptor.index == receipt.value.index })
    else { throw MasterUploadError.invalidReceipt }
    try validatePartReceipt(
      decoded.value,
      state: requiredMasterUpload(callID),
      descriptor: part.descriptor
    )
    if let prior = part.receipt {
      guard prior.value == decoded.value else { throw MasterUploadError.invalidReceipt }
      return
    }
    let hash = try await stageDocument(decoded.storedBytes)
    try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveMasterUpload(callID)
        try database.execute(
          "UPDATE master_upload_parts SET receipt_hash=? WHERE call_id=? AND part_index=? AND receipt_hash IS NULL",
          [.text(hash), .text(callID), .int(decoded.value.index)]
        )
      }
    }
  }

  func requiredMasterUpload(_ callID: String) throws -> MasterUploadState {
    guard let state = try masterUpload(callID: callID) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    return state
  }

  /// Called only within a scheduled SQL unit, including the publication transaction.
  func requireActiveMasterUpload(_ callID: String) throws {
    guard
      let row = try database.rows("SELECT deletion FROM lifecycle WHERE call_id=?", [.text(callID)])
        .first,
      try row.string(0) == "active"
    else { throw MasterUploadError.fenced }
  }

  private func validateMasterSession(
    _ receipt: MasterUploadSession,
    state: MasterUploadState
  ) throws {
    let identity = try masterIdentity(state.callID)
    guard receipt.archiveId == archiveID, receipt.callId == state.callID,
      receipt.uploadId == state.uploadID,
      receipt.masterId == identity.masterID.uuidString.lowercased(),
      receipt.partBytes == MediaMasterProfile.maximumRequestBytes,
      receipt.mediaProfileId == MediaMasterProfile.id
    else { throw MasterUploadError.invalidReceipt }
  }

  private func validatePartReceipt(
    _ receipt: UploadPartReceipt,
    state: MasterUploadState,
    descriptor: UploadPartDescriptor
  ) throws {
    let identity = try masterIdentity(state.callID)
    guard receipt.archiveId == archiveID, receipt.callId == state.callID,
      receipt.uploadId == state.uploadID,
      receipt.masterId == identity.masterID.uuidString.lowercased(),
      receipt.index == descriptor.index, receipt.byteOffset == descriptor.byteOffset,
      receipt.byteLength == descriptor.byteLength, receipt.sha256 == descriptor.sha256
    else { throw MasterUploadError.invalidReceipt }
  }
}
