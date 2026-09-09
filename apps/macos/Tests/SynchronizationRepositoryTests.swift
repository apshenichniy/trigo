import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

func syncStored<T: ContractDocument>(_ value: T) throws -> StoredDocument<T> {
  try Contract.decode(T.self, bytes: Contract.encode(value))
}

func syncRevision(for call: CallDocument) throws -> Data {
  var revision =
    try Contract.decode(TranscriptRevision.self, bytes: repositoryFixture("grouping-revision.json"))
    .value
  revision.callId = call.callId
  revision.revisionId = UUID().uuidString.lowercased()
  revision.audioManifest = try #require(call.audioManifest)
  let oldSpeakers = revision.speakers.map(\.speakerId)
  let newSpeakers = oldSpeakers.map { _ in UUID().uuidString.lowercased() }
  let tracks = [
    "00000000-0000-4000-8000-000000000002": call.tracks.first(where: { $0.role == "microphone" })!
      .trackId,
    "00000000-0000-4000-8000-000000000003": call.tracks.first(where: { $0.role == "application" })!
      .trackId,
  ]
  for index in revision.speakers.indices {
    revision.speakers[index].speakerId = newSpeakers[index]
    revision.speakers[index].diarizationScopeId = UUID().uuidString.lowercased()
    revision.speakers[index].trackId = tracks[revision.speakers[index].trackId]!
  }
  for index in revision.turns.indices {
    revision.turns[index].turnId = UUID().uuidString.lowercased()
    revision.turns[index].trackId = tracks[revision.turns[index].trackId]!
    if let old = revision.turns[index].speakerId {
      revision.turns[index].speakerId = newSpeakers[oldSpeakers.firstIndex(of: old)!]
    }
  }
  if call.durationMs == 0 { revision.turns = []; revision.speakers = [] }
  return try Contract.encode(revision)
}

func syncResult(_ bytes: Data, generation: Int = 1) throws -> (CatalogTranscriptResult, Data) {
  let revision = try Contract.decode(TranscriptRevision.self, bytes: bytes).value
  let provenance = Data("{\"fixture\":\"exact retained provenance\"}".utf8)
  return (
    .init(
      operationId: UUID().uuidString.lowercased(),
      generation: generation,
      result: .init(
        revisionId: revision.revisionId,
        createdAt: revision.createdAt,
        sha256: Contract.hash(bytes),
        byteLength: bytes.count,
        provenanceSHA256: Contract.hash(provenance),
        provenanceByteLength: provenance.count
      )
    ), provenance
  )
}

func syncReceipt(
  for request: PublishCallReplica,
  archiveID: String
) throws -> StoredDocument<ReplicaReceipt> {
  let bytes = Data(request.document.utf8)
  let call = try Contract.decodeCallSnapshot(bytes).value
  return try syncStored(
    .init(
      schemaVersion: 1,
      operationId: request.operationId,
      archiveId: archiveID,
      callId: call.callId,
      documentVersion: call.documentVersion,
      sha256: Contract.hash(bytes),
      byteLength: bytes.count,
      publishedAt: "2026-09-08T12:00:00.000Z"
    )
  )
}

func uploadedSyncFixture(seconds: Int = 1) async throws -> MasterUploadFixture {
  let fixture = try await MasterUploadFixture.create(seconds: seconds)
  try await fixture.finish()
  let upload = MasterUploadCoordinator(
    repository: fixture.repository,
    transport: MasterUploadTestServer()
  )
  let report = try await upload.runPass()
  #expect(report.failures.isEmpty)
  return fixture
}

func syncReplicaContents(
  _ repository: LocalRepository,
  callID: String
) async throws -> ServerReplicaContents {
  let call = try await repository.loadCall(callID: callID)
  var provenance: [String: Data] = [:]
  for reference in call.manifest.value.revisions {
    provenance[reference.revisionId] = try repository.transcriptProvenanceBytes(
      revisionID: reference.revisionId
    )
  }
  return try .init(
    document: call.manifest.storedBytes,
    audioManifest: #require(call.audioManifest),
    revisions: call.transcriptRevisions,
    provenance: provenance,
    receipt: #require(try repository.verifiedMasterReceipt(callID: callID))
  )
}

var removeSyncSchemaFixtureSQL: String {
  (repositorySyncSchema + repositoryTimingSchema).reversed()
    .map { statement in
      let name =
        statement.components(separatedBy: "CREATE TABLE ")[1].components(separatedBy: "(")[0]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return "DROP TABLE \(name);"
    }
    .joined(separator: " ")
}

@Suite struct SynchronizationRepositoryTests {
  @Test func groupingRetainsNamesEvidenceAndIdentityAcrossReopen() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let bytes = try syncRevision(for: await repository.call(callID: callID))
    let revision = try Contract.decode(TranscriptRevision.self, bytes: bytes).value
    let (result, provenance) = try syncResult(bytes)
    _ = try await repository.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    let first = revision.speakers[0].speakerId
    let originalSpeakers = try await repository.speakers(
      callID: callID,
      revisionID: revision.revisionId
    )
    #expect(Set(originalSpeakers.map(\.neutralLabel)).count == revision.speakers.count)
    #expect(
      originalSpeakers.map(\.diarizationScopeID) == revision.speakers.map(\.diarizationScopeId)
    )
    _ = try await repository.setSpeakerName(
      "Александр 👋",
      callID: callID,
      revisionID: revision.revisionId,
      speakerID: first
    )
    let groupID = UUID().uuidString.lowercased()
    let edit = try await SpeakerAnnotationEdit(
      operationID: UUID().uuidString.lowercased(),
      callID: callID,
      revisionID: revision.revisionId,
      expectedDocumentVersion: repository.call(callID: callID).documentVersion,
      mutation: .group(
        groupID: groupID,
        displayName: "Same voice",
        speakerIDs: revision.speakers.map(\.speakerId)
      )
    )
    let grouped = try await repository.editSpeakerAnnotations(edit)
    #expect(grouped.value.speakerNames[revision.revisionId]?[first] == "Александр 👋")
    #expect(
      try await repository.turns(callID: callID, revisionID: revision.revisionId)[0].speakerName
        == "Same voice"
    )
    let groupedSpeakers = try await repository.speakers(
      callID: callID,
      revisionID: revision.revisionId
    )
    #expect(groupedSpeakers.map(\.neutralLabel) == originalSpeakers.map(\.neutralLabel))
    #expect(groupedSpeakers.allSatisfy { $0.displayName == "Same voice" && $0.groupID == groupID })
    #expect(groupedSpeakers.first?.excerpt?.text == originalSpeakers.first?.excerpt?.text)
    let reopened = try LocalRepository(root: fixture.root, archiveID: repositoryArchiveID)
    let replay = try await reopened.editSpeakerAnnotations(edit)
    #expect(replay.storedBytes == grouped.storedBytes)
    #expect(
      try await reopened.call(callID: callID).documentVersion == grouped.value.documentVersion
    )
    let removed = try await reopened.editSpeakerAnnotations(
      .init(
        operationID: UUID().uuidString.lowercased(),
        callID: callID,
        revisionID: revision.revisionId,
        expectedDocumentVersion: grouped.value.documentVersion,
        mutation: .removeMembers(groupID: groupID, speakerIDs: [first])
      )
    )
    #expect(removed.value.speakerGroups.isEmpty)
    #expect(
      try await reopened.turns(callID: callID, revisionID: revision.revisionId)[0].speakerName
        == "Александр 👋"
    )
    #expect(
      try await reopened.speakers(callID: callID, revisionID: revision.revisionId)
        .map(\.neutralLabel) == originalSpeakers.map(\.neutralLabel)
    )
    #expect(
      try await reopened.transcriptRevisionBytes(callID: callID, revisionID: revision.revisionId)
        == bytes
    )
    #expect(try reopened.transcriptProvenanceBytes(revisionID: revision.revisionId) == provenance)
    await #expect(throws: CanonicalSyncError.groupIdentityReused(groupID)) {
      try await reopened.editSpeakerAnnotations(
        .init(
          operationID: UUID().uuidString.lowercased(),
          callID: callID,
          revisionID: revision.revisionId,
          expectedDocumentVersion: removed.value.documentVersion,
          mutation: .group(
            groupID: groupID,
            displayName: "New entity",
            speakerIDs: revision.speakers.map(\.speakerId)
          )
        )
      )
    }
  }

  @Test(arguments: [
    PersistenceInterruptionPoint.afterRepositoryStaging, .beforeRepositoryCommit,
    .afterRepositoryCommit,
  ])
  func annotationCommitAndReplayHaveNoReplicaGap(_ point: PersistenceInterruptionPoint) async throws
  {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let callID = fixture.session.callID
    let bytes = try syncRevision(for: await fixture.repository.call(callID: callID))
    let revision = try Contract.decode(TranscriptRevision.self, bytes: bytes).value
    _ = try await fixture.repository.importRevision(
      bytes,
      associatedWork: .init(
        operationID: UUID().uuidString.lowercased(),
        archiveID: repositoryArchiveID,
        callID: callID,
        kind: .importRevision
      )
    )
    let prior = try await fixture.repository.call(callID: callID)
    let edit = SpeakerAnnotationEdit(
      operationID: UUID().uuidString.lowercased(),
      callID: callID,
      revisionID: revision.revisionId,
      expectedDocumentVersion: prior.documentVersion,
      mutation: .rename(speakerID: revision.speakers[0].speakerId, name: "Committed once")
    )
    let fault = RepositoryFault(point)
    let failing = try LocalRepository(
      root: fixture.root,
      archiveID: repositoryArchiveID,
      interruption: { try fault($0) }
    )
    await #expect(throws: RepositoryInjectedFailure.self) {
      try await failing.editSpeakerAnnotations(edit)
    }
    let reopened = try LocalRepository(root: fixture.root, archiveID: repositoryArchiveID)
    let value = try await reopened.editSpeakerAnnotations(edit)
    #expect(value.value.documentVersion == prior.documentVersion + 1)
    #expect(try reopened.pendingReplicas(callID: callID).count == 1)
    #expect(try await reopened.editSpeakerAnnotations(edit).storedBytes == value.storedBytes)
    #expect(try await reopened.lifecycle(callID: callID)?.replica.state == .pending)
  }

  @Test func lateReplicaAcknowledgementCannotConfirmANewerAnnotation() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    #expect(try await repository.isCallSavedOnMacAndServer(callID: callID) == false)
    try await repository.ensureCanonicalReplica(callID: callID)
    let base = try #require(repository.pendingReplicas().first)
    let baseRequest = try await repository.bindReplicaRequest(operationID: base.operationID)
    #expect(baseRequest.expectedDocumentVersion == nil)
    try await repository.acceptReplicaReceipt(
      syncReceipt(for: baseRequest, archiveID: repositoryArchiveID)
    )
    #expect(try await repository.isCallSavedOnMacAndServer(callID: callID) == false)
    let bytes = try syncRevision(for: await repository.call(callID: callID))
    let revision = try Contract.decode(TranscriptRevision.self, bytes: bytes).value
    let (result, provenance) = try syncResult(bytes)
    _ = try await repository.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    let importedWork = try #require(repository.pendingReplicas().first)
    let importedRequest = try await repository.bindReplicaRequest(
      operationID: importedWork.operationID
    )
    #expect(importedRequest.expectedDocumentVersion == base.documentVersion)
    _ = try await repository.setSpeakerName(
      "Pending local edit",
      callID: callID,
      revisionID: revision.revisionId,
      speakerID: revision.speakers[0].speakerId
    )
    #expect(
      try await repository.bindReplicaRequest(operationID: importedWork.operationID)
        == importedRequest
    )
    try await repository.acceptReplicaReceipt(
      syncReceipt(for: importedRequest, archiveID: repositoryArchiveID)
    )
    #expect(try await repository.isCallSavedOnMacAndServer(callID: callID) == false)
    let edit = try #require(repository.pendingReplicas().first)
    let request = try await repository.bindReplicaRequest(operationID: edit.operationID)
    #expect(request.expectedDocumentVersion == importedWork.documentVersion)
    try await repository.acceptReplicaReceipt(
      syncReceipt(for: request, archiveID: repositoryArchiveID)
    )
    #expect(try await repository.isCallSavedOnMacAndServer(callID: callID))
    #expect(try repository.pendingReplicas().isEmpty)
    #expect(
      try await repository.importAvailableResult(
        result,
        callID: callID,
        revision: bytes,
        provenance: provenance
      ) == .alreadyPresent
    )
    #expect(try await repository.isCallSavedOnMacAndServer(callID: callID))
  }

  @Test(arguments: [0, 1]) func restoreKeepsAudioRemoteAndDeletionCannotResurrect(
    _ seconds: Int
  ) async throws {
    let fixture = try await uploadedSyncFixture(seconds: seconds)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let callID = fixture.session.callID
    let bytes = try syncRevision(for: await fixture.repository.call(callID: callID))
    let (result, provenance) = try syncResult(bytes)
    _ = try await fixture.repository.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    let contents = try await syncReplicaContents(fixture.repository, callID: callID)
    let root = repositoryRoot("restore")
    defer { try? FileManager.default.removeItem(at: root) }
    let restored = try LocalRepository(root: root, archiveID: repositoryArchiveID)
    _ = try await restored.restoreReplica(contents)
    #expect(try await restored.isCallSavedOnMacAndServer(callID: callID))
    #expect(try await restored.captureSession(callID: callID) == nil)
    #expect(try await restored.loadCall(callID: callID).manifest.storedBytes == contents.document)
    #expect(
      try await restored.transcriptRevisionBytes(
        callID: callID,
        revisionID: result.result.revisionId
      ) == bytes
    )
    try await restored.acceptDeletionMarker(
      .init(callId: callID, markedAt: "2026-09-08T12:00:00Z", phase: "draining")
    )
    #expect(try await restored.calls().isEmpty)
    await #expect(throws: CanonicalSyncError.deleted) {
      try await restored.restoreReplica(contents)
    }
    #expect(try await restored.isCallSavedOnMacAndServer(callID: callID) == false)
  }

  @Test func oldSQLiteAndLegacySnapshotsUpgradeWithoutRehashingHistory() async throws {
    let root = repositoryRoot("v3-source")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try LocalRepository(root: root, archiveID: repositoryArchiveID)
    let bytes = try repositoryFixture("legacy-valid-recording.json")
    let legacy = try Contract.decodeCallSnapshot(bytes)
    try await repository.stageCall(legacy)
    _ = try repository.database.access {
      try repository.database.transaction {
        try repository.commitCall(legacy.value, hash: legacy.sha256, expected: nil)
      }
    }
    let copiedRoot = repositoryRoot("v3-copy")
    defer { try? FileManager.default.removeItem(at: copiedRoot) }
    try FileManager.default.copyItem(at: root, to: copiedRoot)
    try sqliteFixtureSQL(
      copiedRoot.appendingPathComponent(SQLiteDatabase.filename),
      removeSyncSchemaFixtureSQL
        + " PRAGMA user_version=3; UPDATE repository_identity SET root='\(copiedRoot.path)'"
    )
    let migrated = try LocalRepository(root: copiedRoot, archiveID: repositoryArchiveID)
    #expect(
      try await migrated.snapshotBytes(
        callID: legacy.value.callId,
        version: legacy.value.documentVersion
      ) == bytes
    )
    try await migrated.upgradeLegacyCallSnapshots()
    let current = try await migrated.loadCall(callID: legacy.value.callId)
    #expect(current.manifest.value.schemaVersion == 2)
    #expect(current.manifest.value.speakerGroups.isEmpty)
    #expect(current.manifest.value.documentVersion == legacy.value.documentVersion + 1)
    #expect(current.manifest.sha256 != legacy.sha256)
    #expect(
      try await migrated.snapshotBytes(
        callID: legacy.value.callId,
        version: legacy.value.documentVersion
      ) == bytes
    )
    try await migrated.upgradeLegacyCallSnapshots()
    #expect(
      try await migrated.loadCall(callID: legacy.value.callId).manifest.storedBytes
        == current.manifest.storedBytes
    )
  }
}
