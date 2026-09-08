import Foundation

enum AppInstanceLeaseError: Error { case alreadyRunning, unavailable }

/// One live application owns a namespace, including connection recovery and capture.
/// Keep the locked inode in place: removing it would let another process lock a new inode.
final class AppInstanceLease {
  private let lease: ExclusiveFileLease

  init(namespace: AppNamespace) throws {
    do {
      lease = try ExclusiveFileLease(
        file: namespace.connection.deletingLastPathComponent()
          .appendingPathComponent("application.lock")
      )
    } catch ExclusiveFileLeaseError.alreadyOwned {
      throw AppInstanceLeaseError.alreadyRunning
    } catch {
      throw AppInstanceLeaseError.unavailable
    }
  }
}
