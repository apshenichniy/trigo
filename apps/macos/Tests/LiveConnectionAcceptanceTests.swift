import Foundation
import Testing

@testable import TrigoNative

@Suite(.serialized)
struct LiveConnectionAcceptanceTests {
  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["TRIGO_LIVE_HANDOFF_PATH"] != nil))
  func pairAndRestoreThroughProductionPersistence() async throws {
    let environment = ProcessInfo.processInfo.environment
    let handoffPath = try #require(environment["TRIGO_LIVE_HANDOFF_PATH"])
    let serverURL = try #require(environment["TRIGO_LIVE_SERVER_URL"])
    let archiveId = try #require(environment["TRIGO_LIVE_ARCHIVE_ID"])
    let worktree = try #require(environment["TRIGO_LIVE_WORKTREE_ID"])
    let expectedTarget = OwnerHandoffTarget(
      accountId: try #require(environment["TRIGO_LIVE_ACCOUNT_ID"]),
      databaseName: try #require(environment["TRIGO_LIVE_DATABASE_NAME"]),
      deploymentIdentity: try #require(environment["TRIGO_LIVE_DEPLOYMENT_IDENTITY"]))
    let rawExpectedGeneration = try #require(environment["TRIGO_LIVE_EXPECTED_GENERATION"])
    let expectedGeneration = try #require(Int(rawExpectedGeneration))
    let handoff = try readValidatedHandoff(
      at: URL(filePath: handoffPath), expectedTarget: expectedTarget,
      expectedGeneration: expectedGeneration)
    guard let canonicalServerURL = ServerConnection.canonicalServerURL(serverURL),
      archiveId.range(of: canonicalUUIDPattern, options: .regularExpression) != nil
    else { throw LiveAcceptanceError.invalidSelector }
    let status = try await HTTPSStatusClient().fetch(
      serverURL: canonicalServerURL, token: handoff.token)
    guard status.stage == .dev, status.archiveId == archiveId else {
      throw LiveAcceptanceError.unexpectedServer
    }
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

  @Test func protectedHandoffReaderRejectsUnsafeOrMismatchedInput() throws {
    let root = FileManager.default.temporaryDirectory.appending(
      path: "trigo-live-handoff-\(UUID())", directoryHint: .isDirectory)
    let handoff = root.appending(path: "handoff.json")
    let symbolicLink = root.appending(path: "handoff-link.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try validHandoffData().write(to: handoff, options: .withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: handoff.path)

    #expect(throws: LiveAcceptanceError.unsafeHandoff) {
      try readValidatedHandoff(at: handoff, expectedTarget: .fixture, expectedGeneration: 3)
    }

    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: handoff.path)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: handoff)
    #expect(throws: LiveAcceptanceError.unsafeHandoff) {
      try readValidatedHandoff(at: symbolicLink, expectedTarget: .fixture, expectedGeneration: 3)
    }
    #expect(throws: LiveAcceptanceError.invalidHandoff) {
      try readValidatedHandoff(
        at: handoff,
        expectedTarget: OwnerHandoffTarget(
          accountId: String(repeating: "f", count: 32), databaseName: "trigo-dev-catalog",
          deploymentIdentity: "trigo-dev-api:different"),
        expectedGeneration: 3)
    }
  }
}

private struct OwnerHandoff: Decodable {
  let schemaVersion: Int
  let stage: String
  let target: OwnerHandoffTarget
  let operationId: String
  let createdAt: String
  let action: String
  let expectedGeneration: Int
  let token: String
}

private struct OwnerHandoffTarget: Codable, Equatable {
  let accountId: String
  let databaseName: String
  let deploymentIdentity: String
}

private enum LiveAcceptanceError: Error, Equatable {
  case unsafeHandoff
  case invalidHandoff
  case invalidSelector
  case unexpectedServer
}

extension OwnerHandoffTarget {
  fileprivate static let fixture = OwnerHandoffTarget(
    accountId: String(repeating: "0", count: 32), databaseName: "trigo-dev-catalog",
    deploymentIdentity: "trigo-dev-api:0000000000000000")
}

private func validHandoffData() throws -> Data {
  try JSONSerialization.data(
    withJSONObject: [
      "schemaVersion": 1,
      "stage": "dev",
      "target": [
        "accountId": OwnerHandoffTarget.fixture.accountId,
        "databaseName": OwnerHandoffTarget.fixture.databaseName,
        "deploymentIdentity": OwnerHandoffTarget.fixture.deploymentIdentity,
      ],
      "operationId": "00000000-0000-4000-8000-000000000031",
      "createdAt": "2026-09-05T00:00:00Z",
      "action": "rotate",
      "expectedGeneration": 3,
      "token": "trigo_v1_\(String(repeating: "0", count: 64))",
    ])
}

private let canonicalUUIDPattern =
  "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"

private func readValidatedHandoff(
  at url: URL, expectedTarget: OwnerHandoffTarget, expectedGeneration: Int
) throws -> OwnerHandoff {
  let values = try url.resourceValues(forKeys: [
    .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
  ])
  let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
  guard values.isRegularFile == true, values.isSymbolicLink != true,
    (values.fileSize ?? 0) <= 65_536, attributes[.posixPermissions] as? Int == 0o600
  else { throw LiveAcceptanceError.unsafeHandoff }

  let data = try Data(contentsOf: url)
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    Set(object.keys)
      == Set([
        "schemaVersion", "stage", "target", "operationId", "createdAt", "action",
        "expectedGeneration", "token",
      ]),
    let targetObject = object["target"] as? [String: Any],
    Set(targetObject.keys) == Set(["accountId", "databaseName", "deploymentIdentity"])
  else { throw LiveAcceptanceError.invalidHandoff }

  let handoff = try JSONDecoder().decode(OwnerHandoff.self, from: data)
  let timestamp = ISO8601DateFormatter()
  timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  let hasValidTimestamp = timestamp.date(from: handoff.createdAt) != nil
  guard handoff.schemaVersion == 1, handoff.stage == "dev", handoff.action == "rotate",
    handoff.expectedGeneration == expectedGeneration, expectedGeneration >= 1,
    handoff.target == expectedTarget,
    handoff.target.accountId.range(
      of: "^[0-9a-f]{32}$", options: .regularExpression) != nil,
    !handoff.target.databaseName.isEmpty, !handoff.target.deploymentIdentity.isEmpty,
    handoff.operationId.range(of: canonicalUUIDPattern, options: .regularExpression) != nil,
    hasValidTimestamp,
    handoff.token.range(of: "^trigo_v1_[0-9a-f]{64}$", options: .regularExpression) != nil
  else { throw LiveAcceptanceError.invalidHandoff }
  return handoff
}

extension ConnectionHealth {
  fileprivate var isConnected: Bool {
    if case .connected = self { return true }
    return false
  }
}
