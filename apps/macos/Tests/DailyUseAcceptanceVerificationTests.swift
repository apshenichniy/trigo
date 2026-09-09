import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@MainActor @Suite struct DailyUseAcceptanceVerificationTests {
  @Test func fullReaderProofTraversesEveryPageAndRejectsChangedEvidence() async throws {
    let fixture = try await uploadedSyncFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let repository = fixture.repository
    let call = try await repository.call(callID: fixture.session.callID)
    var revision = try Contract.decode(TranscriptRevision.self, bytes: syncRevision(for: call))
      .value
    let first = try #require(revision.turns.first)
    revision.turns = (0..<225)
      .map { index in
        var turn = first
        turn.turnId = UUID().uuidString.lowercased()
        turn.startMs = index * 4
        turn.endMs = (index + 1) * 4
        turn.text = "Controlled reader passage \(index)"
        turn.words = []
        return turn
      }
    let bytes = try Contract.encode(revision)
    let (result, provenance) = try syncResult(bytes)
    _ = try await repository.importAvailableResult(
      result,
      callID: call.callId,
      revision: bytes,
      provenance: provenance
    )
    let preferencesName = fixture.root.lastPathComponent
    let preferences = try #require(UserDefaults(suiteName: preferencesName))
    defer { preferences.removePersistentDomain(forName: preferencesName) }
    let player = CallAudioPlayer(
      transport: PlaybackTransportFixture(),
      output: PlaybackOutputFixture()
    )
    let reader = LibraryModel(preferences: preferences) {
      .init(repository: repository, player: player, retry: { _ in })
    }
    defer { reader.close() }
    await reader.refresh()
    #expect(reader.turns.count == 100 && reader.hasMoreTurns)
    let passages = try await dailyUseReaderPassages(reader, revision: revision)
    #expect(passages.count == 225 && !reader.hasMoreTurns)
    #expect(passages.last?.turnID == revision.turns.last?.turnId)
    revision.turns[224].text = "Unretained changed evidence"
    await #expect(throws: DailyUseAcceptanceFailure.self) {
      try await dailyUseReaderPassages(reader, revision: revision)
    }
  }
}
