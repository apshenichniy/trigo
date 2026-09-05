import Foundation
import Testing

@testable import TrigoNative

@Suite(.serialized)
struct LiveConnectionAcceptanceTests {
  @Test(
    .enabled(
      if: ProcessInfo.processInfo.environment["TRIGO_LIVE_HANDOFF_PATH"] != nil
        && ProcessInfo.processInfo.environment["TRIGO_LIVE_SERVER_URL"] != nil
        && ProcessInfo.processInfo.environment["TRIGO_LIVE_ARCHIVE_ID"] != nil
        && ProcessInfo.processInfo.environment["TRIGO_LIVE_WORKTREE_ID"] != nil))
  func pairAndRestoreThroughProductionPersistence() async throws {
    let environment = ProcessInfo.processInfo.environment
    let handoffPath = try #require(environment["TRIGO_LIVE_HANDOFF_PATH"])
    let serverURL = try #require(environment["TRIGO_LIVE_SERVER_URL"])
    let archiveId = try #require(environment["TRIGO_LIVE_ARCHIVE_ID"])
    let worktree = try #require(environment["TRIGO_LIVE_WORKTREE_ID"])
    let handoff = try JSONDecoder().decode(
      OwnerHandoff.self, from: Data(contentsOf: URL(filePath: handoffPath)))
    #expect(handoff.schemaVersion == 1)
    #expect(handoff.stage == "dev")
    let support = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let namespace = try AppNamespace(variant: .dev, worktree: worktree, support: support)

    let connection = ServerConnection.live(namespace: namespace, variant: .dev)
    let connected = await connection.connect(serverURL: serverURL, token: handoff.token)
    #expect(connected.binding?.archiveId == archiveId)
    #expect(connected.health.isConnected)
    #expect(connected.recordingEligibility == .eligible(archiveId: archiveId))

    let replaced = await connection.connect(serverURL: serverURL, token: handoff.token)
    #expect(replaced.binding == connected.binding)
    #expect(replaced.health.isConnected)
    #expect(replaced.lastAttemptIssue == nil)

    let rejected = await connection.connect(
      serverURL: serverURL, token: "trigo-invalid-acceptance-token")
    #expect(rejected.binding == replaced.binding)
    #expect(rejected.lastAttemptIssue == .unauthorized)
    #expect(rejected.recordingEligibility == .eligible(archiveId: archiveId))

    let relaunched = ServerConnection.live(namespace: namespace, variant: .dev)
    let restored = await relaunched.restore()
    #expect(restored.binding == replaced.binding)
    #expect(restored.health.isConnected)
    #expect(restored.recordingEligibility == .eligible(archiveId: archiveId))

    let metadata = try await FileConnectionMetadataStore(url: namespace.connection).load()
    #expect(metadata?.pending == nil)
    #expect(metadata?.retiredCredentialAccounts == [])
    let attributes = try FileManager.default.attributesOfItem(atPath: namespace.connection.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }
}

private struct OwnerHandoff: Decodable {
  let schemaVersion: Int
  let stage: String
  let token: String
}

extension ConnectionHealth {
  fileprivate var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}
