import Foundation
import TrigoContracts

public enum PersistenceInterruptionPoint: Sendable, Equatable {
  case beforeRepositoryCommit
  case afterRepositoryCommit
  case afterRepositoryStaging
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
  case operationAlreadyAcknowledged(String)
  case lifecycleNotFound(String)
  case invalidFailureCode(String)
  case unsupportedStore(String)
  case unsafeStore(String)
  case concurrentMutation
  case captureStateOwnedByRepository
  case invalidMediaProgress
  case sqlite(code: Int32, message: String)
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
}

func isCanonicalIdentifier(_ value: String) -> Bool {
  value.range(
    of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
    options: .regularExpression
  ) != nil
}

func requireCanonicalIdentifier(_ value: String) throws {
  guard isCanonicalIdentifier(value) else { throw LocalPersistenceError.invalidIdentifier(value) }
}
