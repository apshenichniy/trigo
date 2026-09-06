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
    root: URL, archiveID: String, source: CaptureSource,
    microphone: CaptureMicrophone?, startedAt: Date = Date()
  ) async throws -> Self {
    let session = try allocate(
      root: root, archiveID: archiveID, source: source,
      microphone: microphone, startedAt: startedAt)
    do { try await session.prepare() } catch {
      throw CapturePreparationFailure(session: session, underlying: error)
    }
    return session
  }

  /// Keep this identity before the first durable write, including when that write fails.
  public static func allocate(
    root: URL, archiveID: String, source: CaptureSource,
    microphone: CaptureMicrophone?, startedAt: Date = Date()
  ) throws -> Self {
    try requireCanonicalIdentifier(archiveID)
    return Self(
      root: try canonicalRepositoryRoot(root), archiveID: archiveID, callID: captureID(),
      microphoneTrackID: captureID(),
      applicationTrackID: captureID(), audioManifestID: captureID(), masterID: captureID(),
      startedAt: startedAt,
      source: source, microphone: microphone)
  }

  public var mediaMasterIdentity: MediaMasterIdentity {
    .init(
      masterID: UUID(uuidString: masterID)!, callID: UUID(uuidString: callID)!,
      microphoneTrackID: UUID(uuidString: microphoneTrackID)!,
      applicationTrackID: UUID(uuidString: applicationTrackID)!)
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
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  }

  public func requestStop(reason: String?) async throws {
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    try await repository.requestCaptureStop(callID: callID, reason: reason)
  }

  public func finish(
    media: CapturedMedia, interruptionReason: String?,
    interruption: @escaping @Sendable (CaptureFinalizationPoint) throws -> Void = { _ in }
  ) async throws -> LocalCallAggregate {
    try requireCaptureInterruptionReason(interruptionReason)
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    try await repository.requestCaptureStop(callID: callID, reason: interruptionReason)
    try interruption(.afterStopIntent)
    return try await repository.finalizeCapture(self, media: media, reason: interruptionReason) {
      point in
      if point == .beforeRepositoryCommit { try interruption(.beforeCommit) }
      if point == .afterRepositoryCommit { try interruption(.afterCommit) }
    }
  }

  public static func recover(root: URL, archiveID: String, callID: String) async throws
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
    try await prepare()
    let repository = try LocalRepository(root: root, archiveID: archiveID)
    let existing = try await repository.loadCall(callID: callID)
    if existing.manifest.value.audioManifest != nil { return existing }
    if let sealed = try await repository.resumeLegacyCaptureSeal(callID: callID) { return sealed }
    let requested = try await repository.captureStopRequest(callID: callID)
    guard
      FileManager.default.fileExists(
        atPath: mediaDirectory.appendingPathComponent("media-checkpoint.json").path)
    else {
      return try await finish(
        media: CapturedMedia(objects: [], durationMs: 0),
        interruptionReason: requested.map { $0.reason } ?? "process_terminated")
    }
    let recovered = try CaptureMediaWriter.recover(directory: mediaDirectory)
    return try await finish(
      media: recovered.media,
      interruptionReason: requested.map { $0.reason } ?? recovered.interruptionReason)
  }

  func callBytes(
    media: CapturedMedia?, reason: String?, version: Int,
    reference: AudioManifestReference?
  ) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    let profile = try MediaProfile.selected()
    let tracks: [AudioTrack] = [
      .init(
        trackId: microphoneTrackID, role: "microphone",
        inputDevice: microphone.map { .init(id: $0.id, name: $0.name) },
        mediaProfileId: profile.id.rawValue,
        intervals: intervalDocuments(media?.microphoneIntervals ?? [])),
      .init(
        trackId: applicationTrackID, role: "application", inputDevice: nil,
        mediaProfileId: profile.id.rawValue,
        intervals: intervalDocuments(media?.applicationIntervals ?? [])),
    ]
    return try Contract.encode(
      CallDocument(
        schemaVersion: 1, archiveId: archiveID, callId: callID, documentVersion: version,
        startedAt: formatter.string(from: startedAt),
        endedAt: media.map {
          formatter.string(from: startedAt.addingTimeInterval(Double($0.durationMs) / 1000))
        },
        durationMs: media?.durationMs,
        captureState: media == nil ? "recording" : reason == nil ? "stopped" : "interrupted",
        interruptionReason: reason,
        source: .init(
          applicationName: source.applicationName, bundleId: source.bundleID,
          processId: Int(source.processID), windowId: Int(source.windowID),
          windowTitle: source.windowTitle),
        tracks: tracks, audioManifest: reference, revisions: [], activeRevisionId: nil,
        speakerNames: [:]))
  }

  func audioBytes(_ media: CapturedMedia) throws -> Data {
    try Contract.encode(
      AudioManifest(
        schemaVersion: 1, callId: callID, manifestId: audioManifestID,
        durationMs: media.durationMs, mediaProfileId: MediaProfile.selected().id.rawValue,
        objects: media.objects.map { object in
          .init(
            objectId: object.objectID, index: object.index, contentType: "audio/wav",
            byteLength: object.byteLength, sha256: object.sha256, startMs: object.startMs,
            endMs: object.endMs,
            channelMap: [
              .init(channelIndex: 0, trackId: microphoneTrackID),
              .init(channelIndex: 1, trackId: applicationTrackID),
            ])
        }))
  }
}

private func captureID() -> String { UUID().uuidString.lowercased() }

private func intervalDocuments(_ intervals: [CaptureInterval]) -> [TrackInterval] {
  intervals.map {
    .init(
      startMs: $0.startMs, endMs: $0.endMs, state: $0.state.rawValue,
      reason: $0.state == .recorded ? nil : $0.state.rawValue)
  }
}
