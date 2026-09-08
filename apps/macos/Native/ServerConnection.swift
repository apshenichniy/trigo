import Foundation

public enum ServerStage: String, Codable, Sendable {
  case dev
  case personal
}

extension AppVariant {
  public var serverStage: ServerStage { self == .dev ? .dev : .personal }
}

public enum TranscriptionReadiness: String, Codable, Sendable {
  case ready
  case notVerified = "not_verified"
  case unavailable
}

public enum CallOperationsReadiness: String, Codable, Sendable {
  case ready
  case unavailable
}

public struct ServerReadiness: Codable, Equatable, Sendable {
  public let archive: String
  public let ownerAuthentication: String
  public let transcription: TranscriptionReadiness
  public let callOperations: CallOperationsReadiness

  public init(
    archive: String,
    ownerAuthentication: String,
    transcription: TranscriptionReadiness,
    callOperations: CallOperationsReadiness
  ) {
    self.archive = archive
    self.ownerAuthentication = ownerAuthentication
    self.transcription = transcription
    self.callOperations = callOperations
  }
}

public struct ServerStatusNotice: Codable, Equatable, Sendable, Identifiable {
  public let code: String
  public let retry: String
  public let message: String
  public var id: String { code }
}

public struct ServerStatus: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let apiVersion: Int
  public let archiveId: String
  public let stage: ServerStage
  public let readiness: ServerReadiness
  public let errors: [ServerStatusNotice]

  public init(
    schemaVersion: Int,
    apiVersion: Int,
    archiveId: String,
    stage: ServerStage,
    readiness: ServerReadiness,
    errors: [ServerStatusNotice]
  ) {
    self.schemaVersion = schemaVersion
    self.apiVersion = apiVersion
    self.archiveId = archiveId
    self.stage = stage
    self.readiness = readiness
    self.errors = errors
  }
}

public struct ArchiveBinding: Equatable, Sendable {
  public let serverURL: URL
  public let archiveId: String
  public let stage: ServerStage

  public init(serverURL: URL, archiveId: String, stage: ServerStage) {
    self.serverURL = serverURL
    self.archiveId = archiveId
    self.stage = stage
  }
}

public enum CredentialAccessFailure: Equatable, Sendable {
  case interactionRequired, accessDenied, cancelled, invalid
  case unavailable(status: Int32?)

  public var title: String {
    switch self {
    case .interactionRequired: "Keychain needs attention"
    case .accessDenied: "Keychain access denied"
    case .cancelled: "Keychain access cancelled"
    case .invalid: "Saved token is unreadable"
    case .unavailable: "Keychain unavailable"
    }
  }

  public var recoverySuggestion: String {
    switch self {
    case .interactionRequired:
      "Unlock your login keychain if locked, then retry the saved connection and review any access request. The saved credential has not been replaced."
    case .accessDenied, .cancelled:
      "Retry the saved connection and review the Keychain access request for this installed Trigo app. The saved credential has not been replaced."
    case .invalid:
      "Enter the current token and reconnect to the same archive."
    case .unavailable(let status):
      "Check Keychain access, then retry the saved connection."
        + (status.map { " Security status: \($0)." } ?? "")
    }
  }
}

public enum ConnectionIssue: Error, Equatable, Sendable {
  case invalidServerURL
  case tokenRequired
  case unreachable
  case unauthorized
  case incompatible
  case wrongStage(expected: ServerStage, actual: ServerStage)
  case differentArchive(expected: String, actual: String)
  case credentialMissing
  case credentialAccess(CredentialAccessFailure)
  case persistence
  case operationInProgress

  public var title: String {
    switch self {
    case .invalidServerURL: "Enter a valid HTTPS server URL"
    case .tokenRequired: "Enter the owner token"
    case .unreachable: "Server unavailable"
    case .unauthorized: "Token rejected"
    case .incompatible: "Incompatible Trigo server"
    case .wrongStage: "Wrong server stage"
    case .differentArchive: "Different archive rejected"
    case .credentialMissing: "Saved token missing"
    case .credentialAccess(let failure): failure.title
    case .persistence: "Connection could not be saved"
    case .operationInProgress: "Connection check already running"
    }
  }

  public var recoverySuggestion: String {
    switch self {
    case .invalidServerURL:
      "Use the HTTPS origin provided by the Trigo operator, without a path or query."
    case .tokenRequired:
      "Paste the owner token created for this archive."
    case .unreachable:
      "Check the URL and network, then try again. A saved archive remains available locally."
    case .unauthorized:
      "Use the current owner token, then try again. A saved archive remains unchanged."
    case .incompatible:
      "Update the server or use a compatible Trigo v1 endpoint. The saved connection is unchanged."
    case .wrongStage(let expected, let actual):
      "This app requires the \(expected.rawValue) server, but the endpoint reported \(actual.rawValue)."
    case .differentArchive:
      "This Mac is already bound to another archive. Archive switching is not supported yet."
    case .credentialMissing:
      "Enter the current token and reconnect to the same archive. Local recording remains available."
    case .credentialAccess(let failure):
      failure.recoverySuggestion + " A retained archive remains available for local recording."
    case .persistence:
      "Check access to Application Support and Keychain, then retry. The previous connection remains active."
    case .operationInProgress:
      "Wait for the current check to finish."
    }
  }
}

public enum ConnectionHealth: Equatable, Sendable {
  case setupRequired
  case checking
  case connected(ServerStatus)
  case blocked(ConnectionIssue)
  case recoveryRequired(ConnectionIssue)
}

public enum RecordingEligibility: Equatable, Sendable {
  case requiresSetup
  case eligible(archiveId: String)
  case unavailableUntilRecovery
}

public struct ConnectionSnapshot: Equatable, Sendable {
  public let binding: ArchiveBinding?
  public let health: ConnectionHealth
  public let lastAttemptIssue: ConnectionIssue?

  public init(
    binding: ArchiveBinding?,
    health: ConnectionHealth,
    lastAttemptIssue: ConnectionIssue?
  ) {
    self.binding = binding
    self.health = health
    self.lastAttemptIssue = lastAttemptIssue
  }

  public var recordingEligibility: RecordingEligibility {
    if let binding { return .eligible(archiveId: binding.archiveId) }
    if case .recoveryRequired = health { return .unavailableUntilRecovery }
    return .requiresSetup
  }

  public var serverOperationsAvailable: Bool {
    guard case .connected(let status) = health else { return false }
    return status.readiness.callOperations == .ready
  }
}

struct StoredConnection: Codable, Equatable, Sendable {
  let serverURL: URL
  let archiveId: String
  let stage: ServerStage
  let credentialAccount: String

  init(serverURL: URL, archiveId: String, stage: ServerStage, credentialAccount: String) {
    self.serverURL = serverURL
    self.archiveId = archiveId
    self.stage = stage
    self.credentialAccount = credentialAccount
  }

  var binding: ArchiveBinding {
    ArchiveBinding(serverURL: serverURL, archiveId: archiveId, stage: stage)
  }
}

struct ConnectionMetadata: Codable, Equatable, Sendable {
  let formatVersion: Int
  var committed: StoredConnection?
  var pending: StoredConnection?
  var retiredCredentialAccounts: [String]

  init(
    committed: StoredConnection? = nil,
    pending: StoredConnection? = nil,
    retiredCredentialAccounts: [String] = []
  ) {
    formatVersion = 1
    self.committed = committed
    self.pending = pending
    self.retiredCredentialAccounts = retiredCredentialAccounts
  }
}

protocol ConnectionMetadataStoring: Sendable {
  func load() async throws -> ConnectionMetadata?
  func save(_ metadata: ConnectionMetadata) async throws
}

protocol CredentialStoring: Sendable {
  func load(account: String) async throws -> String?
  func save(token: String, account: String) async throws
  func delete(account: String) async throws
}

protocol ServerStatusFetching: Sendable {
  func fetch(serverURL: URL, token: String) async throws -> ServerStatus
}

public actor ServerConnection {
  private let transportPolicy: ServerTransportPolicy
  private let expectedStage: ServerStage
  private let metadataStore: any ConnectionMetadataStoring
  private let credentialStore: any CredentialStoring
  private let statusClient: any ServerStatusFetching
  private var metadata = ConnectionMetadata()
  private var didLoad = false
  private var recoveryIssue: ConnectionIssue?
  private var operationInProgress = false
  private var current = ConnectionSnapshot(
    binding: nil,
    health: .setupRequired,
    lastAttemptIssue: nil
  )

  init(
    expectedStage: ServerStage,
    metadataStore: any ConnectionMetadataStoring,
    credentialStore: any CredentialStoring,
    statusClient: any ServerStatusFetching,
    transportPolicy: ServerTransportPolicy = .httpsOnly
  ) {
    self.transportPolicy = transportPolicy
    self.expectedStage = expectedStage
    self.metadataStore = metadataStore
    self.credentialStore = credentialStore
    self.statusClient = statusClient
  }

  public static func live(namespace: AppNamespace, variant: AppVariant) throws -> ServerConnection {
    try namespace.requireInstalledVariant(variant)
    let policy: ServerTransportPolicy =
      namespace.localDevelopment.map { .localDevelopment($0) } ?? .httpsOnly
    return ServerConnection(
      expectedStage: variant.serverStage,
      metadataStore: FileConnectionMetadataStore(
        url: namespace.connection,
        transportPolicy: policy
      ),
      credentialStore: KeychainCredentialStore(service: namespace.keychainService),
      statusClient: HTTPSStatusClient(transportPolicy: policy),
      transportPolicy: policy
    )
  }

  public func snapshot() -> ConnectionSnapshot { current }

  /// Internal transport authority. UI clients never receive the token or credential account.
  func masterUploadAuthorization(archiveID: String) async throws -> MasterUploadAuthorization {
    guard current.serverOperationsAvailable, let committed = metadata.committed,
      committed.archiveId == archiveID, current.binding == committed.binding,
      transportPolicy.canonicalURL(committed.serverURL.absoluteString) == committed.serverURL
    else { throw MasterUploadError.remoteBlocked }
    let token: String
    do {
      guard let stored = try await credentialStore.load(account: committed.credentialAccount) else {
        throw ConnectionIssue.credentialMissing
      }
      token = stored
    } catch {
      let issue: ConnectionIssue
      if let connectionIssue = error as? ConnectionIssue {
        issue = connectionIssue
      } else {
        issue = .credentialAccess(credentialAccessFailure(error))
      }
      if metadata.committed?.credentialAccount == committed.credentialAccount,
        current.binding == committed.binding
      {
        current = .init(binding: committed.binding, health: .blocked(issue), lastAttemptIssue: nil)
      }
      throw MasterUploadError.remoteBlocked
    }
    // Credentials may suspend. A settings change in that interval invalidates this authority.
    guard current.serverOperationsAvailable,
      metadata.committed?.credentialAccount == committed.credentialAccount,
      current.binding == committed.binding
    else { throw MasterUploadError.remoteBlocked }
    return .init(
      binding: committed.binding,
      credentialAccount: committed.credentialAccount,
      token: token
    )
  }

  func reportMasterUploadIssue(_ issue: ConnectionIssue, authority: MasterUploadAuthorization) {
    guard metadata.committed?.credentialAccount == authority.credentialAccount,
      current.binding == authority.binding
    else { return }
    current = .init(binding: authority.binding, health: .blocked(issue), lastAttemptIssue: nil)
  }

  public func restore(
    onBindingRestored: @Sendable (ConnectionSnapshot) async -> Void = { _ in }
  ) async -> ConnectionSnapshot {
    guard beginOperation() else { return current }
    defer { operationInProgress = false }

    do {
      metadata = try await metadataStore.load() ?? ConnectionMetadata()
      guard metadataIsValidForNamespace() else { throw ConnectionIssue.persistence }
      didLoad = true
    } catch {
      current = ConnectionSnapshot(
        binding: nil,
        health: .recoveryRequired(.persistence),
        lastAttemptIssue: nil
      )
      return current
    }

    let recovered = await recoverInterruptedWrites()
    guard let committed = metadata.committed else {
      current = ConnectionSnapshot(
        binding: nil,
        health: recovered ? .setupRequired : .recoveryRequired(.persistence),
        lastAttemptIssue: recovered ? nil : (recoveryIssue ?? .persistence)
      )
      return current
    }

    current = ConnectionSnapshot(
      binding: committed.binding,
      health: .checking,
      lastAttemptIssue: recovered ? nil : (recoveryIssue ?? .persistence)
    )
    // Local capture can recover and become eligible before the remote health request completes.
    await onBindingRestored(current)
    let token: String
    do {
      guard let savedToken = try await credentialStore.load(account: committed.credentialAccount)
      else {
        current = ConnectionSnapshot(
          binding: committed.binding,
          health: .blocked(.credentialMissing),
          lastAttemptIssue: current.lastAttemptIssue
        )
        return current
      }
      token = savedToken
    } catch {
      current = ConnectionSnapshot(
        binding: committed.binding,
        health: .blocked(.credentialAccess(credentialAccessFailure(error))),
        lastAttemptIssue: current.lastAttemptIssue
      )
      return current
    }
    do {
      let status = try await statusClient.fetch(serverURL: committed.serverURL, token: token)
      try validate(status, expectedArchiveId: committed.archiveId)
      current = ConnectionSnapshot(
        binding: committed.binding,
        health: .connected(status),
        lastAttemptIssue: current.lastAttemptIssue
      )
    } catch let issue as ConnectionIssue {
      current = ConnectionSnapshot(
        binding: committed.binding,
        health: .blocked(issue),
        lastAttemptIssue: current.lastAttemptIssue
      )
    } catch {
      current = ConnectionSnapshot(
        binding: committed.binding,
        health: .blocked(.unreachable),
        lastAttemptIssue: current.lastAttemptIssue
      )
    }
    return current
  }

  public func connect(
    serverURL rawServerURL: String,
    token rawToken: String
  ) async
    -> ConnectionSnapshot
  {
    guard beginOperation() else { return current }
    defer { operationInProgress = false }

    guard let serverURL = transportPolicy.canonicalURL(rawServerURL) else {
      return reject(.invalidServerURL)
    }
    let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { return reject(.tokenRequired) }
    guard await loadMetadataIfNeeded() else { return reject(.persistence) }
    guard await recoverInterruptedWrites() else { return reject(recoveryIssue ?? .persistence) }

    let status: ServerStatus
    do {
      status = try await statusClient.fetch(serverURL: serverURL, token: token)
      try validate(status, expectedArchiveId: metadata.committed?.archiveId)
    } catch let issue as ConnectionIssue {
      return reject(issue)
    } catch {
      return reject(.unreachable)
    }

    if let committed = metadata.committed, committed.serverURL == serverURL {
      do {
        // Compare only the exact committed item, after same-archive validation and recovery.
        // A read failure is not permission to replace a retained credential.
        if try await credentialStore.load(account: committed.credentialAccount) == token {
          current = ConnectionSnapshot(
            binding: committed.binding,
            health: .connected(status),
            lastAttemptIssue: nil
          )
          return current
        }
      } catch {
        let failure = credentialAccessFailure(error)
        // Known unreadable bytes can be repaired with the explicitly entered,
        // remote-validated token. Access failures do not establish corruption.
        if failure != .invalid { return reject(.credentialAccess(failure)) }
      }
    }

    let candidate = StoredConnection(
      serverURL: serverURL,
      archiveId: status.archiveId,
      stage: status.stage,
      credentialAccount: UUID().uuidString.lowercased()
    )
    if let issue = await commit(candidate: candidate, token: token) { return reject(issue) }

    current = ConnectionSnapshot(
      binding: candidate.binding,
      health: .connected(status),
      lastAttemptIssue: nil
    )
    await cleanRetiredCredentials()
    return current
  }

  private func beginOperation() -> Bool {
    guard !operationInProgress else {
      current = ConnectionSnapshot(
        binding: current.binding,
        health: current.health,
        lastAttemptIssue: .operationInProgress
      )
      return false
    }
    operationInProgress = true
    return true
  }

  private func loadMetadataIfNeeded() async -> Bool {
    guard !didLoad else { return true }
    do {
      metadata = try await metadataStore.load() ?? ConnectionMetadata()
      guard metadataIsValidForNamespace() else { throw ConnectionIssue.persistence }
      didLoad = true
      if let committed = metadata.committed {
        current = ConnectionSnapshot(
          binding: committed.binding,
          health: .checking,
          lastAttemptIssue: nil
        )
      }
      return true
    } catch {
      current = ConnectionSnapshot(
        binding: nil,
        health: .recoveryRequired(.persistence),
        lastAttemptIssue: nil
      )
      return false
    }
  }

  private func recoverInterruptedWrites() async -> Bool {
    var recoverySucceeded = true
    recoveryIssue = nil
    if let pending = metadata.pending {
      do {
        try await credentialStore.delete(account: pending.credentialAccount)
        var recovered = metadata
        recovered.pending = nil
        try await metadataStore.save(recovered)
        metadata = recovered
      } catch {
        recoverySucceeded = false
        recoveryIssue = connectionPersistenceIssue(error)
      }
    }
    await cleanRetiredCredentials()
    return recoverySucceeded
  }

  private func commit(candidate: StoredConnection, token: String) async -> ConnectionIssue? {
    let previous = metadata
    var pending = previous
    pending.pending = candidate
    do {
      try await metadataStore.save(pending)
      metadata = pending
      try await credentialStore.save(token: token, account: candidate.credentialAccount)
    } catch {
      await rollBack(candidate: candidate, to: previous)
      return connectionPersistenceIssue(error)
    }

    var committed = previous
    committed.committed = candidate
    committed.pending = nil
    if let previousAccount = previous.committed?.credentialAccount,
      previousAccount != candidate.credentialAccount
    {
      committed.retiredCredentialAccounts.append(previousAccount)
    }
    do {
      try await metadataStore.save(committed)
      metadata = committed
      return nil
    } catch {
      await rollBack(candidate: candidate, to: previous)
      return connectionPersistenceIssue(error)
    }
  }

  private func rollBack(candidate: StoredConnection, to previous: ConnectionMetadata) async {
    do {
      try await credentialStore.delete(account: candidate.credentialAccount)
      try await metadataStore.save(previous)
      metadata = previous
    } catch {
      // The persisted pending record is deliberately retained for relaunch recovery.
    }
  }

  private func cleanRetiredCredentials() async {
    guard !metadata.retiredCredentialAccounts.isEmpty else { return }
    var remaining: [String] = []
    for account in metadata.retiredCredentialAccounts {
      do {
        try await credentialStore.delete(account: account)
      } catch {
        remaining.append(account)
      }
    }
    guard remaining != metadata.retiredCredentialAccounts else { return }
    var cleaned = metadata
    cleaned.retiredCredentialAccounts = remaining
    do {
      try await metadataStore.save(cleaned)
      metadata = cleaned
    } catch {
      // Keeping the retirement list is safe and makes cleanup retryable on relaunch.
    }
  }

  private func validate(_ status: ServerStatus, expectedArchiveId: String?) throws {
    guard status.stage == expectedStage else {
      throw ConnectionIssue.wrongStage(expected: expectedStage, actual: status.stage)
    }
    if let expectedArchiveId, status.archiveId != expectedArchiveId {
      throw ConnectionIssue.differentArchive(
        expected: expectedArchiveId,
        actual: status.archiveId
      )
    }
  }

  private func metadataIsValidForNamespace() -> Bool {
    let stored = [metadata.committed, metadata.pending].compactMap { $0 }
    guard stored.allSatisfy({ $0.stage == expectedStage }) else { return false }
    if let committed = metadata.committed, let pending = metadata.pending,
      committed.archiveId != pending.archiveId
    {
      return false
    }
    let accounts = stored.map(\.credentialAccount) + metadata.retiredCredentialAccounts
    return Set(accounts).count == accounts.count
  }

  private func reject(_ issue: ConnectionIssue) -> ConnectionSnapshot {
    current = ConnectionSnapshot(
      binding: current.binding,
      health: current.health,
      lastAttemptIssue: issue
    )
    return current
  }

  static func canonicalServerURL(_ rawValue: String) -> URL? {
    ServerTransportPolicy.httpsOnly.canonicalURL(rawValue)
  }
}
