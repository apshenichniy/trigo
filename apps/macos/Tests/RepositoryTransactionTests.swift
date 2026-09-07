import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

enum InvalidRevisionReference: CaseIterable, Sendable {
  case duplicateSpeaker, duplicateTurn, foreignSpeakerTrack, foreignTurnTrack, missingTrack
  case pastDuration, wrongAudioIdentity, wrongAudioHash, corruptRetainedBytes
}

@Test(arguments: InvalidRevisionReference.allCases)
func repositoryTypedImportRejectsInvalidReferencesWithoutPublishing(
  _ invalid: InvalidRevisionReference
) async throws {
  let root = repositoryRoot("typed-import-reference")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root, finalized: true)
  let audio = try repositoryFixture("audio.json")
  _ = try await repository.publishAudioManifest(audio)
  var call = try await repository.call(callID: repositoryCallID)
  call.documentVersion += 1
  call.audioManifest = .init(
    manifestId: "00000000-0000-4000-8000-000000000004", sha256: Contract.hash(audio))
  _ = try await repository.publishManifest(Contract.encode(call))
  let retainedBytes = try repositoryFixture("revision.json")
  _ = try await repository.importRevision(retainedBytes, associatedWork: repositoryIntent())
  let retained = try Contract.decode(TranscriptRevision.self, bytes: retainedBytes).value
  var incoming = retained
  incoming.revisionId = UUID().uuidString.lowercased()
  incoming.speakers[0].speakerId = UUID().uuidString.lowercased()
  incoming.turns[0].speakerId = incoming.speakers[0].speakerId
  incoming.turns[0].turnId = UUID().uuidString.lowercased()
  incoming.turns[1].turnId = UUID().uuidString.lowercased()
  switch invalid {
  case .duplicateSpeaker:
    incoming.speakers[0].speakerId = retained.speakers[0].speakerId
    incoming.turns[0].speakerId = retained.speakers[0].speakerId
  case .duplicateTurn: incoming.turns[0].turnId = retained.turns[0].turnId
  case .foreignSpeakerTrack:
    incoming.speakers[0].trackId = UUID().uuidString.lowercased()
    incoming.turns[0].trackId = incoming.speakers[0].trackId
  case .foreignTurnTrack: incoming.turns[1].trackId = UUID().uuidString.lowercased()
  case .pastDuration: incoming.turns[1].endMs = try #require(call.durationMs) + 1
  case .wrongAudioIdentity: incoming.audioManifest.manifestId = UUID().uuidString.lowercased()
  case .wrongAudioHash: incoming.audioManifest.sha256 = String(repeating: "0", count: 64)
  case .missingTrack, .corruptRetainedBytes: break
  }
  var bytes = try Contract.encode(incoming)
  if invalid == .missingTrack {
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    var turns = try #require(object["turns"] as? [[String: Any]])
    turns[0].removeValue(forKey: "trackId")
    object["turns"] = turns
    bytes = try JSONSerialization.data(withJSONObject: object)
  }
  if invalid == .corruptRetainedBytes {
    try repository.database.access {
      try repository.database.transaction {
        try repository.database.execute(
          "UPDATE document_chunks SET bytes=? WHERE hash=? AND part=0",
          [
            .blob(Data(repeating: 0, count: retainedBytes.count)),
            .text(Contract.hash(retainedBytes)),
          ])
      }
    }
  }
  let version = try await repository.call(callID: repositoryCallID).documentVersion
  let lifecycle = try await repository.lifecycle(callID: repositoryCallID)
  let documentCount = try repository.database.access {
    try repository.database.scalarInt("SELECT count(*) FROM documents")
  }
  let work = repositoryIntent()
  await #expect(throws: ContractError.self) {
    try await repository.importRevision(bytes, associatedWork: work)
  }
  #expect(try await repository.call(callID: repositoryCallID).documentVersion == version)
  #expect(try await repository.lifecycle(callID: repositoryCallID) == lifecycle)
  #expect(
    try await repository.turns(callID: repositoryCallID, revisionID: incoming.revisionId).isEmpty)
  #expect(try await repository.operation(work.operationID) == nil)
  #expect(
    try repository.database.access {
      try repository.database.scalarInt("SELECT count(*) FROM documents")
    } == documentCount)
}

@Test func repositoryFinalizationIntentRetainsAssociatedWorkAcrossUncertainPublication()
  async throws
{
  let root = repositoryRoot("legacy-seal-work")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let repository = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let work = repositoryIntent(
    callID: session.callID, kind: .upload, payload: Data("sealed media".utf8))
  await #expect(throws: RepositoryInjectedFailure.self) {
    try await repository.finalizeCapture(
      session, master: nil, reason: "process_terminated",
      associatedWork: work
    ) {
      if $0 == .beforeRepositoryCommit { throw RepositoryInjectedFailure() }
    }
  }
  #expect(try await repository.call(callID: session.callID).captureState == "recording")
  #expect(try await repository.operation(work.operationID) == nil)
  let recovered = try await session.recover()
  #expect(recovered.manifest.value.captureState == "interrupted")
  #expect(try await repository.operation(work.operationID)?.payload == work.payload)
  let alternate = repositoryIntent(callID: session.callID, kind: .upload)
  await #expect(throws: LocalPersistenceError.operationConflict(alternate.operationID)) {
    try await repository.finalizeCapture(
      session, master: nil, reason: "process_terminated",
      associatedWork: alternate)
  }
}

@Test(arguments: [PersistenceInterruptionPoint.beforeRepositoryCommit, .afterRepositoryCommit])
func repositoryCaptureAdmissionAndWorkHaveOneCommit(point: PersistenceInterruptionPoint)
  async throws
{
  let root = repositoryRoot("admission")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  let work = repositoryIntent(
    callID: session.callID, kind: .capture, payload: Data("allocated".utf8))
  let fault = RepositoryFault(point)
  var repository: LocalRepository? = try .init(
    root: root, archiveID: repositoryArchiveID, interruption: fault.callAsFunction)
  await #expect(throws: RepositoryInjectedFailure.self) {
    try await repository!.beginCapture(session, associatedWork: work)
  }
  repository = nil
  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let committed = point == .afterRepositoryCommit
  #expect(try await reopened.captureSession(callID: session.callID) == (committed ? session : nil))
  #expect((try await reopened.lifecycle(callID: session.callID) != nil) == committed)
  #expect((try await reopened.operation(work.operationID) != nil) == committed)
  #expect(try await reopened.calls().count == (committed ? 1 : 0))
  _ = try await reopened.beginCapture(session, associatedWork: work)
  #expect(try await reopened.captureSession(callID: session.callID) == session)
  #expect(try await reopened.call(callID: session.callID).captureState == "recording")
  #expect(try await reopened.lifecycle(callID: session.callID)?.capture.state == .recording)
  #expect(try await reopened.operation(work.operationID)?.payload == work.payload)
  let changed = OperationIntent(
    operationID: work.operationID, archiveID: work.archiveID,
    callID: work.callID, kind: .upload, payload: Data("different".utf8))
  await #expect(throws: LocalPersistenceError.operationConflict(work.operationID)) {
    try await reopened.beginCapture(session, associatedWork: changed)
  }
}

@Test(arguments: [PersistenceInterruptionPoint.beforeRepositoryCommit, .afterRepositoryCommit])
func repositoryCaptureFinalizationAndWorkHaveOneCommit(point: PersistenceInterruptionPoint)
  async throws
{
  let root = repositoryRoot("finalize")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let work = repositoryIntent(callID: session.callID, kind: .upload)
  let fault = RepositoryFault(point)
  var repository: LocalRepository? = try .init(
    root: root, archiveID: repositoryArchiveID, interruption: fault.callAsFunction)
  await #expect(throws: RepositoryInjectedFailure.self) {
    try await repository!.finalizeCapture(
      session, master: nil, reason: "system_sleep",
      associatedWork: work)
  }
  repository = nil
  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let committed = point == .afterRepositoryCommit
  let call = try await reopened.call(callID: session.callID)
  let lifecycle = try #require(try await reopened.lifecycle(callID: session.callID))
  #expect((call.audioManifest != nil) == committed)
  #expect(call.captureState == (committed ? "interrupted" : "recording"))
  #expect(call.captureState == lifecycle.capture.state.rawValue)
  #expect(call.interruptionReason == lifecycle.capture.failure?.code)
  #expect((try await reopened.operation(work.operationID) != nil) == committed)
  let final = try await reopened.finalizeCapture(
    session, master: nil, reason: "system_sleep", associatedWork: work)
  let repeated = try await reopened.finalizeCapture(
    session, master: nil, reason: "system_sleep", associatedWork: work)
  #expect(final.manifest.storedBytes == repeated.manifest.storedBytes)
  #expect(try await reopened.lifecycle(callID: session.callID)?.upload.state == .pending)
  #expect(try await reopened.lifecycle(callID: session.callID)?.importState.state == .notAvailable)
  var conflicting = final.manifest.value
  conflicting.durationMs = 1
  await #expect(throws: Error.self) {
    try await reopened.finalizeCapture(
      callSnapshot: Contract.encode(conflicting), audioManifest: #require(final.audioManifest))
  }
  let changed = OperationIntent(
    operationID: work.operationID, archiveID: work.archiveID,
    callID: work.callID, kind: .replica, payload: Data([1]))
  await #expect(throws: LocalPersistenceError.operationConflict(work.operationID)) {
    try await reopened.finalizeCapture(
      session, master: nil, reason: "system_sleep",
      associatedWork: changed)
  }
}

@Test(arguments: [PersistenceInterruptionPoint.beforeRepositoryCommit, .afterRepositoryCommit])
func repositoryRevisionImportPublishesEvidenceProjectionLifecycleAndWorkTogether(
  point: PersistenceInterruptionPoint
) async throws {
  let root = repositoryRoot("import")
  defer { try? FileManager.default.removeItem(at: root) }
  var repository: LocalRepository? = try await seedRepositoryCall(root: root, finalized: true)
  _ = try await repository!.publishAudioManifest(repositoryFixture("audio.json"))
  // Import needs the canonical audio reference; creating it is a separate prior fact.
  var call = try await repository!.call(callID: repositoryCallID)
  call.audioManifest = .init(
    manifestId: "00000000-0000-4000-8000-000000000004",
    sha256: Contract.hash(try repositoryFixture("audio.json")))
  call.documentVersion += 1
  _ = try await repository!.publishManifest(Contract.encode(call))
  let work = repositoryIntent(payload: Data("replicate-revision".utf8))
  let bytes = try repositoryFixture("revision.json")
  let revision = try Contract.decode(TranscriptRevision.self, bytes: bytes).value
  let prepared = try await repository!.prepareRevisionImport(bytes, associatedWork: work)
  #expect(
    try await repository!.turns(callID: repositoryCallID, revisionID: revision.revisionId).isEmpty)
  #expect(try await repository!.operation(work.operationID) == nil)
  #expect(
    try await repository!.lifecycle(callID: repositoryCallID)?.importState.state == .notAvailable)
  let fault = RepositoryFault(point)
  repository = try LocalRepository(
    root: root, archiveID: repositoryArchiveID, interruption: fault.callAsFunction)
  await #expect(throws: RepositoryInjectedFailure.self) {
    try await repository!.commitRevisionImport(prepared)
  }
  repository = nil
  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let committed = point == .afterRepositoryCommit
  #expect(
    (try await reopened.call(callID: repositoryCallID).activeRevisionId == revision.revisionId)
      == committed)
  #expect((try await reopened.operation(work.operationID) != nil) == committed)
  #expect(
    (try await reopened.lifecycle(callID: repositoryCallID)?.importState.state == .imported)
      == committed)
  _ = try await reopened.commitRevisionImport(prepared)
  #expect(try await reopened.importRevision(bytes, associatedWork: work) == .alreadyPresent)
  #expect(
    try await reopened.transcriptRevisionBytes(
      callID: repositoryCallID, revisionID: revision.revisionId) == bytes)
  let turns = try await reopened.turns(callID: repositoryCallID, revisionID: revision.revisionId)
  #expect(turns.map(\.turnID) == revision.turns.map(\.turnId))
  #expect(turns.map(\.text) == revision.turns.map(\.text))
  #expect(try await reopened.lifecycle(callID: repositoryCallID)?.replica.state == .pending)
}

@Test func repositoryPreparedImportCannotOverwriteAConcurrentSnapshot() async throws {
  let root = repositoryRoot("stale-import")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root, finalized: true)
  let audio = try repositoryFixture("audio.json")
  _ = try await repository.publishAudioManifest(audio)
  var call = try await repository.call(callID: repositoryCallID)
  call.audioManifest = .init(
    manifestId: "00000000-0000-4000-8000-000000000004", sha256: Contract.hash(audio))
  call.documentVersion = 2
  _ = try await repository.publishManifest(Contract.encode(call))
  let work = repositoryIntent()
  let prepared = try await repository.prepareRevisionImport(
    repositoryFixture("revision.json"), associatedWork: work)
  call.documentVersion = 3
  _ = try await repository.publishManifest(Contract.encode(call))
  await #expect(throws: LocalPersistenceError.concurrentMutation) {
    try await repository.commitRevisionImport(prepared)
  }
  #expect(try await repository.operation(work.operationID) == nil)
  #expect(try await repository.call(callID: repositoryCallID).revisions.isEmpty)
  _ = try await repository.importRevision(repositoryFixture("revision.json"), associatedWork: work)
  #expect(try await repository.call(callID: repositoryCallID).documentVersion == 4)
}

@Test func repositorySnapshotHistoryRetainsExactBytesAndNeverMovesBackward() async throws {
  let root = repositoryRoot("snapshots")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root)
  let original = try await repository.snapshotBytes(callID: repositoryCallID, version: 1)
  var call = try await repository.call(callID: repositoryCallID)
  call.documentVersion = 3
  let latest = try Contract.encode(call)
  _ = try await repository.publishManifest(latest)
  #expect(try await repository.publishManifest(original) == .alreadyPresent)
  #expect(try await repository.snapshotBytes(callID: repositoryCallID, version: 1) == original)
  #expect(try await repository.loadCall(callID: repositoryCallID).manifest.storedBytes == latest)
  let differentBytes = Data(" \n".utf8) + original
  await #expect(throws: LocalPersistenceError.self) {
    try await repository.publishManifest(differentBytes)
  }
  call.documentVersion = 2
  await #expect(throws: LocalPersistenceError.staleDocumentVersion(current: 3, proposed: 2)) {
    try await repository.publishManifest(Contract.encode(call))
  }
}

@Test func repositoryCaptureAxisCannotBeWrittenThroughProcessingLifecycle() async throws {
  let root = repositoryRoot("capture-owner")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let repository = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  await #expect(throws: LocalPersistenceError.captureStateOwnedByRepository) {
    try await repository.updateLifecycle(callID: session.callID) {
      $0.capture = .init(state: .stopped)
    }
  }
  await #expect(throws: LocalPersistenceError.captureStateOwnedByRepository) {
    try await repository.publishManifest(
      session.callBytes(
        media: nil, reason: nil, version: 2, finalized: true, reference: nil))
  }
  #expect(try await repository.lifecycle(callID: session.callID)?.capture.state == .recording)
}
