import Foundation
import TrigoContracts

@testable import TrigoNative

struct DailyUseEvent: Codable, Sendable {
  let event: String
  var at = dailyUseTimestamp()
  var uptime = ProcessInfo.processInfo.systemUptime
  var operationID: String?
  var attemptCount: Int?
  var state: String?
  var documentVersion: Int?
  var byteLength: Int?
  var sha256: String?
  var freshLatencyMeasurement: Bool?
  var warmStatusRoundTripMs: Double?
  var preFinishUploadMbps: Double?
  var finishToStoredMs: Double?
}

actor DailyUseJournal {
  let file: URL
  init(file: URL) throws {
    self.file = file
    try writeDailyUseBytes(Data(), to: file)
  }
  func record(_ event: DailyUseEvent) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var bytes = try encoder.encode(event)
    bytes.append(10)
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: bytes)
    try handle.synchronize()
  }
}

/// Only the fixed synthetic call may cause mutations. All data and network responses
/// still come from the real shared HTTP transports; no result or timing is fabricated.
struct DailyUseAdmittedUpload: MasterUploadTransport {
  let underlying: HTTPMasterUploadTransport
  let plan: DailyUsePlan
  let journal: DailyUseJournal

  func register(_ request: RegisterMasterUpload) async throws -> StoredDocument<MasterUploadSession>
  {
    try requireDailyUse(
      Contract.hash(try Contract.encode(request)) == plan.registrationSHA256,
      "An upload registration outside the prepared call was rejected."
    )
    return try await underlying.register(request)
  }

  func upload(
    callID: String,
    uploadID: String,
    part: UploadPartDescriptor,
    bytes: Data
  ) async throws -> StoredDocument<UploadPartReceipt> {
    try requireDailyUse(
      callID == plan.callID && uploadID == plan.uploadID,
      "An upload outside the prepared call was rejected."
    )
    return try await underlying.upload(
      callID: callID,
      uploadID: uploadID,
      part: part,
      bytes: bytes
    )
  }

  func finalize(
    callID: String,
    request: FinalizeMasterUpload
  ) async throws -> StoredDocument<VerifiedMasterReceipt> {
    let sourceStates = Data(base64Encoded: request.sourceStates.data)
    try requireDailyUse(
      callID == plan.callID && request.uploadId == plan.uploadID
        && request.operationId == plan.finalizeOperationID
        && request.durationMs == plan.durationMs && request.masterSHA256 == plan.masterSHA256
        && sourceStates.map(Contract.hash) == plan.sourceStatesSHA256,
      "A finalization outside the prepared call was rejected."
    )
    try await journal.record(.init(event: "finalization_requested"))
    let receipt = try await underlying.finalize(callID: callID, request: request)
    try await journal.record(
      .init(
        event: "verified_storage_returned",
        byteLength: receipt.value.byteLength,
        sha256: receipt.value.masterSHA256
      )
    )
    return receipt
  }
}

struct DailyUseAdmittedSync: CanonicalSyncTransport {
  let underlying: HTTPCanonicalSyncTransport
  let plan: DailyUsePlan
  let journal: DailyUseJournal

  func catalog(cursor: String?) async throws -> CallCatalogPage {
    try await underlying.catalog(cursor: cursor)
  }
  func changes(cursor: String) async throws -> CallChangesPage {
    try await underlying.changes(cursor: cursor)
  }
  func document(callID: String, version: Int?) async throws -> Data {
    try await underlying.document(callID: callID, version: version)
  }
  func audioManifest(callID: String) async throws -> Data {
    try await underlying.audioManifest(callID: callID)
  }
  func results(callID: String, cursor: String?) async throws -> TranscriptResultsPage {
    try await underlying.results(callID: callID, cursor: cursor)
  }
  func revision(callID: String, revisionID: String) async throws -> Data {
    let bytes = try await underlying.revision(callID: callID, revisionID: revisionID)
    if callID == plan.callID {
      try await journal.record(
        .init(event: "revision_downloaded", byteLength: bytes.count, sha256: Contract.hash(bytes))
      )
    }
    return bytes
  }
  func provenance(callID: String, revisionID: String) async throws -> Data {
    try await underlying.provenance(callID: callID, revisionID: revisionID)
  }
  func publish(
    callID: String,
    request: PublishCallReplica
  ) async throws -> StoredDocument<ReplicaReceipt> {
    guard callID == plan.callID else {
      throw CanonicalSyncError.remote(code: "acceptance_call_not_admitted", retry: .never)
    }
    let receipt = try await underlying.publish(callID: callID, request: request)
    try await journal.record(
      .init(event: "canonical_replica_confirmed", documentVersion: receipt.value.documentVersion)
    )
    return receipt
  }
  func requestTranscription(
    callID: String,
    request: RequestTranscription
  ) async throws -> TranscriptionOperation {
    guard callID == plan.callID,
      request.operationId == plan.transcriptionOperationID && request.revisionId == plan.revisionID,
      request.requestedLanguage == "en",
      request.profileId == "nova3-wav-s16le-16000-stereo-stream-v1"
    else { throw CanonicalSyncError.remote(code: "acceptance_call_not_admitted", retry: .never) }
    try await journal.record(
      .init(event: "automatic_transcription_requested", operationID: request.operationId)
    )
    let operation = try await underlying.requestTranscription(callID: callID, request: request)
    try recordBounds(operation)
    try await journal.record(
      .init(
        event: "automatic_transcription_returned",
        operationID: operation.operationId,
        attemptCount: operation.attemptCount,
        state: operation.state
      )
    )
    return operation
  }
  func operation(operationID: String) async throws -> TranscriptionOperation {
    let operation = try await underlying.operation(operationID: operationID)
    if operationID == plan.transcriptionOperationID {
      try recordBounds(operation)
      try await journal.record(
        .init(
          event: "operation_observed",
          operationID: operationID,
          attemptCount: operation.attemptCount,
          state: operation.state
        )
      )
    }
    return operation
  }

  private func recordBounds(_ operation: TranscriptionOperation) throws {
    try requireDailyUse(
      operation.archiveId == plan.archiveID && operation.callId == plan.callID
        && operation.operationId == plan.transcriptionOperationID
        && operation.revisionId == plan.revisionID && operation.attemptCount <= 2,
      "The server returned an operation outside the admitted identity or attempt bound."
    )
  }
}
