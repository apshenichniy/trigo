import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Suite(.serialized)
struct MasterUploadTests {
  @Test func activeCaptureUploadsOnlyFullStablePartsAndRetainsTwoSourceTimelineAfterCleanup()
    async throws
  {
    let fixture = try await MasterUploadFixture.create(seconds: 132)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let server = MasterUploadTestServer()
    var client: MasterUploadCoordinator? = .init(repository: fixture.repository, transport: server)
    let active = try await client!.runPass()
    #expect(active.uploadedParts == 1 && active.storedCallIDs.isEmpty && active.failures.isEmpty)
    #expect(fixture.mediaExists)
    #expect(try fixture.repository.masterUploadParts(callID: fixture.session.callID).count == 1)
    #expect(
      try await fixture.repository.lifecycle(callID: fixture.session.callID)?.capture.state
        == .recording
    )
    try fixture.appendSecond()
    let final = try await fixture.finish(reason: "process_terminated")
    let originalCall = try await fixture.repository.snapshotBytes(
      callID: fixture.session.callID,
      version: 2
    )
    client = nil
    let reopened = try LocalRepository(root: fixture.root, archiveID: repositoryArchiveID)
    let recovered = MasterUploadCoordinator(repository: reopened, transport: server)
    let report = try await recovered.runPass()
    #expect(report.uploadedParts == 1 && report.storedCallIDs == [fixture.session.callID])
    #expect(report.cleanedCallIDs == [fixture.session.callID] && report.failures.isEmpty)
    #expect(!fixture.mediaExists && !FileManager.default.fileExists(atPath: fixture.indexURL.path))
    #expect(
      try await reopened.snapshotBytes(callID: fixture.session.callID, version: 2) == originalCall
    )
    let stored = try #require(try reopened.verifiedMasterReceipt(callID: fixture.session.callID))
      .value
    #expect(stored.masterSHA256 == final.sha256 && stored.durationMs == 133000)
    #expect(stored.byteLength == 133 * 64000 + 68)
    #expect(
      stored.channelMap.map(\.trackId) == [
        fixture.session.microphoneTrackID, fixture.session.applicationTrackID,
      ]
    )
    let call = try await reopened.call(callID: fixture.session.callID)
    #expect(
      call.tracks.allSatisfy {
        $0.intervals == [.init(startMs: 0, endMs: 133000, state: "recorded", reason: nil)]
      }
    )
    #expect(
      try await reopened.lifecycle(callID: fixture.session.callID)?.capture.state == .interrupted
    )
    #expect(
      try await reopened.lifecycle(callID: fixture.session.callID)?.transcription.state
        == .waitingForAudio
    )
    #expect(try await reopened.pendingOperations().isEmpty)
    #expect(await server.registerRequests.count == 1)
    #expect(await server.maximumBodyBytes == 8_388_608)
    #expect(try await recovered.runPass().uploadedParts == 0)
  }

  @Test(arguments: [MasterUploadTransportFault.register, .part, .final])
  func lostAcknowledgementsReplayTheOriginalDurableIdentity(
    fault: MasterUploadTransportFault
  ) async throws {
    let fixture = try await MasterUploadFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.finish()
    let server = MasterUploadTestServer(fault: fault)
    let first = MasterUploadCoordinator(repository: fixture.repository, transport: server)
    let failed = try await first.runPass()
    #expect(failed.failures[fixture.session.callID]?.retry == .retryable)
    #expect(fixture.mediaExists)
    #expect(try fixture.repository.verifiedMasterReceipt(callID: fixture.session.callID) == nil)
    let state = try #require(try fixture.repository.masterUpload(callID: fixture.session.callID))
    let reopened = try LocalRepository(root: fixture.root, archiveID: repositoryArchiveID)
    let second = MasterUploadCoordinator(repository: reopened, transport: server)
    #expect(try await second.runPass().storedCallIDs == [fixture.session.callID])
    #expect(!fixture.mediaExists)
    #expect(try reopened.masterUpload(callID: fixture.session.callID)?.uploadID == state.uploadID)
    let registrations = await server.registerRequests
    let finals = await server.finalRequests
    let parts = await server.partRequests
    #expect(registrations.allSatisfy { $0.uploadId == state.uploadID })
    #expect(finals.allSatisfy { $0.operationId == state.finalizeOperationID })
    #expect(parts.allSatisfy { $0 == parts.first })
  }

  @Test(arguments: [
    MasterUploadPersistencePoint.beforeReceiptCommit, .afterReceiptCommit,
    .beforeMediaCleanup, .afterMasterRemoval, .afterMediaCleanup,
  ])
  func crashesNeverAuthorizeCleanupBeforeDurableVerifiedReceipt(
    point: MasterUploadPersistencePoint
  ) async throws {
    let fixture = try await MasterUploadFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.finish()
    let sentinel = fixture.session.mediaDirectory.appendingPathComponent("retained-evidence")
    try Data("preserve".utf8).write(to: sentinel)
    let server = MasterUploadTestServer()
    let fault = MasterUploadFault(point)
    let client = MasterUploadCoordinator(
      repository: fixture.repository,
      transport: server,
      interruption: fault.callAsFunction
    )
    let report = try await client.runPass()
    #expect(report.failures.count == 1)
    let receipt = try fixture.repository.verifiedMasterReceipt(callID: fixture.session.callID)
    #expect((receipt != nil) == (point != .beforeReceiptCommit))
    if receipt == nil {
      #expect(fixture.mediaExists)
    } else {
      #expect(
        try await fixture.repository.lifecycle(callID: fixture.session.callID)?.upload.state
          == .stored
      )
    }
    let reopened = try LocalRepository(root: fixture.root, archiveID: repositoryArchiveID)
    let recovery = MasterUploadCoordinator(repository: reopened, transport: server)
    let recovered = try await recovery.runPass()
    #expect(recovered.failures.isEmpty && recovered.cleanedCallIDs == [fixture.session.callID])
    #expect(!fixture.mediaExists)
    #expect(try reopened.masterUpload(callID: fixture.session.callID)?.cleanupComplete == true)
    #expect(try Data(contentsOf: sentinel) == Data("preserve".utf8))
    #expect(await server.finalRequests.count == (point == .beforeReceiptCommit ? 2 : 1))
  }

  @Test func forgedReceiptAndLifecycleStoredAloneCannotDeleteAudio() async throws {
    let fixture = try await MasterUploadFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.finish()
    _ = try await fixture.repository.updateLifecycle(callID: fixture.session.callID) {
      $0.upload = .init(state: .stored)
    }
    await #expect(throws: MasterUploadError.invalidReceipt) {
      try await fixture.repository.cleanupVerifiedMaster(callID: fixture.session.callID)
    }
    let server = MasterUploadTestServer(fault: .forgedReceipt)
    let client = MasterUploadCoordinator(repository: fixture.repository, transport: server)
    #expect(
      try await client.runPass().failures[fixture.session.callID]?.code == "upload_receipt_invalid"
    )
    #expect(fixture.mediaExists)
    #expect(try await client.runPass(retryAfterCorrection: false).storedCallIDs.isEmpty)
    #expect(await server.finalRequests.count == 1)
    #expect(try await client.runPass().storedCallIDs == [fixture.session.callID])
  }

  @Test(arguments: [MasterUploadPersistencePoint.beforeReceiptCommit, .afterReceiptCommit])
  func receiptRecoveryReopensSQLiteAfterEveryClientAndWriterHasClosed(
    point: MasterUploadPersistencePoint
  ) async throws {
    var fixture: MasterUploadFixture? = try await .create()
    let root = fixture!.root
    let callID = fixture!.session.callID
    let mediaURL = fixture!.mediaURL
    defer { try? FileManager.default.removeItem(at: root) }
    try await fixture!.finish()
    let server = MasterUploadTestServer()
    let fault = MasterUploadFault(point)
    var client: MasterUploadCoordinator? = .init(
      repository: fixture!.repository,
      transport: server,
      interruption: fault.callAsFunction
    )
    _ = try await client!.runPass()
    weak let priorDatabase = fixture!.repository.database
    fixture = nil
    client = nil
    #expect(priorDatabase == nil)
    let reopened = try LocalRepository(root: root, archiveID: repositoryArchiveID)
    #expect(
      (try reopened.verifiedMasterReceipt(callID: callID) != nil) == (point == .afterReceiptCommit)
    )
    #expect(FileManager.default.fileExists(atPath: mediaURL.path))
    let recovery = MasterUploadCoordinator(repository: reopened, transport: server)
    #expect(try await recovery.runPass().cleanedCallIDs == [callID])
    #expect(!FileManager.default.fileExists(atPath: mediaURL.path))
    #expect(try await reopened.pendingOperations().isEmpty)
  }

  @Test func localDeletionFencePreventsNewRequestsAndReceiptPublication() async throws {
    let fixture = try await MasterUploadFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.finish()
    let server = MasterUploadTestServer(fault: .final)
    let client = MasterUploadCoordinator(repository: fixture.repository, transport: server)
    _ = try await client.runPass()
    let request = try #require(await server.finalRequests.first)
    let receipt = try await server.finalize(callID: fixture.session.callID, request: request)
    _ = try await fixture.repository.updateLifecycle(callID: fixture.session.callID) {
      $0.deletion = .init(state: .requested)
    }
    await #expect(throws: MasterUploadError.fenced) {
      try await fixture.repository.acceptVerifiedMasterReceipt(
        receipt,
        callID: fixture.session.callID
      )
    }
    _ = try await client.runPass()
    #expect(await server.finalRequests.count == 2)
    #expect(fixture.mediaExists)
    #expect(try fixture.repository.verifiedMasterReceipt(callID: fixture.session.callID) == nil)
  }

  @Test func backgroundLifetimeCoalescesWakesAndCancellationKeepsReplayableMedia() async throws {
    let fixture = try await MasterUploadFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    try await fixture.finish()
    let server = MasterUploadTestServer(fault: .pausePart)
    let client = MasterUploadCoordinator(
      repository: fixture.repository,
      transport: server,
      interval: .seconds(30)
    )
    await client.start()
    let deadline = ContinuousClock.now + .seconds(5)
    while await server.partRequests.isEmpty && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await server.partRequests.count == 1)
    for _ in 0..<10 { await client.wake() }
    #expect(try await client.runPass().coalesced)
    await client.stop()
    #expect(await server.cancelledParts == 1)
    #expect(await server.partRequests.count == 1)
    #expect(fixture.mediaExists)
    #expect(
      try fixture.repository.masterUploadParts(callID: fixture.session.callID).first?.receipt == nil
    )
    #expect(try await client.runPass().storedCallIDs == [fixture.session.callID])
  }

  @Test func transportReaderNeverTruncatesUncommittedCaptureTail() async throws {
    let fixture = try await MasterUploadFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let confirmed = try #require(
      try fixture.repository.confirmedMediaCursor(callID: fixture.session.callID)
    )
    _ = try appendRepositorySecond(fixture.writer)
    let before = try Data(contentsOf: fixture.mediaURL)
    let data = try RecoverableMediaMaster.readStableBytes(
      directory: fixture.session.mediaDirectory,
      confirmed: confirmed,
      in: 0..<confirmed.stableBytes
    )
    #expect(data == before.prefix(Int(confirmed.stableBytes)))
    #expect(try Data(contentsOf: fixture.mediaURL) == before)
    #expect(throws: MediaMasterError.invalidInput) {
      try RecoverableMediaMaster.readStableBytes(
        directory: fixture.session.mediaDirectory,
        confirmed: confirmed,
        in: 0..<fixture.writer.cursor.stableBytes
      )
    }
  }

  @Test func exactVersionTwoStoreMigratesWithoutChangingCaptureOrDocuments() async throws {
    let fixture = try await MasterUploadFixture.create()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let snapshot = try await fixture.repository.snapshotBytes(
      callID: fixture.session.callID,
      version: 1
    )
    let cursor = try fixture.repository.confirmedMediaCursor(callID: fixture.session.callID)
    // A disposable v2 file is created from the exact prior schema and real captured rows.
    let copiedRoot = repositoryRoot("upload-migration")
    defer { try? FileManager.default.removeItem(at: copiedRoot) }
    try FileManager.default.copyItem(at: fixture.root, to: copiedRoot)
    let url = copiedRoot.appendingPathComponent(SQLiteDatabase.filename)
    try sqliteFixtureSQL(
      url,
      "DROP TABLE master_upload_parts; DROP TABLE master_uploads; PRAGMA user_version=2; UPDATE repository_identity SET root='\(copiedRoot.path)'"
    )
    let migrated = try LocalRepository(root: copiedRoot, archiveID: repositoryArchiveID)
    #expect(
      try await migrated.snapshotBytes(callID: fixture.session.callID, version: 1) == snapshot
    )
    #expect(try migrated.confirmedMediaCursor(callID: fixture.session.callID) == cursor)
    #expect(
      try migrated.database.access { try migrated.database.scalarInt("PRAGMA user_version") } == 3
    )
    #expect(try migrated.masterUpload(callID: fixture.session.callID) == nil)
  }
}
