import Foundation
import TrigoContracts

public enum CanonicalSyncError: Error, Sendable, Equatable {
  case deleted
  case invalidAnnotation
  case groupIdentityReused(String)
  case conflict
  case invalidReceipt
  case incompatibleDocument
  case missingCanonicalDocument
  case invalidResult
  case cursorReset
  case serverUnavailable
  case unauthorized
  case remote(code: String, retry: LifecycleRetryClassification)
}

public enum SpeakerAnnotationMutation: Codable, Sendable, Equatable {
  case rename(speakerID: String, name: String?)
  case group(groupID: String, displayName: String, speakerIDs: [String])
  case removeMembers(groupID: String, speakerIDs: [String])
  case ungroup(groupID: String)
}

public struct SpeakerAnnotationEdit: Codable, Sendable, Equatable {
  public let operationID: String
  public let callID: String
  public let revisionID: String
  public let expectedDocumentVersion: Int
  public let mutation: SpeakerAnnotationMutation

  public init(
    operationID: String,
    callID: String,
    revisionID: String,
    expectedDocumentVersion: Int,
    mutation: SpeakerAnnotationMutation
  ) {
    self.operationID = operationID
    self.callID = callID
    self.revisionID = revisionID
    self.expectedDocumentVersion = expectedDocumentVersion
    self.mutation = mutation
  }
}

public struct CanonicalReplicaWork: Sendable, Equatable {
  public let operationID: String
  public let callID: String
  public let snapshotHash: String
  public let documentVersion: Int
  public let requestBound: Bool
  public let expectedServerVersion: Int?
  public let annotationRevisionIDs: [String]
  public let conflictRemoteHash: String?
}

public struct SpeakerAnnotations: Sendable, Equatable {
  public let names: [String: String]
  public let groups: [SpeakerGroup]
}

public struct SpeakerAnnotationConflict: Sendable, Equatable {
  public let callID: String
  public let revisionID: String
  public let local: SpeakerAnnotations
  public let server: SpeakerAnnotations
  public let serverDocumentVersion: Int
}

public enum SpeakerConflictChoice: String, Codable, Sendable {
  case keepThisMac
  case useServer
}

func synchronizationIdentity(_ seed: String) -> String {
  var hex = Array(Contract.hash(Data(seed.utf8)).prefix(32))
  hex[12] = "4"
  hex[16] = "8"
  return [
    String(hex[0..<8]), String(hex[8..<12]), String(hex[12..<16]), String(hex[16..<20]),
    String(hex[20..<32]),
  ]
  .joined(separator: "-")
}
