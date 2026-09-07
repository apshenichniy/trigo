import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test(arguments: [PersistenceInterruptionPoint.beforeRepositoryCommit, .afterRepositoryCommit])
func repositoryMediaCertificateSurvivesTheExternalToSQLiteGap(point: PersistenceInterruptionPoint)
  async throws
{
  let root = repositoryRoot("media-gap")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  var repository: LocalRepository? = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  var writer: RecoverableMediaMaster? = try .init(
    directory: session.mediaDirectory, identity: session.mediaMasterIdentity)
  let first = try appendRepositorySecond(writer!)
  #expect(try repository!.commitMediaProgress(first) == .committed)
  let second = try appendRepositorySecond(writer!)
  let fault = RepositoryFault(point)
  repository = try .init(
    root: root, archiveID: repositoryArchiveID, interruption: fault.callAsFunction)
  #expect(throws: RepositoryInjectedFailure.self) { try repository!.commitMediaProgress(second) }
  writer = nil
  repository = nil
  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let witness = try #require(try reopened.confirmedMediaCursor(callID: session.callID))
  #expect(witness == (point == .afterRepositoryCommit ? second.cursor : first.cursor))
  let recovered = try RecoverableMediaMaster(
    reopening: session.mediaDirectory, expectedIdentity: session.mediaMasterIdentity,
    confirmed: witness)
  #expect(recovered.cursor == second.cursor)
  try recovered.forEachCommit(intersecting: 0..<recovered.cursor.frames) {
    _ = try reopened.commitMediaProgress($0)
  }
  #expect(try reopened.confirmedMediaCursor(callID: session.callID) == second.cursor)
  #expect(try reopened.commitMediaProgress(second) == .alreadyPresent)
  #expect(try reopened.mediaCommit(callID: session.callID, sequence: 2) == second)
  #expect(try await reopened.call(callID: session.callID).captureState == "recording")
  #expect(try await reopened.lifecycle(callID: session.callID)?.capture.state == .recording)
  let altered = MediaMasterCommit(
    cursor: second.cursor, startFrame: second.startFrame,
    pcmSHA256: String(repeating: "0", count: 64), microphoneIntervals: second.microphoneIntervals,
    applicationIntervals: second.applicationIntervals)
  #expect(throws: LocalPersistenceError.self) { try reopened.commitMediaProgress(altered) }
  // Already confirmed evidence can never be silently rolled back during external recovery.
  let index = try FileHandle(
    forWritingTo: session.mediaDirectory.appendingPathComponent("master.index"))
  try index.truncate(
    atOffset: UInt64(MediaMasterProfile.indexHeaderBytes + MediaMasterProfile.indexRecordBytes))
  try index.close()
  #expect(throws: MediaMasterError.confirmedCursorMissing) {
    try RecoverableMediaMaster(
      reopening: session.mediaDirectory, expectedIdentity: session.mediaMasterIdentity,
      confirmed: reopened.confirmedMediaCursor(callID: session.callID))
  }
  #expect(try reopened.confirmedMediaCursor(callID: session.callID) == second.cursor)
}

@Test func repositoryMediaFailurePublishesOnlyIssuedCertificates() async throws {
  let root = repositoryRoot("media-failure")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let repository = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let events = RepositoryMediaFault()
  var writer: RecoverableMediaMaster? = try .init(
    directory: session.mediaDirectory,
    identity: session.mediaMasterIdentity, io: .init(event: events.event))
  let first = try appendRepositorySecond(writer!)
  try repository.commitMediaProgress(first)
  #expect(throws: RepositoryInjectedFailure.self) {
    let failed = try appendRepositorySecond(writer!)
    try repository.commitMediaProgress(failed)
  }
  #expect(try repository.confirmedMediaCursor(callID: session.callID) == first.cursor)
  writer = nil
  let reopened = try RecoverableMediaMaster(
    reopening: session.mediaDirectory,
    expectedIdentity: session.mediaMasterIdentity, confirmed: first.cursor)
  #expect(reopened.cursor == first.cursor)
  #expect(reopened.discardedTailBytes == 64_000)
  #expect(2 * 16000 - reopened.cursor.frames <= 2 * 16000)
}

@Test func repositoryRejectsSkippedMalformedOrForeignMediaCertificates() async throws {
  let root = repositoryRoot("media-invalid")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let repository = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  let writer = try RecoverableMediaMaster(
    directory: session.mediaDirectory, identity: session.mediaMasterIdentity)
  let first = try appendRepositorySecond(writer)
  let second = try appendRepositorySecond(writer)
  #expect(throws: LocalPersistenceError.invalidMediaProgress) {
    try repository.commitMediaProgress(second)
  }
  let bad = MediaMasterCommit(
    cursor: .init(
      identity: first.cursor.identity, frames: first.cursor.frames,
      stableBytes: first.cursor.stableBytes + 4, commitCount: 1,
      integritySHA256: first.cursor.integritySHA256),
    startFrame: 0, pcmSHA256: first.pcmSHA256, microphoneIntervals: first.microphoneIntervals,
    applicationIntervals: first.applicationIntervals)
  #expect(throws: LocalPersistenceError.invalidMediaProgress) {
    try repository.commitMediaProgress(bad)
  }
  let foreignID = MediaMasterIdentity(
    masterID: UUID(), callID: first.cursor.identity.callID,
    microphoneTrackID: first.cursor.identity.microphoneTrackID,
    applicationTrackID: first.cursor.identity.applicationTrackID)
  let foreign = MediaMasterCommit(
    cursor: .init(
      identity: foreignID, frames: first.cursor.frames,
      stableBytes: first.cursor.stableBytes, commitCount: 1,
      integritySHA256: first.cursor.integritySHA256),
    startFrame: 0, pcmSHA256: first.pcmSHA256, microphoneIntervals: first.microphoneIntervals,
    applicationIntervals: first.applicationIntervals)
  #expect(throws: MediaMasterError.identityMismatch) { try repository.commitMediaProgress(foreign) }
  #expect(try repository.confirmedMediaCursor(callID: session.callID) == nil)
  try repository.commitMediaProgress(first)
  try repository.commitMediaProgress(second)
}

@Test(arguments: [PersistenceInterruptionPoint.beforeRepositoryCommit, .afterRepositoryCommit])
func repositoryZeroFrameMasterFinalizationIsJointAndRetainsItsCertificate(
  point: PersistenceInterruptionPoint
) async throws {
  let root = repositoryRoot("zero-master")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let writer = try RecoverableMediaMaster(
    directory: session.mediaDirectory, identity: session.mediaMasterIdentity)
  let final = try writer.finish()
  let audio = try session.audioBytes(final)
  let snapshot = try session.callBytes(
    media: final, reason: "process_terminated", version: 2, finalized: true,
    reference: .init(manifestId: session.audioManifestID, sha256: Contract.hash(audio)))
  let fault = RepositoryFault(point)
  var repository: LocalRepository? = try .init(
    root: root, archiveID: repositoryArchiveID, interruption: fault.callAsFunction)
  await #expect(throws: RepositoryInjectedFailure.self) {
    try await repository!.finalizeCapture(
      callSnapshot: snapshot, audioManifest: audio, verifiedMaster: final)
  }
  repository = nil
  let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
  #expect(
    (try reopened.finalizedMaster(callID: session.callID) != nil)
      == (point == .afterRepositoryCommit))
  _ = try await reopened.finalizeCapture(
    callSnapshot: snapshot, audioManifest: audio, verifiedMaster: final)
  #expect(try reopened.finalizedMaster(callID: session.callID) == final)
  #expect(try reopened.confirmedMediaCursor(callID: session.callID)?.frames == 0)
  #expect(try reopened.confirmedMediaCursor(callID: session.callID)?.stableBytes == 68)
  #expect(try reopened.mediaCommit(callID: session.callID, sequence: 0) == nil)
  #expect(
    try await reopened.call(callID: session.callID).tracks.allSatisfy { $0.intervals.isEmpty })
  #expect(try await reopened.lifecycle(callID: session.callID)?.capture.state == .interrupted)
}

@discardableResult
func appendRepositorySecond(_ writer: RecoverableMediaMaster) throws -> MediaMasterCommit {
  let start = Int(writer.cursor.frames / 16)
  return try writer.append(
    interleaved: Array(repeating: 321, count: 32000),
    microphoneIntervals: [.init(startMs: start, endMs: start + 1000, state: .recorded)],
    applicationIntervals: [.init(startMs: start, endMs: start + 1000, state: .recorded)])
}

private final class RepositoryMediaFault {
  private var syncs = 0
  func event(_ point: MediaMasterIOPoint) throws {
    if point == .afterMediaSync {
      syncs += 1
      if syncs == 2 { throw RepositoryInjectedFailure() }
    }
  }
}
