import Foundation
import Testing

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

private func initialManifest() throws -> Data {
  try replacingJSONValue(try fixture("valid-recording.json"), key: "documentVersion", value: 1)
}

private func publishCompleteCall(into archive: LocalArchive) async throws {
  _ = try await archive.publishManifest(initialManifest())
  _ = try await archive.publishAudioManifest(fixture("audio.json"))
  _ = try await archive.publishTranscriptRevision(fixture("revision.json"))
  _ = try await archive.publishTranscriptRevision(fixture("no-speech.json"))
  _ = try await archive.publishManifest(fixture("call.json"))
}

@Test func immutableRevisionsPublishIdempotentlyAndNeverChangeExistingBytes() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalArchive(root: root, archiveID: archiveID)

  _ = try await archive.publishManifest(initialManifest())
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
  let archive = try LocalArchive(root: root, archiveID: archiveID)
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

@Test func speakerNamesAreRevisionScopedAndDoNotRewriteTranscriptEvidence() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let archive = try LocalArchive(root: root, archiveID: archiveID)
  try await publishCompleteCall(into: archive)
  _ = try await archive.publishTranscriptRevision(
    fixture("valid-fresh-transcription-revision.json"))
  let thirdManifest = try replacingJSONValue(
    try fixture("valid-fresh-transcription.json"), key: "documentVersion", value: 3)
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
}

@Test func interruptedAtomicPublicationRelaunchesIntoPriorOrCommittedDocument() async throws {
  let root = try temporaryRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let baseline = try LocalArchive(root: root, archiveID: archiveID)
  _ = try await baseline.publishManifest(initialManifest())
  _ = try await baseline.publishAudioManifest(fixture("audio.json"))
  _ = try await baseline.publishTranscriptRevision(fixture("revision.json"))
  _ = try await baseline.publishTranscriptRevision(fixture("no-speech.json"))

  let beforeReplacement = FailOnce(at: .afterArchiveTemporaryFileSynced)
  let interruptedBefore = try LocalArchive(
    root: root, archiveID: archiveID, interruption: beforeReplacement.callAsFunction)
  await #expect(throws: InjectedInterruption.self) {
    try await interruptedBefore.publishManifest(fixture("call.json"))
  }

  let relaunchedPrior = try LocalArchive(root: root, archiveID: archiveID)
  let priorReport = try await relaunchedPrior.reconcile()
  #expect(priorReport.removedTemporaryFiles == 1)
  #expect(try await relaunchedPrior.loadCall(callID: callID).manifest.documentVersion == 1)

  let afterReplacement = FailOnce(at: .afterArchiveAtomicReplacement)
  let interruptedAfter = try LocalArchive(
    root: root, archiveID: archiveID, interruption: afterReplacement.callAsFunction)
  await #expect(throws: InjectedInterruption.self) {
    try await interruptedAfter.publishManifest(fixture("call.json"))
  }

  let relaunchedCommitted = try LocalArchive(root: root, archiveID: archiveID)
  #expect(try await relaunchedCommitted.loadCall(callID: callID).manifest.documentVersion == 2)
}
