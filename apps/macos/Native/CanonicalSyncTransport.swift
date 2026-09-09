import Foundation
import TrigoContracts

public protocol CanonicalSyncTransport: Sendable {
  func catalog(cursor: String?) async throws -> CallCatalogPage
  func changes(cursor: String) async throws -> CallChangesPage
  func document(callID: String, version: Int?) async throws -> Data
  func audioManifest(callID: String) async throws -> Data
  func results(callID: String, cursor: String?) async throws -> TranscriptResultsPage
  func revision(callID: String, revisionID: String) async throws -> Data
  func provenance(callID: String, revisionID: String) async throws -> Data
  func publish(
    callID: String,
    request: PublishCallReplica
  ) async throws -> StoredDocument<ReplicaReceipt>
  func requestTranscription(
    callID: String,
    request: RequestTranscription
  ) async throws -> TranscriptionOperation
  func operation(operationID: String) async throws -> TranscriptionOperation
}

public struct CanonicalSyncPassReport: Sendable {
  public var restoredCallIDs: [String] = []
  public var publishedCallIDs: [String] = []
  public var importedRevisionIDs: [String] = []
  public var changedOperationIDs: [String] = []
  public var conflictCallIDs: [String] = []
  public var failures: [String: LifecycleFailure] = [:]
  public var catalogFailure: LifecycleFailure?
  public var coalesced = false
  public var didChange = false
}

extension Notification.Name {
  public static let canonicalArchiveDidChange = Notification.Name("Trigo.canonicalArchiveDidChange")
}
