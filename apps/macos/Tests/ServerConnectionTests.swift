import Foundation
import Testing

@testable import TrigoNative

private let archiveA = "00000000-0000-4000-8000-000000000031"
private let archiveB = "00000000-0000-4000-8000-000000000032"

@Suite(.serialized)
struct ServerConnectionTests {
  @Test func firstConnectionPersistsAndRelaunchRestoresTheBinding() async throws {
    let metadata = MemoryConnectionMetadataStore()
    let credentials = MemoryCredentialStore()
    let status = StubStatusClient(responses: ["first": .success(.fixture(archiveId: archiveA))])
    let connection = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)

    let connected = await connection.connect(serverURL: "https://dev.example.test", token: "first")

    #expect(connected.binding?.archiveId == archiveA)
    #expect(connected.binding?.serverURL.absoluteString == "https://dev.example.test")
    #expect(connected.health == .connected(.fixture(archiveId: archiveA)))
    #expect(connected.recordingEligibility == .eligible(archiveId: archiveA))
    #expect(connected.lastAttemptIssue == nil)

    let relaunched = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    let restored = await relaunched.restore()

    #expect(restored.binding == connected.binding)
    #expect(restored.health == connected.health)
    #expect(restored.recordingEligibility == .eligible(archiveId: archiveA))
    #expect(await credentials.count == 1)
  }

  @Test func sameArchiveReplacementCommitsNewSettingsAndRetiresTheOldCredential() async {
    let metadata = MemoryConnectionMetadataStore()
    let credentials = MemoryCredentialStore()
    let status = StubStatusClient(responses: [
      "first": .success(.fixture(archiveId: archiveA)),
      "replacement": .success(.fixture(archiveId: archiveA)),
    ])
    let connection = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    _ = await connection.connect(serverURL: "https://old.example.test", token: "first")

    let replaced = await connection.connect(
      serverURL: "https://new.example.test", token: "replacement")

    #expect(replaced.binding?.archiveId == archiveA)
    #expect(replaced.binding?.serverURL.absoluteString == "https://new.example.test")
    #expect(replaced.lastAttemptIssue == nil)
    #expect(await credentials.values == ["replacement"])

    let relaunched = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    #expect(await relaunched.restore().binding == replaced.binding)
  }

  @Test(
    arguments: [
      ("wrong", StubStatusClient.Result.failure(.unauthorized)),
      ("offline", .failure(.unreachable)),
      ("legacy", .failure(.incompatible)),
      ("other", .success(.fixture(archiveId: archiveB))),
      ("personal", .success(.fixture(archiveId: archiveA, stage: .personal))),
    ])
  private func rejectedCandidatesPreserveThePriorConnection(
    token: String, response: StubStatusClient.Result
  ) async {
    let metadata = MemoryConnectionMetadataStore()
    let credentials = MemoryCredentialStore()
    let status = StubStatusClient(responses: [
      "first": .success(.fixture(archiveId: archiveA)), token: response,
    ])
    let connection = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    let original = await connection.connect(
      serverURL: "https://old.example.test", token: "first")

    let rejected = await connection.connect(
      serverURL: "https://candidate.example.test", token: token)

    #expect(rejected.binding == original.binding)
    #expect(rejected.health == original.health)
    #expect(rejected.lastAttemptIssue != nil)
    #expect(rejected.recordingEligibility == .eligible(archiveId: archiveA))
    #expect(await credentials.values == ["first"])

    let relaunched = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    #expect(await relaunched.restore().binding == original.binding)
  }

  @Test func metadataCommitFailureRollsBackTheCandidateAcrossRelaunch() async {
    let metadata = MemoryConnectionMetadataStore()
    let credentials = MemoryCredentialStore()
    let status = StubStatusClient(responses: [
      "first": .success(.fixture(archiveId: archiveA)),
      "replacement": .success(.fixture(archiveId: archiveA)),
    ])
    let connection = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    let original = await connection.connect(
      serverURL: "https://old.example.test", token: "first")
    await metadata.failSave(afterSuccessfulSaves: 1)

    let failed = await connection.connect(
      serverURL: "https://new.example.test", token: "replacement")

    #expect(failed.binding == original.binding)
    #expect(failed.lastAttemptIssue == .persistence)

    let relaunched = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    let restored = await relaunched.restore()
    #expect(restored.binding == original.binding)
    #expect(restored.recordingEligibility == .eligible(archiveId: archiveA))
    #expect(await credentials.values == ["first"])
  }

  @Test func credentialWriteFailureRollsBackPendingMetadata() async {
    let metadata = MemoryConnectionMetadataStore()
    let credentials = MemoryCredentialStore()
    let status = StubStatusClient(responses: [
      "first": .success(.fixture(archiveId: archiveA)),
      "replacement": .success(.fixture(archiveId: archiveA)),
    ])
    let connection = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    let original = await connection.connect(
      serverURL: "https://old.example.test", token: "first")
    await credentials.failNextSave()

    let failed = await connection.connect(
      serverURL: "https://new.example.test", token: "replacement")

    #expect(failed.binding == original.binding)
    #expect(failed.lastAttemptIssue == .persistence)
    #expect(await metadata.value?.pending == nil)
    #expect(await credentials.values == ["first"])
  }

  @Test func relaunchRollsBackAnInterruptedPendingReplacement() async throws {
    let old = StoredConnection.fixture(
      archiveId: archiveA, serverURL: "https://old.example.test", credentialAccount: "old")
    let pending = StoredConnection.fixture(
      archiveId: archiveA, serverURL: "https://new.example.test", credentialAccount: "pending")
    let metadata = MemoryConnectionMetadataStore(
      value: ConnectionMetadata(committed: old, pending: pending))
    let credentials = MemoryCredentialStore(values: ["old": "first", "pending": "replacement"])
    let status = StubStatusClient(responses: ["first": .success(.fixture(archiveId: archiveA))])

    let relaunched = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    let restored = await relaunched.restore()

    #expect(restored.binding?.serverURL.absoluteString == "https://old.example.test")
    #expect(await metadata.value?.pending == nil)
    #expect(await credentials.values == ["first"])
  }

  @Test func boundArchiveRemainsRecordingEligibleWhenServerIsUnavailableAfterRelaunch() async {
    let metadata = MemoryConnectionMetadataStore()
    let credentials = MemoryCredentialStore()
    let status = StubStatusClient(responses: ["first": .success(.fixture(archiveId: archiveA))])
    let connection = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    _ = await connection.connect(serverURL: "https://dev.example.test", token: "first")
    await status.set("first", result: .failure(.unreachable))

    let relaunched = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: credentials,
      statusClient: status)
    let restored = await relaunched.restore()

    #expect(restored.health == .blocked(.unreachable))
    #expect(restored.recordingEligibility == .eligible(archiveId: archiveA))
    #expect(restored.binding?.archiveId == archiveA)
  }

  @Test func missingCredentialPreservesBindingButBlocksServerOperations() async {
    let record = StoredConnection.fixture(
      archiveId: archiveA, serverURL: "https://dev.example.test", credentialAccount: "missing")
    let metadata = MemoryConnectionMetadataStore(value: ConnectionMetadata(committed: record))
    let connection = ServerConnection(
      expectedStage: .dev, metadataStore: metadata, credentialStore: MemoryCredentialStore(),
      statusClient: StubStatusClient())

    let restored = await connection.restore()

    #expect(restored.binding?.archiveId == archiveA)
    #expect(restored.health == .blocked(.credentialMissing))
    #expect(restored.recordingEligibility == .eligible(archiveId: archiveA))
  }

  @Test func invalidURLNeverReachesTheNetworkOrChangesTheBinding() async {
    let status = StubStatusClient()
    let connection = ServerConnection(
      expectedStage: .dev, metadataStore: MemoryConnectionMetadataStore(),
      credentialStore: MemoryCredentialStore(), statusClient: status)

    let snapshot = await connection.connect(serverURL: "http://example.test", token: "secret")

    #expect(snapshot.binding == nil)
    #expect(snapshot.recordingEligibility == .requiresSetup)
    #expect(snapshot.lastAttemptIssue == .invalidServerURL)
    #expect(await status.requestCount == 0)
  }

  @Test func nativeStatusDecoderUsesTheSharedContract() throws {
    let valid = Data(
      """
      {"schemaVersion":1,"apiVersion":1,"archiveId":"\(archiveA)","stage":"dev","readiness":{"archive":"ready","ownerAuthentication":"ready","transcription":"not_verified","callOperations":"unavailable"},"errors":[]}
      """.utf8)
    let invalid = Data(
      """
      {"schemaVersion":2,"apiVersion":1,"archiveId":"\(archiveA)","stage":"dev","readiness":{"archive":"ready","ownerAuthentication":"ready","transcription":"not_verified","callOperations":"unavailable"},"errors":[]}
      """.utf8)

    #expect(try ServerStatusDecoder.decode(valid).archiveId == archiveA)
    #expect(throws: ConnectionIssue.incompatible) {
      try ServerStatusDecoder.decode(invalid)
    }
  }

  @Test func keychainAdapterPersistsAndDeletesARealGenericPassword() async throws {
    let store = KeychainCredentialStore(service: "io.github.apshenichniy.trigo.tests.\(UUID())")
    let account = UUID().uuidString.lowercased()
    defer { Task { try? await store.delete(account: account) } }

    try await store.save(token: "keychain-token", account: account)
    #expect(try await store.load(account: account) == "keychain-token")
    try await store.delete(account: account)
    #expect(try await store.load(account: account) == nil)
  }
}

private actor MemoryConnectionMetadataStore: ConnectionMetadataStoring {
  var value: ConnectionMetadata?
  private var successfulSaves = 0
  private var savesUntilFailure: Int?

  init(value: ConnectionMetadata? = nil) { self.value = value }

  func load() throws -> ConnectionMetadata? { value }

  func save(_ value: ConnectionMetadata) throws {
    if savesUntilFailure == 0 {
      savesUntilFailure = nil
      throw TestFailure.injected
    }
    if savesUntilFailure != nil { savesUntilFailure! -= 1 }
    self.value = value
    successfulSaves += 1
  }

  func failSave(afterSuccessfulSaves count: Int) { savesUntilFailure = count }
}

private actor MemoryCredentialStore: CredentialStoring {
  private var storage: [String: String]
  private var shouldFailNextSave = false

  init(values: [String: String] = [:]) { storage = values }

  var values: [String] { storage.values.sorted() }
  var count: Int { storage.count }

  func load(account: String) throws -> String? { storage[account] }
  func save(token: String, account: String) throws {
    if shouldFailNextSave {
      shouldFailNextSave = false
      throw TestFailure.injected
    }
    storage[account] = token
  }
  func delete(account: String) throws { storage.removeValue(forKey: account) }
  func failNextSave() { shouldFailNextSave = true }
}

private actor StubStatusClient: ServerStatusFetching {
  typealias Result = Swift.Result<ServerStatus, ConnectionIssue>
  private var responses: [String: Result]
  private(set) var requestCount = 0

  init(responses: [String: Result] = [:]) { self.responses = responses }

  func fetch(serverURL: URL, token: String) async throws -> ServerStatus {
    requestCount += 1
    return try responses[token, default: .failure(.unreachable)].get()
  }

  func set(_ token: String, result: Result) { responses[token] = result }
}

private enum TestFailure: Error { case injected }

extension ServerStatus {
  fileprivate static func fixture(archiveId: String, stage: ServerStage = .dev) -> Self {
    ServerStatus(
      schemaVersion: 1, apiVersion: 1, archiveId: archiveId, stage: stage,
      readiness: ServerReadiness(
        archive: "ready", ownerAuthentication: "ready", transcription: .notVerified,
        callOperations: .unavailable), errors: [])
  }
}

extension StoredConnection {
  fileprivate static func fixture(
    archiveId: String, serverURL: String, credentialAccount: String
  ) -> Self {
    StoredConnection(
      serverURL: URL(string: serverURL)!, archiveId: archiveId, stage: .dev,
      credentialAccount: credentialAccount)
  }
}
