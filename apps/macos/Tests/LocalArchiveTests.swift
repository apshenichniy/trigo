import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

private let archiveID = "00000000-0000-4000-8000-000000000012"
private let callID = "00000000-0000-4000-8000-000000000001"
private let firstRevisionID = "00000000-0000-4000-8000-000000000006"
private let secondRevisionID = "00000000-0000-4000-8000-000000000011"
private let thirdRevisionID = "00000000-0000-4000-8000-000000000030"
private let firstSpeakerID = "00000000-0000-4000-8000-000000000007"
private let thirdSpeakerID = "00000000-0000-4000-8000-000000000031"

private let fixtureRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appendingPathComponent("packages/contracts/fixtures", isDirectory: true)

private struct InjectedInterruption: Error {}

private final class FailOnce: @unchecked Sendable {
  private let lock = NSLock()
  private let target: PersistenceInterruptionPoint
  private var didFail = false

  init(at target: PersistenceInterruptionPoint) {
    self.target = target
  }

  func callAsFunction(_ point: PersistenceInterruptionPoint) throws {
    lock.lock()
    defer { lock.unlock() }
    if point == target && !didFail {
      didFail = true
      throw InjectedInterruption()
    }
  }
}

private func temporaryRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("trigo-archive-tests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private func fixture(_ name: String) throws -> Data {
  try Data(contentsOf: fixtureRoot.appendingPathComponent(name))
}

private func replacingJSONValue(_ data: Data, key: String, value: Any) throws -> Data {
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object[key] = value
  return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

private func recordingManifest() throws -> Data {
  try replacingJSONValue(try fixture("valid-recording.json"), key: "documentVersion", value: 1)
}

private func finalizedPreReferenceManifest(documentVersion: Int = 1) throws -> Data {
  var object = try #require(
    JSONSerialization.jsonObject(with: fixture("call.json")) as? [String: Any])
  object["documentVersion"] = documentVersion
  object["audioManifest"] = NSNull()
  object["revisions"] = []
  object["activeRevisionId"] = NSNull()
  object["speakerNames"] = [:]
  return try encodedJSONObject(object)
}

private func completeManifest() throws -> Data {
  try replacingJSONValue(
    try fixture("call.json"), key: "speakerNames", value: [:] as [String: Any])
}

private func publishCompleteCall(into archive: LocalRepository) async throws {
  _ = try await archive.publishManifest(finalizedPreReferenceManifest())
  _ = try await archive.publishAudioManifest(fixture("audio.json"))
  _ = try await archive.publishTranscriptRevision(fixture("revision.json"))
  _ = try await archive.publishTranscriptRevision(fixture("no-speech.json"))
  _ = try await archive.publishManifest(completeManifest())
}

private func encodedJSONObject(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
}

@Test func immutableRevisionsPublishIdempotentlyAndNeverChangeExistingBytes() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalRepository(root: root, archiveID: archiveID)

  _ = try await archive.publishManifest(finalizedPreReferenceManifest())
  _ = try await archive.publishAudioManifest(fixture("audio.json"))
  _ = try await archive.publishTranscriptRevision(fixture("revision.json"))
  let duplicate = try await archive.publishTranscriptRevision(fixture("revision.json"))
  #expect(duplicate == .alreadyPresent)

  let original = try await archive.transcriptRevisionBytes(
    callID: callID, revisionID: firstRevisionID)
  let conflicting = try replacingJSONValue(
    try fixture("revision.json"), key: "createdAt", value: "2026-09-05T10:02:00Z")
  await #expect(throws: LocalPersistenceError.self) {
    try await archive.publishTranscriptRevision(conflicting)
  }
  #expect(
    try await archive.transcriptRevisionBytes(callID: callID, revisionID: firstRevisionID)
      == original)
}

@Test func invalidManifestReferencesAndHashesCannotReplaceAValidCall() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalRepository(root: root, archiveID: archiveID)
  try await publishCompleteCall(into: archive)
  let original = try await archive.loadCall(callID: callID).manifest.storedBytes

  var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
  object["documentVersion"] = 3
  var revisions = try #require(object["revisions"] as? [[String: Any]])
  revisions[0]["sha256"] = String(repeating: "0", count: 64)
  object["revisions"] = revisions
  let badHash = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  await #expect(throws: Error.self) {
    try await archive.publishManifest(badHash)
  }

  let unsupported = try replacingJSONValue(original, key: "schemaVersion", value: 2)
  await #expect(throws: Error.self) {
    try await archive.publishManifest(unsupported)
  }

  let foreignArchive = try replacingJSONValue(
    original, key: "archiveId", value: "00000000-0000-4000-8000-000000000099")
  await #expect(throws: LocalPersistenceError.self) {
    try await archive.publishManifest(foreignArchive)
  }
  #expect(try await archive.loadCall(callID: callID).manifest.storedBytes == original)
}

@Test func higherManifestVersionCannotDiscardRetainedEvidenceOrAnnotations() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalRepository(root: root, archiveID: archiveID)
  try await publishCompleteCall(into: archive)
  _ = try await archive.setSpeakerName(
    "Саша", callID: callID, revisionID: firstRevisionID, speakerID: firstSpeakerID)
  let original = try await archive.loadCall(callID: callID).manifest.storedBytes
  let originalObject = try #require(
    JSONSerialization.jsonObject(with: original) as? [String: Any])

  var withoutRevision = originalObject
  withoutRevision["documentVersion"] = 4
  var revisions = try #require(withoutRevision["revisions"] as? [[String: Any]])
  revisions.removeAll { $0["revisionId"] as? String == secondRevisionID }
  withoutRevision["revisions"] = revisions
  withoutRevision["activeRevisionId"] = firstRevisionID

  var withoutNames = originalObject
  withoutNames["documentVersion"] = 4
  withoutNames["speakerNames"] = [:]

  var changedNames = originalObject
  changedNames["documentVersion"] = 4
  changedNames["speakerNames"] = [firstRevisionID: [firstSpeakerID: "Someone else"]]

  var withoutAudio = originalObject
  withoutAudio["documentVersion"] = 4
  withoutAudio["audioManifest"] = NSNull()

  var changedAudio = originalObject
  changedAudio["documentVersion"] = 4
  var audioReference = try #require(changedAudio["audioManifest"] as? [String: Any])
  audioReference["manifestId"] = "00000000-0000-4000-8000-000000000099"
  changedAudio["audioManifest"] = audioReference

  for invalid in [withoutRevision, withoutNames, changedNames, withoutAudio, changedAudio] {
    await #expect(throws: LocalPersistenceError.self) {
      try await archive.publishManifest(encodedJSONObject(invalid))
    }
  }
  #expect(try await archive.loadCall(callID: callID).manifest.storedBytes == original)
}

@Test func manifestEvolutionCanAppendANewActiveRevisionWithoutChangingRetainedData() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalRepository(root: root, archiveID: archiveID)
  try await publishCompleteCall(into: archive)
  _ = try await archive.setSpeakerName(
    "Саша", callID: callID, revisionID: firstRevisionID, speakerID: firstSpeakerID)
  let oldRevision = try await archive.transcriptRevisionBytes(
    callID: callID, revisionID: firstRevisionID)

  _ = try await archive.publishTranscriptRevision(
    fixture("valid-fresh-transcription-revision.json"))
  let appended = try replacingJSONValue(
    try fixture("valid-fresh-transcription.json"), key: "documentVersion", value: 4)
  #expect(try await archive.publishManifest(appended) == .committed)

  let loaded = try await archive.loadCall(callID: callID)
  let object = try #require(
    JSONSerialization.jsonObject(with: loaded.manifest.storedBytes) as? [String: Any])
  let names = try #require(object["speakerNames"] as? [String: [String: String]])
  #expect(object["activeRevisionId"] as? String == thirdRevisionID)
  #expect(names[firstRevisionID]?[firstSpeakerID] == "Саша")
  #expect(
    try await archive.transcriptRevisionBytes(callID: callID, revisionID: firstRevisionID)
      == oldRevision)
}

@Test func audioPublicationRequiresFinalizedMatchingCallAndCompleteTrackCoverage()
  async throws
{
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalRepository(root: root, archiveID: archiveID)
  let validAudio = try fixture("audio.json")
  let original = try #require(JSONSerialization.jsonObject(with: validAudio) as? [String: Any])

  _ = try await archive.publishManifest(recordingManifest())
  await #expect(throws: Error.self) {
    try await archive.publishAudioManifest(validAudio)
  }
  _ = try await archive.publishManifest(finalizedPreReferenceManifest(documentVersion: 2))

  var wrongCall = original
  wrongCall["callId"] = "00000000-0000-4000-8000-000000000099"

  var wrongProfile = original
  wrongProfile["mediaProfileId"] = "wrong-profile"

  var foreignTrack = original
  var objects = try #require(foreignTrack["objects"] as? [[String: Any]])
  var channelMap = try #require(objects[0]["channelMap"] as? [[String: Any]])
  channelMap[0]["trackId"] = "00000000-0000-4000-8000-000000000099"
  objects[0]["channelMap"] = channelMap
  foreignTrack["objects"] = objects

  var wrongDuration = original
  wrongDuration["durationMs"] = 2_000

  var missingTrack = original
  var incompleteObjects = try #require(missingTrack["objects"] as? [[String: Any]])
  var incompleteChannelMap = try #require(
    incompleteObjects[0]["channelMap"] as? [[String: Any]])
  incompleteChannelMap.removeAll {
    $0["trackId"] as? String == "00000000-0000-4000-8000-000000000003"
  }
  incompleteObjects[0]["channelMap"] = incompleteChannelMap
  missingTrack["objects"] = incompleteObjects

  for invalid in [wrongCall, wrongProfile, foreignTrack, wrongDuration, missingTrack] {
    await #expect(throws: Error.self) {
      try await archive.publishAudioManifest(encodedJSONObject(invalid))
    }
  }
  #expect(try await archive.publishAudioManifest(validAudio) == .committed)
}

@Test func revisionAudioReferenceRejectsStoredManifestWithAnotherIdentity() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalRepository(root: root, archiveID: archiveID)
  _ = try await archive.publishManifest(finalizedPreReferenceManifest())
  let audio = try fixture("audio.json")
  let wrongPathID = "00000000-0000-4000-8000-000000000099"
  _ = try await archive.publishAudioManifest(audio)
  // The evidence identity is a relational foreign key into its validated immutable metadata.
  #expect(throws: LocalPersistenceError.self) {
    try archive.database.access {
      try archive.database.execute(
        "INSERT INTO evidence VALUES (?,'audio',?,?)",
        [.text(wrongPathID), .text(callID), .text(Contract.hash(audio))])
    }
  }

  var revision = try #require(
    JSONSerialization.jsonObject(with: fixture("revision.json")) as? [String: Any])
  var reference = try #require(revision["audioManifest"] as? [String: Any])
  reference["manifestId"] = wrongPathID
  reference["sha256"] = "a2b877d544b6b5737fd99993eadaa9ff5ba4a91f042d0b6f04e29cc440b4ae56"
  revision["audioManifest"] = reference

  await #expect(throws: Error.self) {
    try await archive.publishTranscriptRevision(encodedJSONObject(revision))
  }
}

@Test func speakerNamesAreRevisionScopedAndDoNotRewriteTranscriptEvidence() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalRepository(root: root, archiveID: archiveID)
  try await publishCompleteCall(into: archive)
  _ = try await archive.setSpeakerName(
    "Саша", callID: callID, revisionID: firstRevisionID, speakerID: firstSpeakerID)
  _ = try await archive.publishTranscriptRevision(
    fixture("valid-fresh-transcription-revision.json"))
  let thirdManifest = try replacingJSONValue(
    try fixture("valid-fresh-transcription.json"), key: "documentVersion", value: 4)
  _ = try await archive.publishManifest(thirdManifest)
  let firstBytes = try await archive.transcriptRevisionBytes(
    callID: callID, revisionID: firstRevisionID)
  let thirdBytes = try await archive.transcriptRevisionBytes(
    callID: callID, revisionID: thirdRevisionID)

  _ = try await archive.setSpeakerName(
    "Guest", callID: callID, revisionID: thirdRevisionID, speakerID: thirdSpeakerID)

  let renamed = try await archive.setSpeakerName(
    "Alexander", callID: callID, revisionID: firstRevisionID, speakerID: firstSpeakerID)
  let renamedObject = try #require(
    JSONSerialization.jsonObject(with: renamed.manifest.storedBytes) as? [String: Any])
  let names = try #require(renamedObject["speakerNames"] as? [String: [String: String]])

  #expect(names[firstRevisionID]?[firstSpeakerID] == "Alexander")
  #expect(names[secondRevisionID] == nil)
  #expect(names[thirdRevisionID]?[thirdSpeakerID] == "Guest")
  let renamedManifest = try #require(
    JSONSerialization.jsonObject(with: renamed.manifest.storedBytes) as? [String: Any])
  #expect(renamedManifest["activeRevisionId"] as? String == thirdRevisionID)
  #expect(
    try await archive.transcriptRevisionBytes(callID: callID, revisionID: firstRevisionID)
      == firstBytes)
  #expect(
    try await archive.transcriptRevisionBytes(callID: callID, revisionID: thirdRevisionID)
      == thirdBytes)

  let removed = try await archive.setSpeakerName(
    nil, callID: callID, revisionID: firstRevisionID, speakerID: firstSpeakerID)
  let removedObject = try #require(
    JSONSerialization.jsonObject(with: removed.manifest.storedBytes) as? [String: Any])
  let namesAfterRemoval = try #require(
    removedObject["speakerNames"] as? [String: [String: String]])
  #expect(namesAfterRemoval[firstRevisionID] == nil)
  #expect(namesAfterRemoval[thirdRevisionID]?[thirdSpeakerID] == "Guest")
  #expect(
    try await archive.transcriptRevisionBytes(callID: callID, revisionID: firstRevisionID)
      == firstBytes)
}

@Test func interruptedAtomicPublicationRelaunchesIntoPriorOrCommittedDocument() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let baseline = try LocalRepository(root: root, archiveID: archiveID)
  _ = try await baseline.publishManifest(finalizedPreReferenceManifest())
  _ = try await baseline.publishAudioManifest(fixture("audio.json"))
  _ = try await baseline.publishTranscriptRevision(fixture("revision.json"))
  _ = try await baseline.publishTranscriptRevision(fixture("no-speech.json"))

  let beforeReplacement = FailOnce(at: .beforeRepositoryCommit)
  let interruptedBefore = try LocalRepository(
    root: root, archiveID: archiveID, interruption: beforeReplacement.callAsFunction)
  await #expect(throws: InjectedInterruption.self) {
    try await interruptedBefore.publishManifest(completeManifest())
  }

  let relaunchedPrior = try LocalRepository(root: root, archiveID: archiveID)
  let priorReport = try await relaunchedPrior.inspectArchive()
  #expect(priorReport.validCallIDs == [callID])
  #expect(try await relaunchedPrior.loadCall(callID: callID).manifest.documentVersion == 1)

  let afterReplacement = FailOnce(at: .afterRepositoryCommit)
  let interruptedAfter = try LocalRepository(
    root: root, archiveID: archiveID, interruption: afterReplacement.callAsFunction)
  await #expect(throws: InjectedInterruption.self) {
    try await interruptedAfter.publishManifest(completeManifest())
  }

  let relaunchedCommitted = try LocalRepository(root: root, archiveID: archiveID)
  #expect(try await relaunchedCommitted.loadCall(callID: callID).manifest.documentVersion == 2)
}

@Test func typedTranscriptExportKeepsOriginalIdentityAndRejectsReencodedBytes() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalRepository(root: root, archiveID: archiveID)
  try await publishCompleteCall(into: archive)
  let original = try await archive.transcriptRevisionBytes(
    callID: callID, revisionID: firstRevisionID)
  let stored = try Contract.decode(TranscriptRevision.self, bytes: original)
  let reencoded = try Contract.encode(stored.value)
  #expect(reencoded != original)
  #expect(try Contract.decode(TranscriptRevision.self, bytes: reencoded).value == stored.value)
  #expect(try await archive.publishTranscriptRevision(stored.storedBytes) == .alreadyPresent)
  await #expect(throws: LocalPersistenceError.immutableConflict(firstRevisionID)) {
    try await archive.publishTranscriptRevision(reencoded)
  }
  let retained = try await archive.transcriptRevisionBytes(
    callID: callID, revisionID: firstRevisionID)
  #expect(retained == original)
  #expect(Contract.hash(retained) == stored.sha256)
}
