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

/// The independently persisted processing dimensions for one local call.
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
    archiveID: String, callID: String, stateVersion: Int,
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
      archiveID: archiveID, callID: callID, stateVersion: 1,
      capture: LifecycleValue(state: .recording),
      upload: LifecycleValue(state: .pending),
      transcription: LifecycleValue(state: .waitingForAudio),
      importState: LifecycleValue(state: .notAvailable),
      replica: LifecycleValue(state: .pending),
      deletion: LifecycleValue(state: .active))
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

public struct LifecycleReconciliationReport: Sendable, Equatable {
  public let validCallIDs: [String]
  public let rejectedCallIDs: [String]
  public let removedTemporaryFiles: Int
}

public actor LocalLifecycleStore {
  private let archiveID: String
  private let directory: URL
  private let writer: AtomicFileWriter

  public init(
    root: URL, archiveID: String,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) throws {
    try requireCanonicalIdentifier(archiveID)
    self.archiveID = archiveID
    self.directory = root.appendingPathComponent("lifecycle", isDirectory: true)
    self.writer = AtomicFileWriter(interruption: interruption)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public func publish(_ snapshot: CallLifecycleSnapshot) throws -> PublicationResult {
    try validate(snapshot)
    let destination = snapshotURL(snapshot.callID)
    if let current = try load(callID: snapshot.callID) {
      if current == snapshot { return .alreadyPresent }
      guard snapshot.stateVersion > current.stateVersion else {
        throw LocalPersistenceError.staleDocumentVersion(
          current: current.stateVersion, proposed: snapshot.stateVersion)
      }
    }
    try writer.write(try encode(snapshot), to: destination, domain: .lifecycle)
    return .committed
  }

  public func load(callID: String) throws -> CallLifecycleSnapshot? {
    try requireCanonicalIdentifier(callID)
    let url = snapshotURL(callID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let snapshot: CallLifecycleSnapshot
    do {
      snapshot = try JSONDecoder().decode(
        CallLifecycleSnapshot.self, from: Data(contentsOf: url))
    } catch {
      throw LocalPersistenceError.invalidStoredDocument(
        "Call lifecycle snapshot cannot be decoded")
    }
    guard snapshot.callID == callID else {
      throw LocalPersistenceError.invalidStoredDocument(
        "Lifecycle filename and call identity differ")
    }
    try validate(snapshot)
    return snapshot
  }

  public func update(
    callID: String, _ change: @Sendable (inout CallLifecycleSnapshot) throws -> Void
  ) throws -> CallLifecycleSnapshot {
    guard var current = try load(callID: callID) else {
      throw LocalPersistenceError.lifecycleNotFound(callID)
    }
    let nextVersion = current.stateVersion + 1
    try change(&current)
    let updated = current.advancingVersion(to: nextVersion)
    _ = try publish(updated)
    return updated
  }

  public func reconcile() throws -> LifecycleReconciliationReport {
    let urls = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [])
    var removed = 0
    for url in urls
    where url.lastPathComponent.hasPrefix(AtomicFileWriter.temporaryPrefix) {
      try writer.remove(url)
      removed += 1
    }

    var valid: [String] = []
    var rejected: [String] = []
    for url in try snapshotURLs() {
      let callID = url.deletingPathExtension().lastPathComponent
      do {
        guard try load(callID: callID) != nil else {
          throw LocalPersistenceError.lifecycleNotFound(callID)
        }
        valid.append(callID)
      } catch {
        rejected.append(callID)
      }
    }
    return LifecycleReconciliationReport(
      validCallIDs: valid.sorted(), rejectedCallIDs: rejected.sorted(),
      removedTemporaryFiles: removed)
  }

  private func validate(_ snapshot: CallLifecycleSnapshot) throws {
    try requireCanonicalIdentifier(snapshot.archiveID)
    try requireCanonicalIdentifier(snapshot.callID)
    guard snapshot.archiveID == archiveID else {
      throw LocalPersistenceError.archiveIdentityMismatch(
        expected: archiveID, actual: snapshot.archiveID)
    }
    guard snapshot.schemaVersion == 1, snapshot.stateVersion >= 1 else {
      throw LocalPersistenceError.invalidStoredDocument(
        "Unsupported lifecycle schema or state version")
    }
    let failures = [
      snapshot.capture.failure, snapshot.upload.failure, snapshot.transcription.failure,
      snapshot.importState.failure, snapshot.replica.failure, snapshot.deletion.failure,
    ].compactMap { $0 }
    for failure in failures where !isStableFailureCode(failure.code) {
      throw LocalPersistenceError.invalidFailureCode(failure.code)
    }
  }

  private func encode(_ snapshot: CallLifecycleSnapshot) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(snapshot)
  }

  private func snapshotURLs() throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []
    ).filter {
      $0.pathExtension == "json"
        && !$0.lastPathComponent.hasPrefix(AtomicFileWriter.temporaryPrefix)
    }
  }

  private func snapshotURL(_ callID: String) -> URL {
    directory.appendingPathComponent(callID).appendingPathExtension("json")
  }
}

func isStableFailureCode(_ code: String) -> Bool {
  code.range(of: "^[a-z][a-z0-9_]*$", options: .regularExpression) != nil
}
