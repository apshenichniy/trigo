import Darwin
import Foundation

struct CaptureMediaFileWriter: Sendable {
  static let temporaryPrefix = ".trigo-pending-"

  func write(_ bytes: Data, to destination: URL) throws {
    let manager = FileManager.default
    let directory = destination.deletingLastPathComponent()
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      let temporary = directory.appendingPathComponent(
        Self.temporaryPrefix + destination.lastPathComponent + "-" + UUID().uuidString.lowercased())
      guard manager.createFile(atPath: temporary.path, contents: nil) else {
        throw LocalPersistenceError.io("Could not create an atomic temporary file")
      }
      let handle = try FileHandle(forWritingTo: temporary)
      try handle.write(contentsOf: bytes)
      try handle.synchronize()
      try handle.close()

      guard Darwin.rename(temporary.path, destination.path) == 0 else {
        throw LocalPersistenceError.io("Atomic replacement failed with errno \(errno)")
      }
      try synchronizeDirectory(directory)
    } catch let error as LocalPersistenceError {
      throw error
    } catch {
      throw error
    }
  }

  func remove(_ destination: URL) throws {
    do {
      try FileManager.default.removeItem(at: destination)
      try synchronizeDirectory(destination.deletingLastPathComponent())
    } catch CocoaError.fileNoSuchFile {
      return
    } catch {
      throw error
    }
  }

  private func synchronizeDirectory(_ directory: URL) throws {
    let descriptor = Darwin.open(directory.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw LocalPersistenceError.io("Could not open persistence directory with errno \(errno)")
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw LocalPersistenceError.io(
        "Could not synchronize persistence directory with errno \(errno)")
    }
  }
}
