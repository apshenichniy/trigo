import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

func confirmPendingReplicas(_ repository: LocalRepository, callID: String) async throws {
  for work in try repository.pendingReplicas(callID: callID) {
    let request = try await repository.bindReplicaRequest(operationID: work.operationID)
    try await repository.acceptReplicaReceipt(
      syncReceipt(for: request, archiveID: repository.archiveID)
    )
  }
}

@Suite struct SpeakerConflictTests {
  @Test(arguments: [SpeakerConflictChoice.keepThisMac, .useServer])
  func explicitChoiceRetainsConcurrentImportsAndOnlyResolvesIntendedAnnotations(
    _ choice: SpeakerConflictChoice
  ) async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let firstBytes = try syncRevision(for: await repository.call(callID: callID))
    let first = try Contract.decode(TranscriptRevision.self, bytes: firstBytes).value
    let (firstResult, firstProvenance) = try syncResult(firstBytes)
    _ = try await repository.importAvailableResult(
      firstResult,
      callID: callID,
      revision: firstBytes,
      provenance: firstProvenance
    )
    try await confirmPendingReplicas(repository, callID: callID)
    let baseContents = try await syncReplicaContents(repository, callID: callID)
    var remote = try Contract.decodeCallSnapshot(baseContents.document).value
    remote.documentVersion += 1
    remote.speakerNames[first.revisionId] = [first.speakers[0].speakerId: "Server individual name"]
    remote.speakerGroups[first.revisionId] = [
      .init(
        groupId: UUID().uuidString.lowercased(),
        displayName: "Server group",
        speakerIds: first.speakers.map(\.speakerId)
      )
    ]
    let contents = ServerReplicaContents(
      document: try Contract.encode(remote),
      audioManifest: baseContents.audioManifest,
      revisions: baseContents.revisions,
      provenance: baseContents.provenance,
      receipt: baseContents.receipt
    )
    _ = try await repository.setSpeakerName(
      "This Mac's name",
      callID: callID,
      revisionID: first.revisionId,
      speakerID: first.speakers[0].speakerId
    )
    let secondBytes = try syncRevision(for: await repository.call(callID: callID))
    let second = try Contract.decode(TranscriptRevision.self, bytes: secondBytes).value
    let (secondResult, secondProvenance) = try syncResult(secondBytes, generation: 2)
    _ = try await repository.importAvailableResult(
      secondResult,
      callID: callID,
      revision: secondBytes,
      provenance: secondProvenance
    )
    try await repository.recordReplicaConflict(contents)
    let comparisons = try await repository.annotationConflicts(callID: callID)
    #expect(comparisons.count == 1)
    #expect(comparisons[0].local.names[first.speakers[0].speakerId] == "This Mac's name")
    #expect(comparisons[0].server.groups[0].displayName == "Server group")
    #expect(try await repository.isCallSavedOnMacAndServer(callID: callID) == false)
    let blocked = try #require(repository.pendingReplicas(callID: callID).first)
    await #expect(throws: CanonicalSyncError.conflict) {
      try await repository.bindReplicaRequest(operationID: blocked.operationID)
    }
    let resolutionID = UUID().uuidString.lowercased()
    let fault = RepositoryFault(.afterRepositoryCommit)
    let uncertain = try LocalRepository(
      root: fixture.root,
      archiveID: repositoryArchiveID,
      interruption: { try fault($0) }
    )
    await #expect(throws: RepositoryInjectedFailure.self) {
      try await uncertain.resolveSpeakerAnnotationConflict(
        callID: callID,
        revisionID: first.revisionId,
        serverDocumentVersion: remote.documentVersion,
        choice: choice,
        operationID: resolutionID
      )
    }
    let resolved = try await repository.resolveSpeakerAnnotationConflict(
      callID: callID,
      revisionID: first.revisionId,
      serverDocumentVersion: remote.documentVersion,
      choice: choice,
      operationID: resolutionID
    )
    #expect(resolved.value.source == remote.source)
    #expect(resolved.value.activeRevisionId == second.revisionId)
    #expect(resolved.value.revisions.map(\.revisionId) == [first.revisionId, second.revisionId])
    #expect(resolved.value.speakerNames[second.revisionId] == nil)
    #expect(resolved.value.speakerGroups[second.revisionId] == nil)
    #expect(
      resolved.value.speakerNames[first.revisionId]?[first.speakers[0].speakerId]
        == (choice == .keepThisMac ? "This Mac's name" : "Server individual name")
    )
    #expect(
      resolved.value.speakerGroups[first.revisionId]
        == (choice == .keepThisMac ? nil : remote.speakerGroups[first.revisionId])
    )
    #expect(try await repository.annotationConflicts(callID: callID).isEmpty)
    #expect(try repository.pendingReplicas(callID: callID).count == 1)
    let request = try await repository.bindReplicaRequest(operationID: resolutionID)
    #expect(request.expectedDocumentVersion == remote.documentVersion)
    #expect(request.annotationRevisionIds == [first.revisionId])
    try await repository.acceptReplicaReceipt(
      syncReceipt(for: request, archiveID: repositoryArchiveID)
    )
    #expect(try await repository.isCallSavedOnMacAndServer(callID: callID))
    #expect(
      try await repository.transcriptRevisionBytes(callID: callID, revisionID: first.revisionId)
        == firstBytes
    )
    #expect(
      try await repository.transcriptRevisionBytes(callID: callID, revisionID: second.revisionId)
        == secondBytes
    )
    #expect(
      try repository.transcriptProvenanceBytes(revisionID: first.revisionId) == firstProvenance
    )
  }

  @Test func aCompetingServerChangeReturnsToConflictAfterAnExplicitChoice() async throws {
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
    try await confirmPendingReplicas(repository, callID: callID)
    let base = try await syncReplicaContents(repository, callID: callID)
    var remote = try Contract.decodeCallSnapshot(base.document).value
    remote.documentVersion += 1
    remote.speakerNames[revision.revisionId] = [revision.speakers[0].speakerId: "Remote first"]
    _ = try await repository.setSpeakerName(
      "Local choice",
      callID: callID,
      revisionID: revision.revisionId,
      speakerID: revision.speakers[0].speakerId
    )
    func contents() throws -> ServerReplicaContents {
      .init(
        document: try Contract.encode(remote),
        audioManifest: base.audioManifest,
        revisions: base.revisions,
        provenance: base.provenance,
        receipt: base.receipt
      )
    }
    try await repository.recordReplicaConflict(contents())
    let resolutionID = UUID().uuidString.lowercased()
    _ = try await repository.resolveSpeakerAnnotationConflict(
      callID: callID,
      revisionID: revision.revisionId,
      serverDocumentVersion: remote.documentVersion,
      choice: .keepThisMac,
      operationID: resolutionID
    )
    let request = try await repository.bindReplicaRequest(operationID: resolutionID)
    remote.documentVersion += 1
    remote.speakerNames[revision.revisionId] = [
      revision.speakers[0].speakerId: "Remote changed again"
    ]
    try await repository.recordReplicaConflict(contents())
    #expect(
      try await repository.annotationConflicts(callID: callID)[0].server
        .names[revision.speakers[0].speakerId] == "Remote changed again"
    )
    #expect(request.expectedDocumentVersion == remote.documentVersion - 1)
    await #expect(throws: CanonicalSyncError.conflict) {
      try await repository.bindReplicaRequest(operationID: resolutionID)
    }
  }

  @Test func aConcurrentEditForcesImportToReprepareWithoutLosingNamesAndDeletionWins() async throws
  {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let first = try syncRevision(for: await repository.call(callID: callID))
    let firstRevision = try Contract.decode(TranscriptRevision.self, bytes: first).value
    _ = try await repository.importRevision(
      first,
      associatedWork: .init(
        operationID: UUID().uuidString.lowercased(),
        archiveID: repositoryArchiveID,
        callID: callID,
        kind: .importRevision
      )
    )
    let second = try syncRevision(for: await repository.call(callID: callID))
    let intent = OperationIntent(
      operationID: UUID().uuidString.lowercased(),
      archiveID: repositoryArchiveID,
      callID: callID,
      kind: .replica
    )
    let prepared = try await repository.prepareRevisionImport(second, associatedWork: intent)
    _ = try await repository.setSpeakerName(
      "Keep through import",
      callID: callID,
      revisionID: firstRevision.revisionId,
      speakerID: firstRevision.speakers[0].speakerId
    )
    await #expect(throws: LocalPersistenceError.concurrentMutation) {
      try await repository.commitRevisionImport(prepared)
    }
    _ = try await repository.importRevision(second, associatedWork: intent)
    #expect(
      try await repository.call(callID: callID).speakerNames[firstRevision.revisionId]?[
        firstRevision.speakers[0].speakerId
      ] == "Keep through import"
    )
    let third = try syncRevision(for: await repository.call(callID: callID))
    let late = try await repository.prepareRevisionImport(
      third,
      associatedWork: .init(
        operationID: UUID().uuidString.lowercased(),
        archiveID: repositoryArchiveID,
        callID: callID,
        kind: .replica
      )
    )
    try await repository.acceptDeletionMarker(
      .init(callId: callID, markedAt: "2026-09-08T12:00:00Z", phase: "requested")
    )
    await #expect(throws: CanonicalSyncError.deleted) {
      try await repository.commitRevisionImport(late)
    }
    #expect(try await repository.calls().isEmpty)
    #expect(try repository.pendingReplicas(callID: callID).isEmpty)
  }
}
