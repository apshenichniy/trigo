import Foundation

public actor CanonicalSyncApplicationOwner {
  private let namespace: AppNamespace
  private let connection: ServerConnection
  private var archiveID: String?
  private var coordinator: CanonicalSyncCoordinator?

  public init(namespace: AppNamespace, connection: ServerConnection) {
    self.namespace = namespace
    self.connection = connection
  }

  public func start(binding: ArchiveBinding) async throws {
    if let archiveID, archiveID != binding.archiveId {
      throw LocalPersistenceError.archiveIdentityMismatch(
        expected: archiveID,
        actual: binding.archiveId
      )
    }
    if let coordinator { await coordinator.start(); return }
    let repository = try LocalRepository(root: namespace.archive, archiveID: binding.archiveId)
    let archiveID = binding.archiveId
    let preferences = namespace.preferences
    let service = CanonicalSyncCoordinator(
      repository: repository,
      transport: HTTPCanonicalSyncTransport(connection: connection, archiveID: archiveID),
      language: {
        let saved = UserDefaults(suiteName: preferences)?
          .string(forKey: AutomaticTranscriptionLanguage.preferenceKey)
        return AutomaticTranscriptionLanguage(rawValue: saved ?? "")?.rawValue
          ?? AutomaticTranscriptionLanguage.russian.rawValue
      },
      onChange: {
        NotificationCenter.default.post(name: .canonicalArchiveDidChange, object: archiveID)
      }
    )
    self.archiveID = archiveID
    coordinator = service
    await service.start()
  }

  public func wake() async { await coordinator?.wake() }
  public func retry(callID: String) async { await coordinator?.wake(callID: callID) }
  public func stop() async { await coordinator?.stop() }
}
