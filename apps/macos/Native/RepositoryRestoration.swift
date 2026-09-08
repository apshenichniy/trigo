import Foundation
import TrigoContracts

public struct ServerReplicaContents: Sendable {
  public let document: Data
  public let audioManifest: Data
  public let revisions: [String: Data]
  public let provenance: [String: Data]
  public let receipt: StoredDocument<VerifiedMasterReceipt>
  public let results: [CatalogTranscriptResult]

  public init(
    document: Data,
    audioManifest: Data,
    revisions: [String: Data],
    provenance: [String: Data],
    receipt: StoredDocument<VerifiedMasterReceipt>,
    results: [CatalogTranscriptResult] = []
  ) {
    self.document = document
    self.audioManifest = audioManifest
    self.revisions = revisions
    self.provenance = provenance
    self.receipt = receipt
    self.results = results
  }
}

struct PreparedServerReplica: Sendable {
  let snapshot: StoredDocument<CallDocument>
  let audio: StoredDocument<AudioManifest>
  let revisions: [StoredDocument<TranscriptRevision>]
  let provenanceHashes: [String: String]
  let receiptHash: String
  let results: [PreparedServerResult]
}

extension LocalRepository {
  /// Restore exact confirmed documents and evidence into a fresh local archive. The verified
  /// storage receipt keeps audio remote; no fabricated capture session or empty master is made.
  @discardableResult
  public func restoreReplica(_ contents: ServerReplicaContents) async throws -> PublicationResult {
    let prepared = try await prepareServerReplica(contents)
    let snapshot = prepared.snapshot
    let callID = snapshot.value.callId
    let priorHash = try currentHash(callID)
    guard priorHash == nil || priorHash == snapshot.sha256 else {
      throw CanonicalSyncError.conflict
    }
    let legacy =
      try Contract.validateCallSnapshot(snapshot.storedBytes).kind == "LegacyCallDocument"
    let upgrade = legacy ? try await prepareLegacyUpgrade(snapshot) : nil
    return try database.access {
      try database.transaction(interruption: interruption) {
        try requireActiveCallLocked(callID)
        let result = try commitCall(snapshot.value, hash: snapshot.sha256, expected: priorHash)
        try commitServerEvidence(prepared)
        try observeReplicaLocked(
          callID: callID,
          version: snapshot.value.documentVersion,
          hash: snapshot.sha256
        )
        try database.execute(
          "UPDATE lifecycle SET upload='stored',upload_failure=NULL,upload_retry=NULL,import_state=?,replica='confirmed',replica_failure=NULL,replica_retry=NULL,state_version=state_version+1 WHERE call_id=?",
          [
            .text(snapshot.value.activeRevisionId == nil ? "not_available" : "imported"),
            .text(callID),
          ]
        )
        if let upgrade {
          _ = try commitCall(
            upgrade.snapshot.value,
            hash: upgrade.snapshot.sha256,
            expected: snapshot.sha256
          )
          if let operation = upgrade.operation {
            try commitReplicaWork(operation, snapshot: upgrade.snapshot, annotationRevisionIDs: [])
          }
        }
        return result
      }
    }
  }

  func prepareServerReplica(_ contents: ServerReplicaContents) async throws -> PreparedServerReplica
  {
    let snapshot = try Contract.decodeCallSnapshot(contents.document)
    try requireArchiveIdentity(snapshot.value.archiveId)
    let audio = try Contract.decode(AudioManifest.self, bytes: contents.audioManifest)
    let receipt = try Contract.decode(
      VerifiedMasterReceipt.self,
      bytes: contents.receipt.storedBytes
    )
    guard receipt.value == contents.receipt.value else { throw CanonicalSyncError.invalidReceipt }
    var references = contents.revisions
    references[audio.value.manifestId] = contents.audioManifest
    _ = try Contract.validateArchive(contents.document, references: references)
    try validateRestoredMasterReceipt(receipt.value, call: snapshot.value, audio: audio.value)
    try await stageCall(snapshot)
    _ = try await stageDocument(audio.storedBytes)
    try await stageEvidence(
      hash: audio.sha256,
      kind: "audio",
      callID: audio.value.callId,
      identity: audio.value.manifestId
    )
    var revisions: [StoredDocument<TranscriptRevision>] = []
    var provenanceHashes: [String: String] = [:]
    var results: [PreparedServerResult] = []
    guard Set(contents.results.map { $0.result.revisionId }).count == contents.results.count,
      contents.results.allSatisfy({ result in
        snapshot.value.revisions.contains { $0.revisionId == result.result.revisionId }
      })
    else { throw CanonicalSyncError.invalidResult }
    for reference in snapshot.value.revisions {
      guard let bytes = contents.revisions[reference.revisionId] else {
        throw ContractError.reference
      }
      let revision = try Contract.decode(TranscriptRevision.self, bytes: bytes)
      try await stageRevision(revision)
      revisions.append(revision)
      if let bytes = contents.provenance[reference.revisionId] {
        provenanceHashes[reference.revisionId] = try await stageDocument(bytes)
      }
      if let result = contents.results.first(where: { $0.result.revisionId == reference.revisionId }
      ) {
        guard let provenance = contents.provenance[reference.revisionId] else {
          throw CanonicalSyncError.invalidResult
        }
        try validateServerResult(result, revision: revision, provenance: provenance)
        results.append(
          .init(
            result: result,
            operation: try await prepareOperation(
              serverResultImportIntent(result, callID: snapshot.value.callId)
            )
          )
        )
      }
    }
    let existingReceiptHash = try database.access {
      try database
        .rows(
          "SELECT hash FROM server_storage_receipts WHERE call_id=?",
          [.text(snapshot.value.callId)]
        )
        .first?
        .string(0)
    }
    let receiptHash: String
    if let existingReceiptHash {
      guard
        try Contract.decode(VerifiedMasterReceipt.self, bytes: documentBytes(existingReceiptHash))
          .value == receipt.value
      else { throw CanonicalSyncError.invalidReceipt }
      receiptHash = existingReceiptHash
    } else {
      receiptHash = try await stageDocument(receipt.storedBytes)
    }
    return .init(
      snapshot: snapshot,
      audio: audio,
      revisions: revisions,
      provenanceHashes: provenanceHashes,
      receiptHash: receiptHash,
      results: results
    )
  }

  func commitServerEvidence(_ prepared: PreparedServerReplica) throws {
    let callID = prepared.snapshot.value.callId
    _ = try commitEvidence(
      identity: prepared.audio.value.manifestId,
      kind: "audio",
      callID: callID,
      hash: prepared.audio.sha256
    )
    for revision in prepared.revisions {
      _ = try commitEvidence(
        identity: revision.value.revisionId,
        kind: "revision",
        callID: callID,
        hash: revision.sha256
      )
      if let hash = prepared.provenanceHashes[revision.value.revisionId] {
        try commitTranscriptProvenanceLocked(revisionID: revision.value.revisionId, hash: hash)
      }
    }
    for result in prepared.results {
      try commitServerResultLocked(result.result, callID: callID, operation: result.operation)
    }
    if let row =
      try database.rows("SELECT hash FROM server_storage_receipts WHERE call_id=?", [.text(callID)])
      .first,
      try row.string(0) != prepared.receiptHash
    {
      throw CanonicalSyncError.invalidReceipt
    }
    try database.execute(
      "INSERT OR IGNORE INTO server_storage_receipts VALUES (?,?)",
      [.text(callID), .text(prepared.receiptHash)]
    )
  }

  func validateRestoredMasterReceipt(
    _ receipt: VerifiedMasterReceipt,
    call: CallDocument,
    audio suppliedAudio: AudioManifest? = nil
  ) throws {
    guard receipt.archiveId == archiveID, receipt.callId == call.callId,
      receipt.audioManifest == call.audioManifest, receipt.durationMs == call.durationMs,
      receipt.mediaProfileId == MediaMasterProfile.id,
      receipt.verification == "complete-master-sha256-v1",
      call.captureState != "recording", let duration = call.durationMs,
      let reference = call.audioManifest
    else { throw CanonicalSyncError.invalidReceipt }
    let audio =
      try suppliedAudio
      ?? Contract.decode(AudioManifest.self, bytes: documentBytes(reference.sha256)).value
    guard audio.callId == call.callId, audio.durationMs == duration,
      audio.manifestId == reference.manifestId,
      receipt.channelMap == [
        .init(
          channelIndex: 0,
          trackId: call.tracks.first(where: { $0.role == "microphone" })?.trackId ?? ""
        ),
        .init(
          channelIndex: 1,
          trackId: call.tracks.first(where: { $0.role == "application" })?.trackId ?? ""
        ),
      ]
    else { throw CanonicalSyncError.invalidReceipt }
    if duration == 0 {
      guard audio.objects.isEmpty, receipt.byteLength == MediaMasterProfile.headerBytes,
        receipt.masterSHA256 == Contract.hash(MediaMasterProfile.header)
      else { throw CanonicalSyncError.invalidReceipt }
    } else {
      guard audio.objects.count == 1, let object = audio.objects.first,
        object.objectId == receipt.masterId, object.sha256 == receipt.masterSHA256,
        object.byteLength == receipt.byteLength,
        object.channelMap.map(\.trackId) == receipt.channelMap.map(\.trackId)
      else { throw CanonicalSyncError.invalidReceipt }
    }
    var states = try MasterUploadSourceStates(durationMs: duration)
    for (channel, role) in ["microphone", "application"].enumerated() {
      guard let track = call.tracks.first(where: { $0.role == role }) else {
        throw CanonicalSyncError.invalidReceipt
      }
      for interval in track.intervals { try states.append(interval, channel: channel) }
    }
    guard try Contract.hash(states.finish()) == receipt.sourceStatesSHA256 else {
      throw CanonicalSyncError.invalidReceipt
    }
  }
}
