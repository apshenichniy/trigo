import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

actor CanonicalSyncTestServer: CanonicalSyncTransport {
  let callID: String
  let audio: Data
  let receipt: VerifiedMasterReceipt
  private var documents: [Int: Data] = [:]
  private var receipts: [String: StoredDocument<ReplicaReceipt>] = [:]
  private var operationValue: TranscriptionOperation?
  private var retainedResults: [CatalogTranscriptResult] = []
  private var revisions: [String: Data] = [:]
  private var provenanceBytes: [String: Data] = [:]
  private var sequence = 1
  private var marker: CallDeletionMarker?
  private var offline = false
  private var corrupt = false
  private var wrongArchive = false
  private var cursorReset = false
  private var losePublish = false
  private var loseRequest = false
  private var completeOnPoll = true
  private(set) var transcriptionRequests: [RequestTranscription] = []
  private(set) var publicationRequests: [PublishCallReplica] = []

  init(contents: ServerReplicaContents) throws {
    callID = try Contract.decodeCallSnapshot(contents.document).value.callId
    audio = contents.audioManifest
    receipt = contents.receipt.value
  }

  func setOffline(_ value: Bool) { offline = value }
  func setCorrupt(_ value: Bool) { corrupt = value }
  func setWrongArchive(_ value: Bool) { wrongArchive = value }
  func resetCursor() { cursorReset = true }
  func loseNextPublication() { losePublish = true }
  func loseNextRequest() { loseRequest = true }
  func holdResult() { completeOnPoll = false }
  func expireWait(code: String) throws {
    guard var value = operationValue else { throw CanonicalSyncError.invalidResult }
    value.state = "running"
    value.attemptCount = 1
    value.failure = .init(
      code: code,
      retry: code == "asr_admission_uncertain" ? "after_correction" : "retryable",
      message: "Resume the existing provider job."
    )
    operationValue = value
    sequence += 1
  }
  func delete() {
    marker = .init(callId: callID, markedAt: "2026-09-08T12:01:00.000Z", phase: "draining")
    sequence += 1
  }

  private func available() throws {
    if offline { throw CanonicalSyncError.serverUnavailable }
  }

  private func entry() throws -> CallCatalogEntry {
    var reference: ReplicaReference?
    if let version = documents.keys.max(), let bytes = documents[version] {
      reference = .init(
        documentVersion: version,
        schemaVersion: 2,
        sha256: Contract.hash(bytes),
        byteLength: bytes.count
      )
    }
    return .init(
      callId: callID,
      replica: marker == nil ? reference : nil,
      audio: marker == nil ? receipt : nil,
      latestTranscriptionOperationId: marker == nil ? operationValue?.operationId : nil,
      resultCount: marker == nil ? retainedResults.count : 0,
      deletion: marker
    )
  }

  func catalog(cursor: String?) throws -> CallCatalogPage {
    try available()
    return try .init(
      schemaVersion: 1,
      archiveId: wrongArchive ? UUID().uuidString.lowercased() : receipt.archiveId,
      calls: [entry()],
      nextCursor: nil,
      changesCursor: "cursor-\(sequence)"
    )
  }

  func changes(cursor: String) throws -> CallChangesPage {
    try available()
    if cursorReset { cursorReset = false; throw CanonicalSyncError.cursorReset }
    let old = Int(cursor.replacingOccurrences(of: "cursor-", with: "")) ?? 0
    return try .init(
      schemaVersion: 1,
      archiveId: wrongArchive ? UUID().uuidString.lowercased() : receipt.archiveId,
      changes: old < sequence ? [.init(sequence: sequence, call: entry())] : [],
      nextCursor: "cursor-\(sequence)",
      hasMore: false
    )
  }

  func document(callID: String, version: Int?) throws -> Data {
    try available()
    guard marker == nil, callID == self.callID, let version = version ?? documents.keys.max(),
      let document = documents[version]
    else { throw CanonicalSyncError.missingCanonicalDocument }
    return document
  }

  func audioManifest(callID: String) throws -> Data { try available(); return audio }

  func results(callID: String, cursor: String?) throws -> TranscriptResultsPage {
    try available()
    return .init(
      schemaVersion: 1,
      archiveId: receipt.archiveId,
      callId: callID,
      results: retainedResults,
      nextCursor: nil
    )
  }

  func revision(callID: String, revisionID: String) throws -> Data {
    try available()
    guard let bytes = revisions[revisionID] else { throw CanonicalSyncError.invalidResult }
    return corrupt ? bytes + Data("changed".utf8) : bytes
  }

  func provenance(callID: String, revisionID: String) throws -> Data {
    try available()
    guard let bytes = provenanceBytes[revisionID] else { throw CanonicalSyncError.invalidResult }
    return bytes
  }

  func publish(callID: String, request: PublishCallReplica) throws -> StoredDocument<ReplicaReceipt>
  {
    try available()
    if marker != nil { throw CanonicalSyncError.deleted }
    publicationRequests.append(request)
    if let receipt = receipts[request.operationId] { return receipt }
    guard request.expectedDocumentVersion == documents.keys.max() else {
      throw CanonicalSyncError.conflict
    }
    let bytes = Data(request.document.utf8)
    let call = try Contract.decodeCallSnapshot(bytes).value
    documents[call.documentVersion] = bytes
    let receipt = try syncReceipt(for: request, archiveID: self.receipt.archiveId)
    receipts[request.operationId] = receipt
    sequence += 1
    if losePublish { losePublish = false; throw CanonicalSyncError.serverUnavailable }
    return receipt
  }

  func requestTranscription(
    callID: String,
    request: RequestTranscription
  ) throws -> TranscriptionOperation {
    try available()
    guard !documents.isEmpty else { throw CanonicalSyncError.missingCanonicalDocument }
    transcriptionRequests.append(request)
    if let existing = operationValue {
      guard existing.operationId == request.operationId, existing.revisionId == request.revisionId
      else { throw CanonicalSyncError.invalidResult }
    } else {
      operationValue = .init(
        schemaVersion: 1,
        operationId: request.operationId,
        archiveId: receipt.archiveId,
        callId: callID,
        revisionId: request.revisionId,
        state: "queued",
        attemptCount: 0,
        createdAt: "2026-09-08T12:00:00.000Z",
        updatedAt: "2026-09-08T12:00:00.000Z",
        result: nil,
        failure: nil
      )
      sequence += 1
    }
    if loseRequest { loseRequest = false; throw CanonicalSyncError.serverUnavailable }
    return operationValue!
  }

  func operation(operationID: String) throws -> TranscriptionOperation {
    try available()
    guard let value = operationValue, value.operationId == operationID else {
      throw CanonicalSyncError.invalidResult
    }
    if value.state == "queued", completeOnPoll { try completeResult() }
    return operationValue!
  }

  func failOperation() throws {
    guard var value = operationValue else { throw CanonicalSyncError.invalidResult }
    value.state = "failed"
    value.attemptCount = 2
    value.failure = .init(
      code: "asr_attempts_exhausted",
      retry: "never",
      message: "Both admitted attempts failed."
    )
    operationValue = value
    sequence += 1
  }

  func completeResult() throws {
    guard var value = operationValue, let version = documents.keys.max(),
      let bytes = documents[version]
    else { throw CanonicalSyncError.invalidResult }
    if value.result != nil { return }
    let call = try Contract.decodeCallSnapshot(bytes).value
    var revision = try Contract.decode(TranscriptRevision.self, bytes: syncRevision(for: call))
      .value
    revision.revisionId = value.revisionId
    let revisionBytes = try Contract.encode(revision)
    let (original, provenance) = try syncResult(revisionBytes)
    let result = CatalogTranscriptResult(
      operationId: value.operationId,
      generation: 1,
      result: original.result
    )
    retainedResults = [result]
    revisions[revision.revisionId] = revisionBytes
    provenanceBytes[revision.revisionId] = provenance
    value.state = "result_available"
    value.attemptCount = 1
    value.result = result.result
    operationValue = value
    sequence += 1
  }
}

@Suite struct CanonicalSyncCoordinatorTests {
  @Test func automaticPipelineConfirmsBaseBeforeASRAndRetainsOneResultAcrossRestarts() async throws
  {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let callID = fixture.session.callID
    let server = try await CanonicalSyncTestServer(
      contents: syncReplicaContents(fixture.repository, callID: callID)
    )
    await server.loseNextPublication()
    let first = CanonicalSyncCoordinator(repository: fixture.repository, transport: server)
    #expect(try await first.runPass().failures[callID]?.retry == .retryable)
    #expect(await server.transcriptionRequests.isEmpty)
    let reopened = try LocalRepository(root: fixture.root, archiveID: repositoryArchiveID)
    let client = CanonicalSyncCoordinator(repository: reopened, transport: server)
    await server.loseNextRequest()
    #expect(try await client.runPass().failures[callID]?.retry == .retryable)
    let request = try #require(try reopened.automaticTranscription(callID: callID)?.request)
    #expect(request.profileId == "assemblyai-u2-wav-s16le-16000-stereo-v1")
    #expect(try await reopened.isCallSavedOnMacAndServer(callID: callID) == false)
    #expect(try await client.runPass().failures.isEmpty)
    #expect(try await client.runPass().importedRevisionIDs == [request.revisionId])
    #expect(try await reopened.isCallSavedOnMacAndServer(callID: callID))
    let current = try await reopened.loadCall(callID: callID).manifest
    #expect(try await client.runPass().importedRevisionIDs.isEmpty)
    #expect(try await reopened.loadCall(callID: callID).manifest.storedBytes == current.storedBytes)
    #expect(await server.transcriptionRequests == [request, request])
    #expect(try reopened.pendingReplicas(callID: callID).isEmpty)
    #expect(try reopened.transcriptProvenanceBytes(revisionID: request.revisionId) != nil)
  }

  @Test func restorationImportsAResultCompletedWhileThePreviousMacWasAway() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let callID = fixture.session.callID
    let server = try await CanonicalSyncTestServer(
      contents: syncReplicaContents(fixture.repository, callID: callID)
    )
    let initial = CanonicalSyncCoordinator(repository: fixture.repository, transport: server)
    #expect(try await initial.runPass().failures.isEmpty)
    try await server.completeResult()
    let root = repositoryRoot("sync-fresh-mac")
    defer { try? FileManager.default.removeItem(at: root) }
    let restored = try LocalRepository(root: root, archiveID: repositoryArchiveID)
    let client = CanonicalSyncCoordinator(repository: restored, transport: server)
    let report = try await client.runPass()
    #expect(report.failures.isEmpty)
    #expect(report.restoredCallIDs == [callID] && report.importedRevisionIDs.count == 1)
    #expect(try await restored.isCallSavedOnMacAndServer(callID: callID))
    #expect(try await restored.captureSession(callID: callID) == nil)
    #expect(await server.transcriptionRequests.count == 1)
    await server.delete()
    #expect(try await client.runPass().failures.isEmpty)
    #expect(try await restored.calls().isEmpty)
    await server.resetCursor()
    #expect(try await client.runPass().failures.isEmpty)
    #expect(try await restored.calls().isEmpty)
  }

  @Test func corruptedEvidenceRetriesFromRetainedCatalogWithoutAnotherServerChange() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let callID = fixture.session.callID
    let server = try await CanonicalSyncTestServer(
      contents: syncReplicaContents(fixture.repository, callID: callID)
    )
    let client = CanonicalSyncCoordinator(repository: fixture.repository, transport: server)
    _ = try await client.runPass()
    try await server.completeResult()
    await server.setCorrupt(true)
    #expect(try await client.runPass().failures[callID]?.code == "sync_evidence_invalid")
    let cursor = try fixture.repository.syncCursor()
    #expect(try await fixture.repository.call(callID: callID).activeRevisionId == nil)
    #expect(try await fixture.repository.isCallSavedOnMacAndServer(callID: callID) == false)
    await server.setCorrupt(false)
    #expect(try await client.runPass().importedRevisionIDs.count == 1)
    #expect(try await fixture.repository.isCallSavedOnMacAndServer(callID: callID))
    #expect(cursor != nil)
  }

  @Test func offlineNamesSurviveCursorResetAndWrongArchiveNeverAdvancesTheCursor() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let callID = fixture.session.callID
    let server = try await CanonicalSyncTestServer(
      contents: syncReplicaContents(fixture.repository, callID: callID)
    )
    let client = CanonicalSyncCoordinator(repository: fixture.repository, transport: server)
    _ = try await client.runPass()
    _ = try await client.runPass()
    let call = try await fixture.repository.call(callID: callID)
    let revision =
      try Contract.decode(
        TranscriptRevision.self,
        bytes: await fixture.repository.transcriptRevisionBytes(
          callID: callID,
          revisionID: #require(call.activeRevisionId)
        )
      )
      .value
    await server.setOffline(true)
    _ = try await fixture.repository.setSpeakerName(
      "Offline name",
      callID: callID,
      revisionID: revision.revisionId,
      speakerID: revision.speakers[0].speakerId
    )
    let bytes = try await fixture.repository.loadCall(callID: callID).manifest.storedBytes
    #expect(try await client.runPass().catalogFailure?.retry == .retryable)
    #expect(try await fixture.repository.loadCall(callID: callID).manifest.storedBytes == bytes)
    let cursor = try fixture.repository.syncCursor()
    await server.setOffline(false)
    await server.setWrongArchive(true)
    #expect(try await client.runPass().catalogFailure != nil)
    #expect(try fixture.repository.syncCursor() == cursor)
    await server.setWrongArchive(false)
    await server.resetCursor()
    #expect(try await client.runPass().failures.isEmpty)
    #expect(try await fixture.repository.loadCall(callID: callID).manifest.storedBytes == bytes)
    #expect(try await fixture.repository.isCallSavedOnMacAndServer(callID: callID))
  }

  @Test func anExhaustedInitialOperationDoesNotCreateAnotherAutomaticPaidCommand() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let callID = fixture.session.callID
    let server = try await CanonicalSyncTestServer(
      contents: syncReplicaContents(fixture.repository, callID: callID)
    )
    await server.holdResult()
    let client = CanonicalSyncCoordinator(repository: fixture.repository, transport: server)
    _ = try await client.runPass()
    try await server.failOperation()
    for _ in 0..<3 { _ = try await client.runPass() }
    #expect(await server.transcriptionRequests.count == 1)
    #expect(try await fixture.repository.lifecycle(callID: callID)?.transcription.state == .failed)
    #expect(try await fixture.repository.isCallSavedOnMacAndServer(callID: callID) == false)
  }

  @Test(arguments: ["asr_processing_timeout", "asr_admission_uncertain"])
  func waitingRecoveryReusesTheSameRequestAndBoundsAutomaticResumes(_ code: String) async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let callID = fixture.session.callID
    let server = try await CanonicalSyncTestServer(
      contents: syncReplicaContents(fixture.repository, callID: callID)
    )
    await server.holdResult()
    let client = CanonicalSyncCoordinator(
      repository: fixture.repository,
      transport: server,
      language: { "uk" }
    )
    _ = try await client.runPass()
    let original = try #require(await server.transcriptionRequests.first)
    #expect(original.requestedLanguage == "uk")
    try await server.expireWait(code: code)
    for _ in 0..<3 { _ = try await client.runPass(retryAfterCorrection: false) }
    let automaticCount = code == "asr_processing_timeout" ? 2 : 1
    #expect(await server.transcriptionRequests.count == automaticCount)
    _ = try await client.runPass(retryAfterCorrection: true)
    #expect(await server.transcriptionRequests.count == automaticCount + 1)
    #expect(await server.transcriptionRequests.allSatisfy { $0 == original })
  }
}
