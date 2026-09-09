import Darwin
import Foundation

enum ExclusiveFileLeaseError: Error { case alreadyOwned, unavailable }

/// Lock a stable inode without PID-file takeover or unlinking the lock file.
final class ExclusiveFileLease {
  private let descriptor: Int32

  init(file: URL) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let descriptor = Darwin.open(file.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw ExclusiveFileLeaseError.unavailable }
    var acquired = false
    defer { if !acquired { Darwin.close(descriptor) } }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
      metadata.st_uid == getuid()
    else { throw ExclusiveFileLeaseError.unavailable }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      throw errno == EWOULDBLOCK
        ? ExclusiveFileLeaseError.alreadyOwned : ExclusiveFileLeaseError.unavailable
    }
    guard fchmod(descriptor, 0o600) == 0 else { throw ExclusiveFileLeaseError.unavailable }
    self.descriptor = descriptor
    acquired = true
  }

  /// Process creation may temporarily duplicate this descriptor before close-on-exec.
  /// Release ownership immediately instead of waiting for that reference to close.
  func relinquish() { _ = flock(descriptor, LOCK_UN) }

  deinit { Darwin.close(descriptor) }
}
