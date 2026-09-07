import Foundation
import TrigoContracts

public enum OperationKind: String, Codable, CaseIterable, Sendable {
  case capture
  case upload
  case asr
  case importRevision = "import"
  case replica
  case deletion
}

public enum OperationPhase: String, Codable, Sendable {
  case pending
  case running
  case blocked
  case failed
}

public struct OperationIntent: Sendable, Equatable {
  public let operationID: String
  public let archiveID: String
  public let callID: String
  public let kind: OperationKind
  public let payload: Data

  public init(
    operationID: String,
    archiveID: String,
    callID: String,
    kind: OperationKind,
    payload: Data = Data()
  ) {
    self.operationID = operationID
    self.archiveID = archiveID
    self.callID = callID
    self.kind = kind
    self.payload = payload
  }
}

public struct JournaledOperation: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let operationID: String
  public let archiveID: String
  public let callID: String
  public let kind: OperationKind
  public let payload: Data
  public let payloadSHA256: String
  public let phase: OperationPhase
  public let createdAtMilliseconds: Int64
  public let updatedAtMilliseconds: Int64
  public let attempt: Int
  public let lastFailure: LifecycleFailure?
  public let acknowledged: Bool
}
