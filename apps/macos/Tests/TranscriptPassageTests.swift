import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func retainedTranscriptGapsInterleaveWithoutChangingEvidence() async throws {
  let root = repositoryRoot("retained-gaps")
  defer { try? FileManager.default.removeItem(at: root) }
  var repository: LocalRepository? = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  var call = try Contract.decode(CallDocument.self, bytes: repositoryFixture("call.json")).value
  call.archiveId = repositoryArchiveID
  call.durationMs = 60_000
  call.endedAt = "2026-09-05T10:01:00Z"
  for index in call.tracks.indices { call.tracks[index].intervals[0].endMs = 60_000 }
  call.audioManifest = nil
  call.revisions = []
  call.activeRevisionId = nil
  call.speakerNames = [:]
  _ = try await repository!.publishManifest(Contract.encode(call))
  var audioValue = try Contract.decode(AudioManifest.self, bytes: repositoryFixture("audio.json"))
    .value
  audioValue.durationMs = 60_000
  audioValue.objects[0].endMs = 60_000
  audioValue.objects[0].byteLength = 60_000 * 64 + 44
  let audio = try Contract.encode(audioValue)
  _ = try await repository!.publishAudioManifest(audio)
  call.documentVersion += 1
  call.audioManifest = .init(
    manifestId: "00000000-0000-4000-8000-000000000004",
    sha256: Contract.hash(audio)
  )
  _ = try await repository!.publishManifest(Contract.encode(call))
  var revision =
    try Contract.decode(TranscriptRevision.self, bytes: repositoryFixture("revision.json")).value
  revision.audioManifest.sha256 = Contract.hash(audio)
  revision.turns[0].words[0].text = "Hello."
  revision.turns[0].words[1].text = "Returning."
  revision.turns[0].words[1].startMs = 40_000
  revision.turns[0].words[1].endMs = 40_600
  revision.turns[0].endMs = 40_600
  revision.turns[0].text = "Hello. Returning."
  revision.turns[1].text = "Meanwhile."
  let bytes = try Contract.encode(revision)
  _ = try await repository!.importRevision(bytes, associatedWork: repositoryIntent())
  let canonical = try await repository!.loadCall(callID: repositoryCallID).manifest.storedBytes
  // A v5 store has only immutable turns/words, as in the already recorded call.
  try repository!.database
    .access {
      try repository!.database.execute("DROP TABLE IF EXISTS revision_passages")
      try repository!.database.execute("DROP TABLE IF EXISTS revision_passage_projections")
      try repository!.database.execute("PRAGMA user_version=5")
    }
  repository = nil

  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let turns = try await reopened.turns(callID: repositoryCallID, revisionID: revision.revisionId)
  #expect(turns.map(\.text) == ["Hello.", "Meanwhile.", "Returning."])
  #expect(turns.map(\.startMs) == [100, 600, 40_000])
  #expect(Set(turns.map(\.passageID)).count == 3)
  #expect(try await reopened.libraryRevisions(callID: repositoryCallID).first?.turnCount == 3)
  var paged: [LocalTurn] = []
  for _ in 0..<4 {
    paged += try await reopened.turns(
      callID: repositoryCallID,
      revisionID: revision.revisionId,
      after: paged.last?.ordinal ?? -1,
      limit: 1
    )
  }
  #expect(paged == turns)
  let retained = try await reopened.loadCall(callID: repositoryCallID)
  #expect(retained.manifest.storedBytes == canonical)
  #expect(retained.transcriptRevisions[revision.revisionId] == bytes)
  _ = try await reopened.setSpeakerName(
    "Named voice",
    callID: repositoryCallID,
    revisionID: revision.revisionId,
    speakerID: revision.speakers[0].speakerId
  )
  let renamed = try await reopened.turns(callID: repositoryCallID, revisionID: revision.revisionId)
  #expect(renamed.map(\.speakerName) == ["Named voice", nil, "Named voice"])
  #expect(
    renamed.map(\.turnID) == [
      revision.turns[0].turnId, revision.turns[1].turnId, revision.turns[0].turnId,
    ]
  )
  #expect(renamed.map(\.passageID) == turns.map(\.passageID))
  let speakers = try await reopened.speakers(
    callID: repositoryCallID,
    revisionID: revision.revisionId
  )
  #expect(speakers.first?.excerpt?.text == "Hello.")
}
