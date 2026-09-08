import AVFoundation
import Foundation
import Network
import Testing
import TrigoContracts

@testable import TrigoNative

private let localWorktree = "012345abcdef"
private let localNamespace = "00000000-0000-4000-8000-000000000054"
private let localToken = "trigo_v1_" + String(repeating: "1", count: 64)

private func localConfiguration(_ url: URL) throws -> LocalDevelopmentConfiguration {
  try .init(
    worktreeId: localWorktree,
    namespaceId: localNamespace,
    serverURL: url,
    ownerToken: localToken
  )
}
private func temporarySupport() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(
    path: "trigo-local-client-\(UUID())",
    directoryHint: .isDirectory
  )
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  return root
}

private struct LocalBridgeFixture: Decodable {
  let name: String
  let kind: String
  let json: String
  let valid: Bool
}

struct LocalDevelopmentTests {
  @Test func playbackRejectsRedirectsAndOversizedBodiesThroughTheRealSession() async throws {
    let redirected = try await LoopbackResponse.start(status: 200, body: "{}")
    defer { redirected.stop() }
    let destination = try #require(redirected.url)
    for (status, body, location, failure) in [
      (
        302, "", destination.absoluteString,
        CallPlaybackError.transport(code: "playback_server_unavailable", retry: .retryable)
      ),
      (200, String(repeating: "x", count: 65_537), nil, .invalidMedia),
      (401, "{}", nil, .accessBlocked),
    ] {
      let fixture = try await LoopbackResponse.start(status: status, body: body, location: location)
      defer { fixture.stop() }
      let url = try #require(fixture.url)
      let support = try temporarySupport()
      defer { try? FileManager.default.removeItem(at: support) }
      let connection = try await localPlaybackConnection(url: url, support: support)
      let transport = HTTPPlaybackTransport(
        connection: connection,
        archiveID: localNamespace,
        timeout: 2
      )
      await #expect(throws: failure) {
        try await transport.grant(
          callID: playbackCallID,
          operationID: UUID().uuidString.lowercased()
        )
      }
      let requests = await fixture.requests.values
      #expect(requests.count == 1)
      #expect(
        requests.first?.hasPrefix("POST /v1/calls/\(playbackCallID)/playback HTTP/1.1") == true
      )
      #expect(requests.first?.contains("Authorization: Bearer \(localToken)") == true)
    }
    #expect(await redirected.requests.count == 0)
  }

  @Test func playbackMediaUsesOnlyTheCapabilityAndRejectsAChangedArchiveBinding() async throws {
    let fixture = try await LoopbackResponse.start(status: 503, body: "{}")
    defer { fixture.stop() }
    let url = try #require(fixture.url)
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let connection = try await localPlaybackConnection(url: url, support: support)
    let binding = try #require(await connection.snapshot().binding)
    var grant = try await PlaybackTransportFixture()
      .grant(callID: playbackCallID, operationID: UUID().uuidString.lowercased()).grant
    grant.archiveId = localNamespace
    let access = PlaybackAccess(grant: grant, binding: binding)
    let transport = HTTPPlaybackTransport(
      connection: connection,
      archiveID: localNamespace,
      timeout: 2
    )
    await #expect(
      throws: CallPlaybackError.transport(code: "playback_server_unavailable", retry: .retryable)
    ) {
      try await transport.segment(access: access, index: 0)
    }
    let requests = await fixture.requests.values
    #expect(requests.count == 1)
    #expect(
      requests.first?
        .hasPrefix("GET /v1/calls/\(playbackCallID)/playback/\(grant.grantId)/segments/0 HTTP/1.1")
        == true
    )
    #expect(requests.first?.contains("Authorization: Bearer \(grant.token)") == true)
    #expect(requests.first?.contains(localToken) == false)
    let wrong = PlaybackAccess(
      grant: grant,
      binding: .init(
        serverURL: URL(string: "https://another.example.test")!,
        archiveId: localNamespace,
        stage: .dev
      )
    )
    await #expect(throws: CallPlaybackError.accessBlocked) {
      try await transport.segment(access: wrong, index: 0)
    }
    #expect(await fixture.requests.count == 1)
  }

  @Test func nativeFileBoundaryEnforcesSharedBridgeCorpus() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let corpus = try JSONDecoder()
      .decode(
        [LocalBridgeFixture].self,
        from: Data(
          contentsOf: root.appending(path: "packages/contracts/fixtures/structure-cases.json")
        )
      )
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let file = support.appending(path: "bridge.json")
    for fixture in corpus where fixture.kind == "LocalDevelopmentBridge" {
      try Data(fixture.json.utf8).write(to: file)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      do {
        let configuration = try LocalDevelopmentConfiguration.load(
          url: file,
          worktree: localWorktree,
          variant: .dev
        )
        #expect(fixture.valid, "Unexpected acceptance: \(fixture.name)")
        #expect(configuration.namespaceId == localNamespace)
      } catch {
        #expect(!fixture.valid, "Unexpected rejection: \(fixture.name): \(error)")
      }
    }
  }

  @Test func loopbackPolicyIsExplicitExactAndIndependentOfOrdinaryDev() throws {
    let url = try #require(URL(string: "http://127.0.0.1:19371"))
    let policy = ServerTransportPolicy.localDevelopment(try localConfiguration(url))
    #expect(policy.canonicalURL(url.absoluteString) == url)
    #expect(ServerTransportPolicy.httpsOnly.canonicalURL(url.absoluteString) == nil)
    #expect(ServerTransportPolicy.httpsOnly.canonicalURL("https://cloud.example") != nil)
    for denied in [
      "http://localhost:19371", "http://[::1]:19371", "http://127.0.0.2:19371",
      "http://127.1:19371", "http://2130706433:19371", "http://127.0.0.1:19372",
      "http://127.0.0.1:19371/", "http://127.0.0.1:19371?x=1", "http://127.0.0.1:19371#fragment",
      "http://user@127.0.0.1:19371", "http://192.168.1.1:19371", "https://cloud.example",
    ] {
      #expect(policy.canonicalURL(denied) == nil)
    }
    for denied in [
      "http://localhost:19371", "http://[::1]:19371", "http://127.0.0.1:80",
      "https://127.0.0.1:19371", "http://127.0.0.1:19371/",
    ] {
      #expect(throws: (any Error).self) {
        try localConfiguration(try #require(URL(string: denied)))
      }
    }
  }

  @Test func localNamespaceCannotReplaceOrdinaryCloudOrPersonalState() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let local = try localConfiguration(try #require(URL(string: "http://127.0.0.1:19371")))
    let offline = try AppNamespace(
      variant: .dev,
      worktree: localWorktree,
      support: support,
      localDevelopment: local
    )
    let dev = try AppNamespace(variant: .dev, worktree: localWorktree, support: support)
    let personal = try AppNamespace(variant: .personal, worktree: localWorktree, support: support)
    #expect(Set([offline.archive, dev.archive, personal.archive]).count == 3)
    #expect(Set([offline.connection, dev.connection, personal.connection]).count == 3)
    #expect(Set([offline.journal, dev.journal, personal.journal]).count == 3)
    #expect(
      Set([offline.keychainService, dev.keychainService, personal.keychainService]).count == 3
    )
    #expect(Set([offline.preferences, dev.preferences, personal.preferences]).count == 3)
    #expect(throws: (any Error).self) {
      try AppNamespace(
        variant: .personal,
        worktree: localWorktree,
        support: support,
        localDevelopment: local
      )
    }
    #expect(throws: (any Error).self) {
      try AppNamespace(
        variant: .dev,
        worktree: "abcdef012345",
        support: support,
        localDevelopment: local
      )
    }
  }

  @Test func bridgeRejectsUnsafeFilesAndMismatchedWorktrees() throws {
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let file = support.appending(path: "bridge.json")
    let bridge = LocalDevelopmentBridge(
      formatVersion: 1,
      worktreeId: localWorktree,
      namespaceId: localNamespace,
      serverURL: "http://127.0.0.1:19371",
      ownerToken: localToken
    )
    try Contract.encode(bridge).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    #expect(
      try LocalDevelopmentConfiguration.load(url: file, worktree: localWorktree, variant: .dev)
        .namespaceId == localNamespace
    )
    #expect(throws: (any Error).self) {
      try LocalDevelopmentConfiguration.load(url: file, worktree: "abcdef012345", variant: .dev)
    }
    #expect(throws: (any Error).self) {
      try LocalDevelopmentConfiguration.load(url: file, worktree: localWorktree, variant: .personal)
    }
    let link = support.appending(path: "link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: (any Error).self) {
      try LocalDevelopmentConfiguration.load(url: link, worktree: localWorktree, variant: .dev)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) {
      try LocalDevelopmentConfiguration.load(url: file, worktree: localWorktree, variant: .dev)
    }
  }

  @Test func actualURLSessionClassifiesUnauthorizedIncompatibleAndUnavailableResponses()
    async throws
  {
    for (status, body, expected) in [
      (401, "{}", ConnectionIssue.unauthorized), (403, "{}", .unauthorized),
      (200, "{\"schemaVersion\":2}", .incompatible), (404, "{}", .incompatible),
      (501, "{}", .unreachable), (503, "{}", .unreachable),
    ] {
      let fixture = try await LoopbackResponse.start(status: status, body: body)
      let url = try #require(fixture.url)
      let client = HTTPSStatusClient(
        timeout: 2,
        transportPolicy: .localDevelopment(try localConfiguration(url))
      )
      await #expect(throws: expected) { try await client.fetch(serverURL: url, token: localToken) }
      fixture.stop()
    }
  }

  @Test func persistentLocalBindingRetainsRecordingEligibilityWhenTransportGoesOffline()
    async throws
  {
    let body = """
      {"schemaVersion":1,"apiVersion":1,"archiveId":"\(localNamespace)","stage":"dev","readiness":{"archive":"ready","ownerAuthentication":"ready","transcription":"not_verified","callOperations":"unavailable"},"errors":[]}
      """
    let fixture = try await LoopbackResponse.start(status: 200, body: body)
    let url = try #require(fixture.url)
    let configuration = try localConfiguration(url)
    let policy = ServerTransportPolicy.localDevelopment(configuration)
    let support = try temporarySupport()
    defer {
      fixture.stop()
      try? FileManager.default.removeItem(at: support)
    }
    let namespace = try AppNamespace(
      variant: .dev,
      worktree: localWorktree,
      support: support,
      localDevelopment: configuration
    )
    let credentials = DisposableLocalCredentials()
    func connection() -> ServerConnection {
      ServerConnection(
        expectedStage: .dev,
        metadataStore: FileConnectionMetadataStore(
          url: namespace.connection,
          transportPolicy: policy
        ),
        credentialStore: credentials,
        statusClient: HTTPSStatusClient(timeout: 1, transportPolicy: policy),
        transportPolicy: policy
      )
    }
    let paired = await connection().connect(serverURL: url.absoluteString, token: localToken)
    #expect(paired.binding?.archiveId == localNamespace)
    fixture.stop()
    let restored = await connection().restore()
    #expect(restored.binding == paired.binding)
    #expect(restored.health == .blocked(.unreachable))
    #expect(restored.recordingEligibility == .eligible(archiveId: localNamespace))
  }

  @Test func realTransportRejectsRedirectsAndForbiddenOriginsBeforeSendingCredentials() async throws
  {
    let fixture = try await LoopbackResponse.start(
      status: 302,
      body: "",
      location: "http://127.0.0.1:19372/v1/status"
    )
    defer { fixture.stop() }
    let url = try #require(fixture.url)
    let client = HTTPSStatusClient(
      timeout: 2,
      transportPolicy: .localDevelopment(try localConfiguration(url))
    )
    await #expect(throws: ConnectionIssue.unreachable) {
      try await client.fetch(serverURL: url, token: localToken)
    }
    await #expect(throws: ConnectionIssue.invalidServerURL) {
      try await HTTPSStatusClient().fetch(serverURL: url, token: localToken)
    }
    let denied = try #require(URL(string: "http://127.0.0.1:19372"))
    await #expect(throws: ConnectionIssue.invalidServerURL) {
      try await client.fetch(serverURL: denied, token: localToken)
    }
    #expect(await fixture.requests.count == 1)
  }
}

/// Opt-in real Worker transport. Credentials are an isolated in-memory adapter; metadata uses the real file store.
struct LocalServerAcceptanceTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIGO_LOCAL_ACCEPTANCE_CONFIG"] != nil))
  @MainActor func pairsRestoresAndRejectsWrongCredentialsAgainstTheActualLocalComposition()
    async throws
  {
    let path = try #require(ProcessInfo.processInfo.environment["TRIGO_LOCAL_ACCEPTANCE_CONFIG"])
    let worktree = try #require(
      ProcessInfo.processInfo.environment["TRIGO_LOCAL_ACCEPTANCE_WORKTREE"]
    )
    let config = try LocalDevelopmentConfiguration.load(
      url: URL(fileURLWithPath: path),
      worktree: worktree,
      variant: .dev
    )
    let support = try temporarySupport()
    defer { try? FileManager.default.removeItem(at: support) }
    let namespace = try AppNamespace(
      variant: .dev,
      worktree: worktree,
      support: support,
      localDevelopment: config
    )
    let policy = ServerTransportPolicy.localDevelopment(config)
    let credentials = DisposableLocalCredentials()
    func connection() -> ServerConnection {
      ServerConnection(
        expectedStage: .dev,
        metadataStore: FileConnectionMetadataStore(
          url: namespace.connection,
          transportPolicy: policy
        ),
        credentialStore: credentials,
        statusClient: HTTPSStatusClient(timeout: 2, transportPolicy: policy),
        transportPolicy: policy
      )
    }
    let first = connection()
    #expect(await first.snapshot().recordingEligibility == .requiresSetup)
    let unauthorized = await first.connect(
      serverURL: config.serverURL.absoluteString,
      token: "invalid"
    )
    #expect(unauthorized.binding == nil)
    #expect(unauthorized.lastAttemptIssue == .unauthorized)
    let paired = await first.connect(
      serverURL: config.serverURL.absoluteString,
      token: config.ownerToken
    )
    #expect(paired.binding?.archiveId == config.namespaceId)
    #expect(paired.recordingEligibility == .eligible(archiveId: config.namespaceId))
    guard case .connected(let status) = paired.health else {
      Issue.record("Local status did not authenticate")
      return
    }
    #expect(status.readiness.callOperations == .ready)
    let restored = await connection().restore()
    #expect(restored.binding == paired.binding)
    #expect(restored.health == paired.health)
    let capture = try repositorySession(namespace.archive, archiveID: config.namespaceId)
    try await capture.prepare()
    let repository = try LocalRepository(root: namespace.archive, archiveID: config.namespaceId)
    let writer = try RecoverableMediaMaster(
      directory: capture.mediaDirectory,
      identity: capture.mediaMasterIdentity
    )
    for second in 0..<31 {
      var samples = [Int16](repeating: 0, count: 32_000)
      for frame in 0..<16_000 {
        samples[frame * 2] = Int16(1000 + second * 100)
        samples[frame * 2 + 1] = Int16(-2000 - second * 100)
      }
      try repository.commitMediaProgress(
        writer.append(
          interleaved: samples,
          microphoneIntervals: [
            .init(startMs: second * 1000, endMs: (second + 1) * 1000, state: .recorded)
          ],
          applicationIntervals: [
            .init(startMs: second * 1000, endMs: (second + 1) * 1000, state: .recorded)
          ]
        )
      )
    }
    let master = try writer.finish()
    _ = try await repository.completeCapture(capture, master: master, reason: "process_terminated")
    let fault = MasterUploadFault(.beforeReceiptCommit)
    let uploads = MasterUploadCoordinator(
      repository: repository,
      transport: HTTPMasterUploadTransport(connection: first, archiveID: config.namespaceId),
      interruption: fault.callAsFunction
    )
    #expect(try await uploads.runPass().failures.count == 1)
    #expect(try repository.verifiedMasterReceipt(callID: capture.callID) == nil)
    #expect(
      FileManager.default.fileExists(
        atPath: capture.mediaDirectory.appendingPathComponent("master.caf").path
      )
    )
    let resumedConnection = connection()
    _ = await resumedConnection.restore()
    let resumed = MasterUploadCoordinator(
      repository: try LocalRepository(root: namespace.archive, archiveID: config.namespaceId),
      transport: HTTPMasterUploadTransport(
        connection: resumedConnection,
        archiveID: config.namespaceId
      )
    )
    #expect(try await resumed.runPass().storedCallIDs == [capture.callID])
    #expect(
      try repository.verifiedMasterReceipt(callID: capture.callID)?.value.masterSHA256
        == master.sha256
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: capture.mediaDirectory.appendingPathComponent("master.caf").path
      )
    )
    let playbackTransport = HTTPPlaybackTransport(
      connection: resumedConnection,
      archiveID: config.namespaceId
    )
    let engine = AVAudioEngine()
    let audio = AVPlaybackAudioOutput(engine: engine)
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    let player = CallAudioPlayer(transport: playbackTransport, output: audio)
    defer { player.clear() }
    await player.load(callID: capture.callID)
    #expect(player.state.phase == .paused && player.state.durationMs == 31_000)
    for (position, left, right) in [(30_500, 4000, -5000), (250, 1000, -2000)] {
      await player.seek(positionMs: position)
      #expect(player.state.phase == .paused && player.state.positionMs == position)
      await player.play()
      #expect(player.state.phase == .playing)
      let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
      #expect(try engine.renderOffline(128, to: buffer) == .success)
      let channels = try #require(buffer.floatChannelData)
      for frame in [0, 64, 127] {
        #expect(abs(channels[0][frame] - Float(left) / 32768) < 0.0001)
        #expect(abs(channels[1][frame] - Float(right) / 32768) < 0.0001)
      }
      player.pause()
    }
    player.clear(callID: capture.callID)
    #expect(player.state.phase == .idle && !engine.isRunning)
    let rejected = await first.connect(serverURL: config.serverURL.absoluteString, token: "invalid")
    #expect(rejected.binding == paired.binding)
    #expect(rejected.lastAttemptIssue == .unauthorized)
    #expect(rejected.recordingEligibility == paired.recordingEligibility)
    let metadata = try await FileConnectionMetadataStore(
      url: namespace.connection,
      transportPolicy: policy
    )
    .load()
    #expect(metadata?.pending == nil)
    #expect(metadata?.retiredCredentialAccounts == [])
    await #expect(throws: (any Error).self) {
      try await FileConnectionMetadataStore(url: namespace.connection).load()
    }
    print(
      "LOCAL_CLIENT_ACCEPTANCE actual URLSession + pairing + authenticated upload/finalization + lost local receipt commit + replay + verified cleanup + server playback/seek + stereo AVAudioEngine rendering + isolated namespace passed"
    )
  }
}

private actor DisposableLocalCredentials: CredentialStoring {
  private var items: [String: String] = [:]
  func load(account: String) -> String? { items[account] }
  func save(token: String, account: String) { items[account] = token }
  func delete(account: String) { items.removeValue(forKey: account) }
}

private struct LocalPlaybackStatus: ServerStatusFetching {
  func fetch(serverURL: URL, token: String) async throws -> ServerStatus {
    ServerStatus(
      schemaVersion: 1,
      apiVersion: 1,
      archiveId: localNamespace,
      stage: .dev,
      readiness: ServerReadiness(
        archive: "ready",
        ownerAuthentication: "ready",
        transcription: .notVerified,
        callOperations: .ready
      ),
      errors: []
    )
  }
}

private func localPlaybackConnection(url: URL, support: URL) async throws -> ServerConnection {
  let policy = ServerTransportPolicy.localDevelopment(try localConfiguration(url))
  let connection = ServerConnection(
    expectedStage: .dev,
    metadataStore: FileConnectionMetadataStore(
      url: support.appending(path: "connection.json"),
      transportPolicy: policy
    ),
    credentialStore: DisposableLocalCredentials(),
    statusClient: LocalPlaybackStatus(),
    transportPolicy: policy
  )
  #expect(
    await connection.connect(serverURL: url.absoluteString, token: localToken)
      .serverOperationsAvailable
  )
  return connection
}

private actor CapturedLocalRequests {
  var values: [String] = []
  var count: Int { values.count }
  func append(_ value: String) { values.append(value) }
}

private final class LoopbackResponse: @unchecked Sendable {
  let listener: NWListener
  let requests: CapturedLocalRequests
  var url: URL? { listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)") } }
  init(listener: NWListener, requests: CapturedLocalRequests) {
    self.listener = listener
    self.requests = requests
  }
  func stop() { listener.cancel() }

  static func start(
    status: Int,
    body: String,
    location: String? = nil
  ) async throws
    -> LoopbackResponse
  {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let requests = CapturedLocalRequests()
    let headers =
      "HTTP/1.1 \(status) Test\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
      + (location.map { "Location: \($0)\r\n" } ?? "") + "\r\n"
    let response = Data((headers + body).utf8)
    listener.newConnectionHandler = { connection in
      connection.start(queue: .global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
        Task {
          await requests.append(data.map { String(decoding: $0, as: UTF8.self) } ?? "")
          connection.send(
            content: response,
            completion: .contentProcessed { _ in connection.cancel() }
          )
        }
      }
    }
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      listener.stateUpdateHandler = { state in
        switch state {
        case .ready: continuation.resume()
        case .failed(let error): continuation.resume(throwing: error)
        default: break
        }
      }
      listener.start(queue: .global())
    }
    return LoopbackResponse(listener: listener, requests: requests)
  }
}
