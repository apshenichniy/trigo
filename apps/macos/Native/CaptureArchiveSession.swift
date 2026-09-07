import Foundation
import TrigoContracts

public struct CaptureMicrophone: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

public enum CaptureFinalizationPoint: Sendable { case afterStopIntent, beforeCommit, afterCommit }
public enum CapturePreparationPoint: Sendable { case beforeCommit, afterCommit }

public struct CapturePreparationFailure: Error {
  public let session: CaptureArchiveSession
  public let underlying: any Error
}

/// Allocated identities and source context survive retries; SQLite owns their admission and
/// canonical lifecycle. The external writer remains the media evidence owner.
public struct CaptureArchiveSession: Equatable, Sendable {
  public let root: URL
  public let archiveID: String
  public let callID: String
  public let microphoneTrackID: String
  public let applicationTrackID: String
  public let audioManifestID: String
  public let masterID: String
  public let startedAt: Date
  public let source: CaptureSource
  public let microphone: CaptureMicrophone?
  public var mediaDirectory: URL {
    root.appendingPathComponent(callID).appendingPathComponent("media")
  }

  public static func begin(
    root: URL,
    archiveID: String,
    source: CaptureSource,
    microphone: CaptureMicrophone?,
    startedAt: Date = Date()
  ) async throws -> Self {
    let session = try allocate(
      root: root,
      archiveID: archiveID,
      source: source,
      microphone: microphone,
      startedAt: startedAt
    )
    do { try await session.prepare() } catch {
      throw CapturePreparationFailure(session: session, underlying: error)
    }
    return session
  }

  /// Keep this identity before the first durable write, including when that write fails.
  public static func allocate(
    root: URL,
    archiveID: String,
    source: CaptureSource,
    microphone: CaptureMicrophone?,
    startedAt: Date = Date()
  ) throws -> Self {
    try requireCanonicalIdentifier(archiveID)
    return Self(
      root: try canonicalRepositoryRoot(root),
      archiveID: archiveID,
      callID: captureID(),
      microphoneTrackID: captureID(),
      applicationTrackID: captureID(),
      audioManifestID: captureID(),
      masterID: captureID(),
      startedAt: startedAt,
      source: source,
      microphone: microphone
    )
  }

  public var mediaMasterIdentity: MediaMasterIdentity {
    .init(
      masterID: UUID(uuidString: masterID)!,
      callID: UUID(uuidString: callID)!,
      microphoneTrackID: UUID(uuidString: microphoneTrackID)!,
      applicationTrackID: UUID(uuidString: applicationTrackID)!
    )
  }

  /// The caller retains this session if admission fails before its single commit.
  public func prepare(
    interruption: @escaping @Sendable (CapturePreparationPoint) throws -> Void = { _ in }
  ) async throws {
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    _ = try await repository.beginCapture(self) { point in
      if point == .beforeRepositoryCommit { try interruption(.beforeCommit) }
      if point == .afterRepositoryCommit { try interruption(.afterCommit) }
    }
    try FileManager.default.createDirectory(
      at: mediaDirectory.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
  }

  public func requestStop(reason: String?) async throws {
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    try repository.requestCaptureStop(callID: callID, reason: reason)
  }

  public func complete(
    media: FinalizedMediaMaster?,
    interruptionReason: String?,
    associatedWork: OperationIntent? = nil,
    interruption: @escaping @Sendable (CaptureFinalizationPoint) throws -> Void = { _ in }
  ) async throws -> CaptureCompletion {
    try requireCaptureInterruptionReason(interruptionReason)
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    try repository.requestCaptureStop(callID: callID, reason: interruptionReason)
    try interruption(.afterStopIntent)
    return try await repository.completeCapture(
      self,
      master: media,
      reason: interruptionReason,
      associatedWork: associatedWork
    ) {
      point in
      if point == .beforeRepositoryCommit { try interruption(.beforeCommit) }
      if point == .afterRepositoryCommit { try interruption(.afterCommit) }
    }
  }

  /// Explicit aggregate convenience for callers that need the full public document.
  public func finish(
    media: FinalizedMediaMaster?,
    interruptionReason: String?,
    associatedWork: OperationIntent? = nil,
    interruption: @escaping @Sendable (CaptureFinalizationPoint) throws -> Void = { _ in }
  ) async throws -> LocalCallAggregate {
    _ = try await complete(
      media: media,
      interruptionReason: interruptionReason,
      associatedWork: associatedWork,
      interruption: interruption
    )
    return try await LocalRepository(root: root, archiveID: archiveID).loadCall(callID: callID)
  }

  public static func recover(
    root: URL,
    archiveID: String,
    callID: String
  ) async throws
    -> LocalCallAggregate
  {
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    guard let session = try await repository.captureSession(callID: callID) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    return try await session.recover()
  }

  /// SQLite already recovers atomic metadata. This recovery only reconciles the external
  /// media boundary, without replaying the removed sequence of metadata file publications.
  public func recover() async throws -> LocalCallAggregate {
    _ = try await recoverCompletion()
    return try await LocalRepository(root: root, archiveID: archiveID).loadCall(callID: callID)
  }

  public func recoverCompletion() async throws -> CaptureCompletion {
    try await prepare()
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    if let existing = try repository.captureCompletion(callID: callID) { return existing }
    let requested = try repository.captureStopRequest(callID: callID)
    let reason =
      try requested?.reason ?? repository.captureMediaFailure(callID: callID)
      ?? (requested == nil ? "process_terminated" : nil)
    let mediaURL = mediaDirectory.appendingPathComponent("master.caf")
    let indexURL = mediaDirectory.appendingPathComponent("master.index")
    if !FileManager.default.fileExists(atPath: mediaURL.path)
      && !FileManager.default.fileExists(atPath: indexURL.path)
    {
      guard try repository.confirmedMediaCursor(callID: callID) == nil else {
        throw MediaMasterError.confirmedCursorMissing
      }
      // Admission can survive without ever creating external media. Publish no invented witness.
      return try await complete(media: nil, interruptionReason: reason)
    }
    let writer = try CaptureMediaWriter.recover(session: self)
    try writer.requestStop(reason: reason)
    let master = try writer.finish()
    return try await complete(media: master, interruptionReason: reason)
  }

  func callBytes(
    media: FinalizedMediaMaster?,
    reason: String?,
    version: Int,
    finalized: Bool = false,
    microphoneIntervals: [CaptureInterval] = [],
    applicationIntervals: [CaptureInterval] = [],
    reference: AudioManifestReference?
  ) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    let tracks: [AudioTrack] = [
      .init(
        trackId: microphoneTrackID,
        role: "microphone",
        inputDevice: microphone.map { .init(id: $0.id, name: $0.name) },
        mediaProfileId: MediaMasterProfile.id,
        intervals: intervalDocuments(microphoneIntervals)
      ),
      .init(
        trackId: applicationTrackID,
        role: "application",
        inputDevice: nil,
        mediaProfileId: MediaMasterProfile.id,
        intervals: intervalDocuments(applicationIntervals)
      ),
    ]
    return try Contract.encode(
      CallDocument(
        schemaVersion: 1,
        archiveId: archiveID,
        callId: callID,
        documentVersion: version,
        startedAt: formatter.string(from: startedAt),
        endedAt: finalized
          ? formatter.string(
            from: startedAt.addingTimeInterval(Double(media?.durationMs ?? 0) / 1000)
          )
          : nil,
        durationMs: finalized ? media?.durationMs ?? 0 : nil,
        captureState: !finalized ? "recording" : reason == nil ? "stopped" : "interrupted",
        interruptionReason: reason,
        source: .init(
          applicationName: source.applicationName,
          bundleId: source.bundleID,
          processId: Int(source.processID),
          windowId: Int(source.windowID),
          windowTitle: source.windowTitle
        ),
        tracks: tracks,
        audioManifest: reference,
        revisions: [],
        activeRevisionId: nil,
        speakerNames: [:]
      )
    )
  }

  func audioBytes(_ master: FinalizedMediaMaster?) throws -> Data {
    let objects: [AudioObject]
    if let master, master.cursor.frames > 0 {
      objects = [
        .init(
          objectId: masterID,
          index: 0,
          contentType: "audio/x-caf",
          byteLength: Int(master.cursor.stableBytes),
          sha256: master.sha256,
          startMs: 0,
          endMs: master.durationMs,
          channelMap: [
            .init(channelIndex: 0, trackId: microphoneTrackID),
            .init(channelIndex: 1, trackId: applicationTrackID),
          ]
        )
      ]
    } else {
      objects = []
    }
    return try Contract.encode(
      AudioManifest(
        schemaVersion: 1,
        callId: callID,
        manifestId: audioManifestID,
        durationMs: master?.durationMs ?? 0,
        mediaProfileId: MediaMasterProfile.id,
        objects: objects
      )
    )
  }
}

private func captureID() -> String { UUID().uuidString.lowercased() }

private func intervalDocuments(_ intervals: [CaptureInterval]) -> [TrackInterval] {
  intervals.map {
    .init(
      startMs: $0.startMs,
      endMs: $0.endMs,
      state: $0.state.rawValue,
      reason: $0.state == .recorded ? nil : $0.state.rawValue
    )
  }
}
