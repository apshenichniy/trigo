import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func repositoryIntervalReasonsSurviveTypedReadReopenAndSpeakerPublication() async throws {
  let root = repositoryRoot("interval-reasons")
  defer { try? FileManager.default.removeItem(at: root) }
  var repository: LocalRepository? = try await seedRepositoryCall(root: root, finalized: true)
  let audio = try repositoryFixture("audio.json")
  _ = try await repository!.publishAudioManifest(audio)
  var call = try await repository!.call(callID: repositoryCallID)
  call.documentVersion += 1
  call.audioManifest = .init(
    manifestId: "00000000-0000-4000-8000-000000000004",
    sha256: Contract.hash(audio)
  )
  _ = try await repository!.publishManifest(Contract.encode(call))
  let revisionBytes = try repositoryFixture("revision.json")
  let revision = try Contract.decode(TranscriptRevision.self, bytes: revisionBytes).value
  _ = try await repository!.importRevision(revisionBytes, associatedWork: repositoryIntent())
  call = try await repository!.call(callID: repositoryCallID)
  call.documentVersion += 1
  let reasons = [String(repeating: "я", count: 2050), "@trigo-text-v1:literal reason"]
  call.tracks[0].intervals[0].reason = reasons[0]
  call.tracks[1].intervals[0].reason = reasons[1]
  // Alternate valid JSON formatting is retained verbatim, separately from the typed view.
  let original = Data(" \n".utf8) + (try Contract.encode(call))
  let originalHash = Contract.hash(original)
  _ = try await repository!.publishManifest(original)
  let retained = try await repository!.loadCall(callID: repositoryCallID)
  #expect(retained.manifest.storedBytes == original)
  #expect(retained.manifest.sha256 == originalHash)
  #expect(retained.manifest.value.tracks.map { $0.intervals[0].reason } == reasons)
  repository = nil

  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let loaded = try await reopened.call(callID: repositoryCallID)
  #expect(loaded.tracks.map { $0.intervals[0].reason } == reasons)
  let renamed = try await reopened.setSpeakerName(
    "Renamed speaker",
    callID: repositoryCallID,
    revisionID: revision.revisionId,
    speakerID: revision.speakers[0].speakerId
  )
  #expect(renamed.manifest.value.documentVersion == call.documentVersion + 1)
  #expect(renamed.manifest.value.tracks.map { $0.intervals[0].reason } == reasons)
  let published = try Contract.decode(CallDocument.self, bytes: renamed.manifest.storedBytes)
  #expect(published.value.tracks.map { $0.intervals[0].reason } == reasons)
  #expect(
    published.value.speakerNames[revision.revisionId]?[revision.speakers[0].speakerId]
      == "Renamed speaker"
  )
  let originalAfterRename = try await reopened.snapshotBytes(
    callID: repositoryCallID,
    version: call.documentVersion
  )
  #expect(originalAfterRename == original)
  #expect(Contract.hash(originalAfterRename) == originalHash)
}

@Test func repositoryIncompleteDocumentConflictDoesNotPublishAnOperation() async throws {
  let root = repositoryRoot("incomplete-document-conflict")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root)
  let payload = Data(repeating: 79, count: 256 * 1024 + 128)
  let hash = Contract.hash(payload)
  let intent = repositoryIntent(payload: payload)
  // A prior interrupted preparation retained a conflicting first chunk under this hash.
  try repository.database.access {
    try repository.database.transaction {
      try repository.database.execute(
        "INSERT INTO documents VALUES (?,?,0)",
        [.text(hash), .int(payload.count)]
      )
      try repository.database.execute(
        "INSERT INTO document_chunks VALUES (?,0,?)",
        [.text(hash), .blob(Data(repeating: 80, count: 256 * 1024))]
      )
    }
  }
  await #expect(throws: LocalPersistenceError.immutableConflict(hash)) {
    _ = try await repository.recordIntent(intent)
  }
  let report = try await repository.inspectOperations()
  #expect(report.recoverableOperations.isEmpty)
  #expect(report.rejectedOperationIDs.isEmpty)
}

@Test func repositoryIncompleteMatchingDocumentResumesAndReplaysAcrossReopen() async throws {
  let root = repositoryRoot("incomplete-document-resume")
  defer { try? FileManager.default.removeItem(at: root) }
  var repository: LocalRepository? = try await seedRepositoryCall(root: root)
  let payload = Data(repeating: 79, count: 256 * 1024) + Data(repeating: 80, count: 128)
  let hash = Contract.hash(payload)
  let intent = repositoryIntent(payload: payload)
  try repository!.database
    .access {
      try repository!.database
        .transaction {
          try repository!.database
            .execute(
              "INSERT INTO documents VALUES (?,?,0)",
              [.text(hash), .int(payload.count)]
            )
          try repository!.database
            .execute(
              "INSERT INTO document_chunks VALUES (?,0,?)",
              [.text(hash), .blob(payload.prefix(256 * 1024))]
            )
        }
    }
  let initial = try await repository!.recordIntent(intent)
  #expect(initial.payload == payload)
  #expect(initial.payloadSHA256 == hash)
  #expect(try await repository!.recordIntent(intent) == initial)
  repository = nil
  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  #expect(try await reopened.operation(intent.operationID) == initial)
  #expect(try await reopened.recordIntent(intent) == initial)
  #expect(try await reopened.pendingOperations().count == 1)
}

@Test(arguments: ["missing", "empty", "oversized", "truncated", "checksum"])
func repositoryDocumentReadersRejectCorruptChunksWithoutRepairingReplay(
  _ fault: String
)
  async throws
{
  let root = repositoryRoot("document-corruption-\(fault)")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root)
  let payload = Data(repeating: 79, count: 256 * 1024 + 128)
  let intent = repositoryIntent(payload: payload)
  let operation = try await repository.recordIntent(intent)
  try repository.database.access {
    try repository.database.transaction {
      if fault == "missing" {
        try repository.database.execute(
          "DELETE FROM document_chunks WHERE hash=? AND part=0",
          [.text(operation.payloadSHA256)]
        )
      } else {
        let bytes: Data
        let part: Int
        switch fault {
        case "empty": (bytes, part) = (Data(), 0)
        case "oversized": (bytes, part) = (Data(repeating: 79, count: 256 * 1024 + 1), 0)
        case "truncated": (bytes, part) = (Data(repeating: 79, count: 127), 1)
        default: (bytes, part) = (Data(repeating: 80, count: 256 * 1024), 0)
        }
        try repository.database.execute(
          "UPDATE document_chunks SET bytes=? WHERE hash=? AND part=?",
          [.blob(bytes), .text(operation.payloadSHA256), .int(part)]
        )
      }
    }
  }
  if fault == "checksum" {
    await #expect(throws: ContractError.checksum) {
      try await repository.operation(intent.operationID)
    }
    await #expect(throws: ContractError.checksum) { try await repository.recordIntent(intent) }
  } else {
    let expected = LocalPersistenceError.invalidStoredDocument("Invalid SQLite row")
    await #expect(throws: expected) { try await repository.operation(intent.operationID) }
    await #expect(throws: expected) { try await repository.recordIntent(intent) }
  }
  let report = try await repository.inspectOperations()
  #expect(report.recoverableOperations.isEmpty)
  #expect(report.rejectedOperationIDs == [intent.operationID])
}
