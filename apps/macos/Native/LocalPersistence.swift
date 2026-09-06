import Darwin
import Foundation
import TrigoContracts

public enum PersistenceInterruptionPoint: Sendable, Equatable {
  case afterArchiveTemporaryFileSynced
  case afterArchiveAtomicReplacement
  case afterJournalTemporaryFileSynced
  case afterJournalAtomicReplacement
  case afterLifecycleTemporaryFileSynced
  case afterLifecycleAtomicReplacement
  case afterJournalIntentPersisted
  case beforeJournalAcknowledgement
  case afterJournalAcknowledgement
}

public typealias PersistenceInterruption = @Sendable (PersistenceInterruptionPoint) throws -> Void

public enum LocalPersistenceError: Error, Sendable, Equatable {
  case invalidIdentifier(String)
  case archiveIdentityMismatch(expected: String, actual: String)
  case callNotFound(String)
  case immutableConflict(String)
  case manifestWouldDiscardRevision(String)
  case manifestWouldChangeSpeakerAnnotations
  case manifestWouldChangeAudioManifest
  case staleDocumentVersion(current: Int, proposed: Int)
  case invalidSpeakerReference(revisionID: String, speakerID: String)
  case invalidStoredDocument(String)
  case operationNotFound(String)
  case operationConflict(String)
  case lifecycleNotFound(String)
  case invalidFailureCode(String)
  case io(String)
}

public enum PublicationResult: Sendable, Equatable {
  /// New validated bytes became the canonical value for their identity.
  case committed
  /// Exactly the same immutable bytes or mutable manifest version were already stored.
  case alreadyPresent
}

/// A validated canonical call and the exact immutable bytes referenced by its manifest.
public struct LocalCallAggregate: Sendable {
  public let manifest: StoredDocument<CallDocument>
  public let transcriptRevisions: [String: Data]
  public let audioManifest: Data?
}

public struct ArchiveReconciliationReport: Sendable, Equatable {
  public let validCallIDs: [String]
  public let rejectedCallIDs: [String]
  public let removedTemporaryFiles: Int
}

enum PersistenceDomain {
  case archive
  case journal
  case lifecycle

  var temporaryFilePoint: PersistenceInterruptionPoint {
    switch self {
    case .archive: .afterArchiveTemporaryFileSynced
    case .journal: .afterJournalTemporaryFileSynced
    case .lifecycle: .afterLifecycleTemporaryFileSynced
    }
  }

  var replacementPoint: PersistenceInterruptionPoint {
    switch self {
    case .archive: .afterArchiveAtomicReplacement
    case .journal: .afterJournalAtomicReplacement
    case .lifecycle: .afterLifecycleAtomicReplacement
    }
  }
}

struct AtomicFileWriter: Sendable {
  static let temporaryPrefix = ".trigo-pending-"

  let interruption: PersistenceInterruption

  func write(_ bytes: Data, to destination: URL, domain: PersistenceDomain) throws {
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
      try interruption(domain.temporaryFilePoint)

      guard Darwin.rename(temporary.path, destination.path) == 0 else {
        throw LocalPersistenceError.io("Atomic replacement failed with errno \(errno)")
      }
      try interruption(domain.replacementPoint)
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

func isCanonicalIdentifier(_ value: String) -> Bool {
  value.range(
    of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    options: .regularExpression) != nil
}

func requireCanonicalIdentifier(_ value: String) throws {
  guard isCanonicalIdentifier(value) else { throw LocalPersistenceError.invalidIdentifier(value) }
}
