import Darwin
import Foundation

extension FileHandle {
  /// Foundation's NSData bridge may otherwise retain autoreleased read buffers until the outer
  /// run-loop/test boundary. Drain each bounded read, including recovery and extraction scans.
  func readMasterBytes(upToCount count: Int) throws -> Data? {
    try autoreleasepool { try read(upToCount: count) }
  }
}

/// Fault seams exercise actual files and partial POSIX writes, never private capture resources.
enum MediaMasterIOPoint: String, CaseIterable {
  case beforeMediaSync, afterMediaSync, beforeIndexSync, afterIndexSync
  case beforeFinalizationSync, afterFinalizationSync
}

struct MediaMasterIO {
  var event: (MediaMasterIOPoint) throws -> Void = { _ in }
  var write: (Int32, UnsafeRawBufferPointer) throws -> Int = { fd, bytes in
    Darwin.write(fd, bytes.baseAddress, bytes.count)
  }

  func writeAll(_ data: Data, to handle: FileHandle) throws {
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = try write(
          handle.fileDescriptor,
          UnsafeRawBufferPointer(rebasing: bytes[offset...])
        )
        if written < 0 && errno == EINTR { continue }
        guard written > 0 && written <= bytes.count - offset else {
          throw MediaMasterError.io(written < 0 ? errno : EIO)
        }
        offset += written
      }
    }
  }

  static func create(_ url: URL) throws -> FileHandle {
    let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw MediaMasterError.io(errno) }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  static func syncDirectory(_ url: URL) throws {
    let descriptor = Darwin.open(url.path, O_RDONLY)
    guard descriptor >= 0 else { throw MediaMasterError.io(errno) }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else { throw MediaMasterError.io(errno) }
  }
}
