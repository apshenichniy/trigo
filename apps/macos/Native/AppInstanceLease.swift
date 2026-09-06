import Darwin
import Foundation

enum AppInstanceLeaseError: Error { case alreadyRunning, unavailable }

/// One live application owns a namespace, including connection recovery and capture.
/// Keep the locked inode in place: removing it would let another process lock a new inode.
final class AppInstanceLease {
  private let descriptor: Int32

  init(namespace: AppNamespace) throws {
    let directory = namespace.connection.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let path = directory.appendingPathComponent("application.lock").path
    let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw AppInstanceLeaseError.unavailable }
    var acquired = false
    defer { if !acquired { Darwin.close(descriptor) } }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1
    else { throw AppInstanceLeaseError.unavailable }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw errno == EWOULDBLOCK
        ? AppInstanceLeaseError.alreadyRunning : AppInstanceLeaseError.unavailable
    }
    guard fchmod(descriptor, 0o600) == 0 else { throw AppInstanceLeaseError.unavailable }
    self.descriptor = descriptor
    acquired = true
  }

  // The kernel also releases ownership after a crash. There is no stale-PID takeover.
  deinit { Darwin.close(descriptor) }
}
