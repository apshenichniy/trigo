import Darwin
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

private final class RepositoryBundleMarker: NSObject {}
private let repositoryBallast = Data(repeating: 91, count: 2 * 1024 * 1024)
private let repositoryKillOperationID = "00000000-0000-4000-8000-000000000210"

@Test(.enabled(if: ProcessInfo.processInfo.environment["TRIGO_SQLITE_KILL_ROOT"] != nil))
func repositorySIGKILLChild() async throws {
  let environment = ProcessInfo.processInfo.environment
  let root = URL(fileURLWithPath: try #require(environment["TRIGO_SQLITE_KILL_ROOT"]))
  let phase = try #require(environment["TRIGO_SQLITE_KILL_PHASE"])
  let after = environment["TRIGO_SQLITE_KILL_AFTER"] == "1"
  let database = try SQLiteDatabase.open(root: root, archiveID: repositoryArchiveID)
  try database.access { try database.execute("PRAGMA cache_size=4") }
  let repository = try LocalRepository(root: root, archiveID: repositoryArchiveID) { point in
    if point == (after ? .afterRepositoryCommit : .beforeRepositoryCommit) {
      if !after {
        // Force dirty pages to spill, producing a genuinely hot rollback journal. This
        // modifies existing retained bytes only inside the deliberately doomed transaction.
        try database.execute(
          "UPDATE document_chunks SET bytes=zeroblob(length(bytes)) WHERE hash=?",
          [.text(Contract.hash(repositoryBallast))])
      }
      _ = Darwin.kill(Darwin.getpid(), SIGKILL)
      while true { Darwin.pause() }
    }
  }
  let session = fixedRepositorySession(root)
  let callID = phase == "import" ? repositoryCallID : session.callID
  let work = OperationIntent(
    operationID: repositoryKillOperationID, archiveID: repositoryArchiveID,
    callID: callID, kind: .replica, payload: Data("joint-work".utf8))
  switch phase {
  case "begin": _ = try await repository.beginCapture(session, associatedWork: work)
  case "progress":
    let writer = try RecoverableMediaMaster(
      reopening: session.mediaDirectory, expectedIdentity: session.mediaMasterIdentity,
      confirmed: repository.confirmedMediaCursor(callID: callID))
    try repository.commitMediaProgress(appendRepositorySecond(writer))
  case "finalize":
    _ = try await repository.finalizeCapture(
      session, media: .init(objects: [], durationMs: 0), reason: "system_sleep",
      associatedWork: work)
  case "import":
    _ = try await repository.importRevision(
      repositoryFixture("revision.json"), associatedWork: work)
  default: throw RepositoryInjectedFailure()
  }
  Issue.record("The child must terminate inside the selected semantic transaction")
}

@Test(arguments: ["begin", "progress", "finalize", "import"], [false, true])
func repositoryRealSIGKILLReopensJointTransactionsIncludingHotJournals(
  phase: String, afterCommit: Bool
) async throws {
  let root = repositoryRoot("kill-\(phase)")
  defer { try? FileManager.default.removeItem(at: root) }
  var repository: LocalRepository? = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  try await repository!.stageDocument(repositoryBallast)
  let session = fixedRepositorySession(root)
  if phase == "import" {
    _ = try await seedRepositoryCall(root: root, finalized: true)
    let audio = try repositoryFixture("audio.json")
    _ = try await repository!.publishAudioManifest(audio)
    var call = try await repository!.call(callID: repositoryCallID)
    call.documentVersion = 2
    call.audioManifest = .init(
      manifestId: "00000000-0000-4000-8000-000000000004", sha256: Contract.hash(audio))
    _ = try await repository!.publishManifest(Contract.encode(call))
  } else if phase != "begin" {
    _ = try await repository!.beginCapture(session)
    if phase == "progress" {
      let writer = try RecoverableMediaMaster(
        directory: session.mediaDirectory, identity: session.mediaMasterIdentity)
      try repository!.commitMediaProgress(appendRepositorySecond(writer))
    }
  }
  repository = nil
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  let bundle = try #require(Bundle(for: RepositoryBundleMarker.self).executableURL?.path)
  let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().path
  child.arguments = [
    "--test-bundle-path", bundle, "--package-path", package,
    "--filter", "repositorySIGKILLChild", bundle, "--testing-library", "swift-testing",
  ]
  child.environment = ProcessInfo.processInfo.environment.merging(
    [
      "TRIGO_SQLITE_KILL_ROOT": root.path, "TRIGO_SQLITE_KILL_PHASE": phase,
      "TRIGO_SQLITE_KILL_AFTER": afterCommit ? "1" : "0",
    ], uniquingKeysWith: { _, value in value })
  child.standardOutput = FileHandle.nullDevice
  child.standardError = FileHandle.nullDevice
  try child.run()
  child.waitUntilExit()
  #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
  let journal = root.appendingPathComponent(SQLiteDatabase.filename + "-journal")
  let journalBytes =
    (try? FileManager.default.attributesOfItem(atPath: journal.path)[.size] as? Int) ?? 0
  if !afterCommit { #expect(journalBytes > 2 * 1024 * 1024) }
  if !afterCommit && phase == "begin" {
    let databaseURL = root.appendingPathComponent(SQLiteDatabase.filename)
    let originalDatabase = try Data(contentsOf: databaseURL)
    let originalJournal = try Data(contentsOf: journal)
    #expect(throws: LocalPersistenceError.self) {
      try LocalRepository(root: root, archiveID: UUID().uuidString.lowercased())
    }
    #expect(try Data(contentsOf: databaseURL) == originalDatabase)
    #expect(try Data(contentsOf: journal) == originalJournal)
  }
  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  #expect(try reopened.documentBytes(Contract.hash(repositoryBallast)) == repositoryBallast)
  if phase == "begin" {
    #expect((try await reopened.captureSession(callID: session.callID) != nil) == afterCommit)
    #expect((try await reopened.lifecycle(callID: session.callID) != nil) == afterCommit)
    #expect((try await reopened.operation(repositoryKillOperationID) != nil) == afterCommit)
  } else if phase == "progress" {
    let witness = try #require(try reopened.confirmedMediaCursor(callID: session.callID))
    #expect(witness.frames == (afterCommit ? 32000 : 16000))
    let media = try RecoverableMediaMaster(
      reopening: session.mediaDirectory, expectedIdentity: session.mediaMasterIdentity,
      confirmed: witness)
    #expect(media.cursor.frames == 32000)
    try media.forEachCommit(intersecting: 0..<media.cursor.frames) {
      _ = try reopened.commitMediaProgress($0)
    }
    #expect(try reopened.confirmedMediaCursor(callID: session.callID)?.frames == 32000)
  } else if phase == "finalize" {
    let call = try await reopened.call(callID: session.callID)
    let lifecycle = try #require(try await reopened.lifecycle(callID: session.callID))
    #expect((call.audioManifest != nil) == afterCommit)
    #expect(call.captureState == lifecycle.capture.state.rawValue)
    #expect(call.interruptionReason == lifecycle.capture.failure?.code)
    #expect((try await reopened.operation(repositoryKillOperationID) != nil) == afterCommit)
  } else {
    #expect((try await reopened.call(callID: repositoryCallID).revisions.count == 1) == afterCommit)
    #expect(
      (try await reopened.lifecycle(callID: repositoryCallID)?.importState.state == .imported)
        == afterCommit)
    #expect((try await reopened.operation(repositoryKillOperationID) != nil) == afterCommit)
  }
  print(
    "SQLITE_SIGKILL phase=\(phase) after_commit=\(afterCommit) hot_journal_bytes=\(journalBytes) rollback_and_identity=verified"
  )
}

private func fixedRepositorySession(_ root: URL) -> CaptureArchiveSession {
  .init(
    root: root, archiveID: repositoryArchiveID,
    callID: "00000000-0000-4000-8000-000000000201",
    microphoneTrackID: "00000000-0000-4000-8000-000000000202",
    applicationTrackID: "00000000-0000-4000-8000-000000000203",
    audioManifestID: "00000000-0000-4000-8000-000000000204",
    masterID: "00000000-0000-4000-8000-000000000205", startedAt: Date(timeIntervalSince1970: 1000),
    source: .init(
      applicationName: "Fixture", bundleID: "fixture.sqlite", processID: 123,
      windowID: 456, windowTitle: nil, processLaunchDate: Date(timeIntervalSince1970: 100)),
    microphone: nil)
}
