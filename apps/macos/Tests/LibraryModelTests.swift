import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@MainActor @Suite struct LibraryModelTests {
  @Test func metadataProjectionGroupsLocalDaysAndRetainsSelectionAcrossInsertAndRelaunch()
    async throws
  {
    let root = repositoryRoot("library-days")
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = try await seedRepositoryCall(root: root, finalized: true)
    let preferences = UserDefaults(suiteName: root.lastPathComponent)!
    defer { preferences.removePersistentDomain(forName: root.lastPathComponent) }
    var source = try await repository.call(callID: repositoryCallID)
    source.callId = "00000000-0000-4000-8000-000000000099"
    source.startedAt = "2026-09-08T23:30:00.000Z"
    source.endedAt = "2026-09-08T23:30:01.000Z"
    _ = try await repository.publishManifest(Contract.encode(source))
    let model = makeModel(repository, preferences: preferences)
    var madrid = Calendar(identifier: .gregorian)
    madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!
    await model.refresh(now: LibraryDate.date("2026-09-09T00:00:00Z"), calendar: madrid)
    #expect(model.failure == nil)
    #expect(model.calls.first?.callID == source.callId)
    #expect(model.days.first?.title == "Today")
    #expect(model.selectedCallID == source.callId)
    model.selectCall(repositoryCallID)
    source.callId = "00000000-0000-4000-8000-000000000098"
    source.startedAt = "2026-09-09T00:00:00.000Z"
    source.endedAt = "2026-09-09T00:00:01.000Z"
    _ = try await repository.publishManifest(Contract.encode(source))
    await model.refresh(now: LibraryDate.date("2026-09-10T00:00:00Z"), calendar: madrid)
    #expect(model.selectedCallID == repositoryCallID)
    #expect(model.calls.first?.callID == source.callId)
    #expect(model.days.first?.title == "Yesterday")
    var losAngeles = Calendar(identifier: .gregorian)
    losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    await model.refresh(now: LibraryDate.date("2026-09-09T00:00:00Z"), calendar: losAngeles)
    #expect(model.days.first?.title == "Today")
    #expect(model.selectedCallID == repositoryCallID)
    let reopened = makeModel(repository, preferences: preferences)
    await reopened.refresh()
    #expect(reopened.selectedCallID == repositoryCallID)
    #expect(reopened.selectedCall?.sourceDescription == model.selectedCall?.sourceDescription)
    #expect(reopened.playback.phase == .idle)
  }

  @Test func importedRevisionRemainsSelectedWhileNewResultAndUnicodeGroupAreCommitted() async throws
  {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let first = try await importRevision(repository, callID: callID)
    let preferences = UserDefaults(suiteName: fixture.root.lastPathComponent)!
    defer { preferences.removePersistentDomain(forName: fixture.root.lastPathComponent) }
    let model = makeModel(repository, preferences: preferences)
    await model.refresh()
    #expect(model.selectedRevisionID == first.value.revisionId)
    #expect(model.turns.map(\.turnID) == first.value.turns.map(\.turnId))
    #expect(
      model.speakers.map(\.neutralLabel).count == Set(model.speakers.map(\.neutralLabel)).count
    )
    let second = try await importRevision(repository, callID: callID, generation: 2)
    await model.refresh()
    #expect(model.selectedRevisionID == first.value.revisionId)
    #expect(model.revisions.count == 2)
    let call = try #require(model.selectedCall)
    let edit = SpeakerAnnotationEdit(
      operationID: UUID().uuidString.lowercased(),
      callID: callID,
      revisionID: first.value.revisionId,
      expectedDocumentVersion: call.documentVersion,
      mutation: .group(
        groupID: UUID().uuidString.lowercased(),
        displayName: "Zoë · Олена 🎙️",
        speakerIDs: Array(first.value.speakers.prefix(2).map(\.speakerId))
      )
    )
    try await model.save(edit)
    try await model.save(edit)
    #expect(model.speakers.prefix(2).allSatisfy { $0.displayName == "Zoë · Олена 🎙️" })
    #expect(model.selectedRevisionID == first.value.revisionId)
    #expect(try await repository.call(callID: callID).activeRevisionId == second.value.revisionId)
    #expect(
      try await repository.transcriptRevisionBytes(
        callID: callID,
        revisionID: first.value.revisionId
      ) == first.storedBytes
    )
    #expect(model.selectedCall?.lifecycle.replica.state == .pending)
    #expect(!LibraryCallStatus(try #require(model.selectedCall)).title.hasPrefix("Ready"))
  }

  @Test func processingFailureKeepsTextAndConflictsAppearWithoutDocumentVersionChange() async throws
  {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let first = try await importRevision(repository, callID: callID)
    try await confirmPendingReplicas(repository, callID: callID)
    let remoteBase = try await syncReplicaContents(repository, callID: callID)
    let preferences = UserDefaults(suiteName: fixture.root.lastPathComponent)!
    defer { preferences.removePersistentDomain(forName: fixture.root.lastPathComponent) }
    let model = makeModel(repository, preferences: preferences)
    await model.refresh()
    _ = try await repository.updateLifecycle(callID: callID) { state in
      state.transcription = .init(
        state: .failed,
        failure: try .init(code: "asr_attempt_limit", retry: .afterCorrection)
      )
    }
    await model.refresh()
    #expect(model.turns.map(\.text) == first.value.turns.map(\.text))
    #expect(
      LibraryCallStatus(try #require(model.selectedCall)).title == "Transcription needs attention"
    )
    _ = try await repository.setSpeakerName(
      "Local",
      callID: callID,
      revisionID: first.value.revisionId,
      speakerID: first.value.speakers[0].speakerId
    )
    await model.refresh()
    let version = try #require(model.selectedCall?.documentVersion)
    var remote = try Contract.decodeCallSnapshot(remoteBase.document).value
    remote.documentVersion += 1
    remote.speakerNames[first.value.revisionId] = [first.value.speakers[0].speakerId: "Server"]
    try await repository.recordReplicaConflict(
      .init(
        document: Contract.encode(remote),
        audioManifest: remoteBase.audioManifest,
        revisions: remoteBase.revisions,
        provenance: remoteBase.provenance,
        receipt: remoteBase.receipt
      )
    )
    await model.refresh()
    #expect(model.selectedCall?.documentVersion == version)
    #expect(model.conflicts.count == 1)
    #expect(model.conflicts.first?.server.names[first.value.speakers[0].speakerId] == "Server")
    #expect(model.turns.map(\.turnID) == first.value.turns.map(\.turnId))
  }

  @Test func timestampPlaybackRenewsAfterCleanupAndRevisionChangesPauseAtSamePosition() async throws
  {
    let fixture = try await uploadedSyncFixture(seconds: 3)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let callID = fixture.session.callID
    let first = try await importRevision(repository, callID: callID)
    let second = try await importRevision(repository, callID: callID, generation: 2)
    let preferences = UserDefaults(suiteName: fixture.root.lastPathComponent)!
    defer { preferences.removePersistentDomain(forName: fixture.root.lastPathComponent) }
    let transport = PlaybackTransportFixture(durationMs: 3_000)
    let output = PlaybackOutputFixture()
    let player = CallAudioPlayer(transport: transport, output: output)
    let model = LibraryModel(preferences: preferences) {
      .init(repository: repository, player: player, retry: { _ in })
    }
    await model.refresh()
    #expect(model.selectedRevisionID == second.value.revisionId)
    await transport.expireOneSegment()
    await model.seek(to: 500, play: true)
    #expect(model.playback.phase == .playing)
    #expect(model.playback.positionMs == 500)
    #expect(output.buffers.first?.pcm.startFrame == 8_000)
    #expect(await transport.operations.count == 2)
    model.selectRevision(first.value.revisionId)
    #expect(model.playback.phase == .paused)
    #expect(model.playback.positionMs == 500)
    #expect(!output.playing)
    model.close()
    #expect(model.playback.positionMs == 500)
    model.selectCall(nil)
    #expect(model.playback.phase == .idle)
    #expect(output.buffers.isEmpty)
  }

  private func makeModel(_ repository: LocalRepository, preferences: UserDefaults) -> LibraryModel {
    let player = CallAudioPlayer(
      transport: PlaybackTransportFixture(),
      output: PlaybackOutputFixture()
    )
    return LibraryModel(preferences: preferences) {
      .init(repository: repository, player: player, retry: { _ in })
    }
  }

  private func importRevision(
    _ repository: LocalRepository,
    callID: String,
    generation: Int = 1
  ) async throws -> StoredDocument<TranscriptRevision> {
    let bytes = try syncRevision(for: await repository.call(callID: callID))
    let (result, provenance) = try syncResult(bytes, generation: generation)
    _ = try await repository.importAvailableResult(
      result,
      callID: callID,
      revision: bytes,
      provenance: provenance
    )
    return try Contract.decode(TranscriptRevision.self, bytes: bytes)
  }
}
