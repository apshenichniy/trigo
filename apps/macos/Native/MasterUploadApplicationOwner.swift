import Foundation

/// Retain once in the application composition. Attach immediately after local binding restore,
/// including offline starts; window visibility and remote health do not own durable cleanup.
public actor MasterUploadApplicationOwner {
  private let namespace: AppNamespace
  private let connection: ServerConnection
  private var archiveID: String?
  private var coordinator: MasterUploadCoordinator?

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
    let service = MasterUploadCoordinator(
      repository: repository,
      transport: HTTPMasterUploadTransport(connection: connection, archiveID: binding.archiveId)
    )
    archiveID = binding.archiveId
    coordinator = service
    await service.start()
  }

  public func wake() async { await coordinator?.wake() }
  public func stop() async { await coordinator?.stop() }
}
