import Foundation

public enum CaptureLifecycleState: String, Codable, CaseIterable, Sendable {
  case recording
  case stopped
  case interrupted
}

public enum UploadLifecycleState: String, Codable, CaseIterable, Sendable {
  case pending
  case uploading
  case stored
  case failed
}

public enum TranscriptionLifecycleState: String, Codable, CaseIterable, Sendable {
  case waitingForAudio = "waiting_for_audio"
  case queued
  case running
  case resultAvailable = "result_available"
  case failed
}

public enum ImportLifecycleState: String, Codable, CaseIterable, Sendable {
  case notAvailable = "not_available"
  case pending
  case imported
  case failed
}

public enum ReplicaLifecycleState: String, Codable, CaseIterable, Sendable {
  case pending
  case confirmed
  case conflict
}

public enum DeletionLifecycleState: String, Codable, CaseIterable, Sendable {
  case active
  case requested
  case draining
  case deleting
  case complete
}

public enum LifecycleRetryClassification: String, Codable, Sendable {
  case never
  case afterCorrection = "after_correction"
  case retryable
}

/// Machine-readable failure identity. User-facing copy belongs to the presentation layer.
public struct LifecycleFailure: Codable, Sendable, Equatable {
  public let code: String
  public let retry: LifecycleRetryClassification

  public init(code: String, retry: LifecycleRetryClassification) throws {
    guard isStableFailureCode(code) else {
      throw LocalPersistenceError.invalidFailureCode(code)
    }
    self.code = code
    self.retry = retry
  }
}

public struct LifecycleValue<State>: Codable, Sendable, Equatable
where State: Codable & Sendable & Equatable {
  public var state: State
  public var failure: LifecycleFailure?

  public init(state: State, failure: LifecycleFailure? = nil) {
    self.state = state
    self.failure = failure
  }
}

/// Six observable dimensions; capture is projected from the canonical call row.
public struct CallLifecycleSnapshot: Codable, Sendable, Equatable {
  public let schemaVersion: Int
  public let archiveID: String
  public let callID: String
  public private(set) var stateVersion: Int
  public var capture: LifecycleValue<CaptureLifecycleState>
  public var upload: LifecycleValue<UploadLifecycleState>
  public var transcription: LifecycleValue<TranscriptionLifecycleState>
  public var importState: LifecycleValue<ImportLifecycleState>
  public var replica: LifecycleValue<ReplicaLifecycleState>
  public var deletion: LifecycleValue<DeletionLifecycleState>

  public init(
    archiveID: String,
    callID: String,
    stateVersion: Int,
    capture: LifecycleValue<CaptureLifecycleState>,
    upload: LifecycleValue<UploadLifecycleState>,
    transcription: LifecycleValue<TranscriptionLifecycleState>,
    importState: LifecycleValue<ImportLifecycleState>,
    replica: LifecycleValue<ReplicaLifecycleState>,
    deletion: LifecycleValue<DeletionLifecycleState>
  ) {
    self.schemaVersion = 1
    self.archiveID = archiveID
    self.callID = callID
    self.stateVersion = stateVersion
    self.capture = capture
    self.upload = upload
    self.transcription = transcription
    self.importState = importState
    self.replica = replica
    self.deletion = deletion
  }

  public static func initial(archiveID: String, callID: String) -> Self {
    Self(
      archiveID: archiveID,
      callID: callID,
      stateVersion: 1,
      capture: LifecycleValue(state: .recording),
      upload: LifecycleValue(state: .pending),
      transcription: LifecycleValue(state: .waitingForAudio),
      importState: LifecycleValue(state: .notAvailable),
      replica: LifecycleValue(state: .pending),
      deletion: LifecycleValue(state: .active)
    )
  }

  func advancingVersion(to stateVersion: Int) -> Self {
    var copy = self
    copy.stateVersion = stateVersion
    return copy
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case archiveID = "archiveId"
    case callID = "callId"
    case stateVersion
    case capture
    case upload
    case transcription
    case importState = "import"
    case replica
    case deletion
  }
}

func isStableFailureCode(_ code: String) -> Bool {
  code.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
}
