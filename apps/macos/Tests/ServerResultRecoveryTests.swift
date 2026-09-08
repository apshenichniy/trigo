import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Suite struct ServerResultRecoveryTests {
  @Test func restorationRetainsGenerationBeforeImportingAnOlderUnreferencedResult() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let newer = try syncRevision(for: await repository.call(callID: callID))
    let older = try syncRevision(for: await repository.call(callID: callID))
    let (newResult, newProvenance) = try syncResult(newer, generation: 2)
    let (oldResult, oldProvenance) = try syncResult(older, generation: 1)
    _ = try await repository.importAvailableResult(
      newResult,
      callID: callID,
      revision: newer,
      provenance: newProvenance
    )
    let contents = try await syncReplicaContents(repository, callID: callID)
    let fresh = try LocalRepository(
      root: fixture.root.appending(path: "restored-order"),
      archiveID: repositoryArchiveID
    )
    _ = try await fresh.restoreReplica(
      .init(
        document: contents.document,
        audioManifest: contents.audioManifest,
        revisions: contents.revisions,
        provenance: contents.provenance,
        receipt: contents.receipt,
        results: [newResult]
      )
    )
    #expect(try fresh.isServerResultImported(revisionID: newResult.result.revisionId))
    _ = try await fresh.importAvailableResult(
      oldResult,
      callID: callID,
      revision: older,
      provenance: oldProvenance
    )
    let restored = try await fresh.loadCall(callID: callID)
    #expect(restored.manifest.value.activeRevisionId == newResult.result.revisionId)
    #expect(restored.transcriptRevisions[newResult.result.revisionId] == newer)
    #expect(restored.transcriptRevisions[oldResult.result.revisionId] == older)
  }

  @Test func separateInstallationsPublishIndependentCommandsButReplayTheirOwnImport() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let base = try await syncReplicaContents(repository, callID: callID)
    let fresh = try LocalRepository(
      root: fixture.root.appending(path: "another-installation"),
      archiveID: repositoryArchiveID
    )
    _ = try await fresh.restoreReplica(base)
    let bytes = try syncRevision(for: await repository.call(callID: callID))
    let (result, provenance) = try syncResult(bytes)
    _ = try await repository.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    _ = try await fresh.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    let original = try #require(repository.pendingReplicas(callID: callID).first)
    let other = try #require(fresh.pendingReplicas(callID: callID).first)
    #expect(original.operationID != other.operationID)
    let reopened = try LocalRepository(root: fixture.root, archiveID: repositoryArchiveID)
    _ = try await reopened.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    #expect(
      try reopened.pendingReplicas(callID: callID).map(\.operationID) == [original.operationID]
    )
  }

  @Test(arguments: [0, -1])
  func aCompatibleBaseAtAnOlderOrEqualVersionRebindsANewPublication(_ difference: Int) async throws
  {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    try await repository.ensureCanonicalReplica(callID: callID)
    let previous = try #require(repository.pendingReplicas(callID: callID).first)
    let contents = try await syncReplicaContents(repository, callID: callID)
    var remote = try Contract.decodeCallSnapshot(contents.document).value
    let localVersion = remote.documentVersion
    remote.documentVersion += difference
    let remoteBytes = Data(" ".utf8) + (try Contract.encode(remote))
    try await repository.recordReplicaConflict(
      .init(
        document: remoteBytes,
        audioManifest: contents.audioManifest,
        revisions: [:],
        provenance: [:],
        receipt: contents.receipt
      )
    )
    let pending = try repository.pendingReplicas(callID: callID)
    #expect(pending.count == 1)
    let replacement = try #require(pending.first)
    #expect(replacement.operationID != previous.operationID)
    #expect(replacement.documentVersion == localVersion + 1)
    #expect(try await repository.lifecycle(callID: callID)?.replica.state == .pending)
    let request = try await repository.bindReplicaRequest(operationID: replacement.operationID)
    #expect(request.expectedDocumentVersion == remote.documentVersion)
    try await repository.acceptReplicaReceipt(
      syncReceipt(for: request, archiveID: repositoryArchiveID)
    )
    #expect(
      try await repository.ensureAutomaticTranscription(callID: callID, language: "en") != nil
    )
  }

  @Test func aLateGenerationIsRetainedWithoutReplacingTheNewerActiveRevision() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let newer = try syncRevision(for: await repository.call(callID: callID))
    let older = try syncRevision(for: await repository.call(callID: callID))
    let (newResult, newProvenance) = try syncResult(newer, generation: 2)
    let (oldResult, oldProvenance) = try syncResult(older, generation: 1)
    _ = try await repository.importAvailableResult(
      newResult,
      callID: callID,
      revision: newer,
      provenance: newProvenance
    )
    _ = try await repository.importAvailableResult(
      oldResult,
      callID: callID,
      revision: older,
      provenance: oldProvenance
    )
    let retained = try await repository.loadCall(callID: callID)
    #expect(retained.manifest.value.activeRevisionId == newResult.result.revisionId)
    #expect(
      Set(retained.manifest.value.revisions.map(\.revisionId)) == [
        newResult.result.revisionId, oldResult.result.revisionId,
      ]
    )
    _ = try await repository.importAvailableResult(
      newResult,
      callID: callID,
      revision: newer,
      provenance: newProvenance
    )
    #expect(
      try await repository.loadCall(callID: callID).manifest.storedBytes
        == retained.manifest.storedBytes
    )
  }

  @Test func associatingARestoredResultKeepsItsExactConfirmedSnapshot() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let bytes = try syncRevision(for: await repository.call(callID: callID))
    let (result, provenance) = try syncResult(bytes)
    _ = try await repository.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    try await confirmPendingReplicas(repository, callID: callID)
    let contents = try await syncReplicaContents(repository, callID: callID)
    let root = fixture.root.appending(path: "restored-result")
    let fresh = try LocalRepository(root: root, archiveID: repositoryArchiveID)
    _ = try await fresh.restoreReplica(contents)
    _ = try await fresh.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    #expect(try await fresh.loadCall(callID: callID).manifest.storedBytes == contents.document)
    #expect(try fresh.pendingReplicas(callID: callID).isEmpty)
    #expect(try await fresh.isCallSavedOnMacAndServer(callID: callID))
    #expect(try fresh.isServerResultImported(revisionID: result.result.revisionId))
  }

  @Test func aBaseWithoutRevisionsCanRecoverFromACompatibleServerVersion() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    try await repository.ensureCanonicalReplica(callID: callID)
    let contents = try await syncReplicaContents(repository, callID: callID)
    var remote = try Contract.decodeCallSnapshot(contents.document).value
    remote.documentVersion += 1
    let remoteBytes = try Contract.encode(remote)
    try await repository.recordReplicaConflict(
      .init(
        document: remoteBytes,
        audioManifest: contents.audioManifest,
        revisions: [:],
        provenance: [:],
        receipt: contents.receipt
      )
    )
    #expect(try await repository.annotationConflicts(callID: callID).isEmpty)
    #expect(try await repository.lifecycle(callID: callID)?.replica.state == .confirmed)
    #expect(try repository.pendingReplicas(callID: callID).isEmpty)
    #expect(try await repository.loadCall(callID: callID).manifest.storedBytes == remoteBytes)
    #expect(
      try await repository.ensureAutomaticTranscription(callID: callID, language: "en") != nil
    )
  }
}
