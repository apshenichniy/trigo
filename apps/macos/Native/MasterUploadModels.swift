import Foundation
import TrigoContracts

public enum MasterUploadError: Error, Sendable, Equatable {
  case invalidReceipt
  case invalidPart
  case remoteBlocked
  case fenced
  case transport(code: String, retry: LifecycleRetryClassification)
}

public struct MasterUploadState: Sendable, Equatable {
  public let callID: String
  public let uploadID: String
  public let operationID: String
  public let finalizeOperationID: String
  public let registered: Bool
  public let cleanupComplete: Bool
}

public struct MasterUploadPart: Sendable {
  public let descriptor: UploadPartDescriptor
  public let receipt: StoredDocument<UploadPartReceipt>?
}

public enum MasterUploadPersistencePoint: Sendable {
  case beforeReceiptCommit, afterReceiptCommit, beforeMediaCleanup, afterMasterRemoval,
    afterMediaCleanup
}

public typealias MasterUploadInterruption = @Sendable (MasterUploadPersistencePoint) throws -> Void

/// Implementations carry authentication and reject redirects; callers supply no arbitrary URL/key.
public protocol MasterUploadTransport: Sendable {
  func register(_ request: RegisterMasterUpload) async throws -> StoredDocument<MasterUploadSession>
  func upload(
    callID: String,
    uploadID: String,
    part: UploadPartDescriptor,
    bytes: Data
  ) async throws -> StoredDocument<UploadPartReceipt>
  func finalize(
    callID: String,
    request: FinalizeMasterUpload
  ) async throws -> StoredDocument<VerifiedMasterReceipt>
}

public struct MasterUploadPassReport: Sendable {
  public var uploadedParts = 0
  public var storedCallIDs: [String] = []
  public var cleanedCallIDs: [String] = []
  public var failures: [String: LifecycleFailure] = [:]
  public var coalesced = false
  public init() {}
}
