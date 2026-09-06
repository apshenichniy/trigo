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

public enum CaptureFinalizationPoint: Sendable { case afterFinalizationIntent, afterAudioManifest }

private struct CaptureFinalization: Codable {
  let media: CapturedMedia
  let reason: String?
}

/// Durable capture identities are allocated locally before a stream is opened. Canonical
/// publication uses LocalArchive's validation and LocalLifecycleStore's independent state.
public struct CaptureArchiveSession: Codable, Sendable {
  public let root: URL
  public let archiveID: String
  public let callID: String
  public let microphoneTrackID: String
  public let applicationTrackID: String
  public let audioManifestID: String
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
    try requireCanonicalIdentifier(archiveID)
    let session = Self(
      root: root, archiveID: archiveID, callID: captureID(), microphoneTrackID: captureID(),
      applicationTrackID: captureID(), audioManifestID: captureID(), startedAt: startedAt,
      source: source, microphone: microphone)
    try AtomicFileWriter(interruption: { _ in }).write(
      try JSONEncoder().encode(session),
      to: session.sessionURL, domain: .archive)
    let archive = try LocalArchive(root: root, archiveID: archiveID)
    _ = try await archive.publishManifest(
      session.callBytes(media: nil, reason: nil, version: 1, reference: nil))
    let lifecycle = try LocalLifecycleStore(root: root, archiveID: archiveID)
    _ = try await lifecycle.publish(.initial(archiveID: archiveID, callID: session.callID))
    return session
  }

  public func finish(
    media: CapturedMedia, interruptionReason: String?,
    interruption: @Sendable (CaptureFinalizationPoint) throws -> Void = { _ in }
  ) async throws
    -> LocalCallAggregate
  {
    try requireCaptureInterruptionReason(interruptionReason)
    let archive = try LocalArchive(root: root, archiveID: archiveID)
    let existing = try await archive.loadCall(callID: callID)
    let current = try jsonObject(existing.manifest.storedBytes)
    // A final canonical reference is immutable. Repeated recovery does not replace its object IDs.
    if current["audioManifest"] is [String: Any] {
      try await publishLifecycle(reason: current["interruptionReason"] as? String)
      return existing
    }
    let finalization: CaptureFinalization
    if FileManager.default.fileExists(atPath: finalizationURL.path) {
      finalization = try JSONDecoder().decode(
        CaptureFinalization.self, from: Data(contentsOf: finalizationURL))
    } else {
      finalization = .init(media: media, reason: interruptionReason)
      try AtomicFileWriter(interruption: { _ in }).write(
        try JSONEncoder().encode(finalization),
        to: finalizationURL, domain: .archive)
    }
    try interruption(.afterFinalizationIntent)
    let media = finalization.media
    let interruptionReason = finalization.reason
    try requireCaptureInterruptionReason(interruptionReason)
    let audio = try audioBytes(media)
    let preReference = try callBytes(
      media: media, reason: interruptionReason, version: 2, reference: nil)
    if (existing.manifest.documentVersion ?? 0) < 2 {
      _ = try await archive.publishManifest(preReference)
    }
    _ = try await archive.publishAudioManifest(audio)
    try interruption(.afterAudioManifest)
    _ = try await archive.publishManifest(
      callBytes(
        media: media, reason: interruptionReason, version: 3,
        reference: ["manifestId": audioManifestID, "sha256": Contract.hash(audio)]))
    try await publishLifecycle(reason: interruptionReason)
    return try await archive.loadCall(callID: callID)
  }

  public static func recover(root: URL, callID: String) async throws -> LocalCallAggregate {
    try requireCanonicalIdentifier(callID)
    let url = root.appendingPathComponent(callID).appendingPathComponent("capture-session.json")
    let session = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard session.root.standardizedFileURL.path == root.standardizedFileURL.path,
      session.callID == callID
    else {
      throw CaptureError.corruptCheckpoint
    }
    let archive = try LocalArchive(root: root, archiveID: session.archiveID)
    let existing = try await archive.loadCall(callID: callID)
    if try jsonObject(existing.manifest.storedBytes)["audioManifest"] is [String: Any] {
      try await session.publishLifecycle(
        reason: jsonObject(existing.manifest.storedBytes)["interruptionReason"] as? String)
      return existing
    }
    if FileManager.default.fileExists(atPath: session.finalizationURL.path) {
      let finalization = try JSONDecoder().decode(
        CaptureFinalization.self, from: Data(contentsOf: session.finalizationURL))
      return try await session.finish(
        media: finalization.media, interruptionReason: finalization.reason)
    }
    guard
      FileManager.default.fileExists(
        atPath: session.mediaDirectory.appendingPathComponent("media-checkpoint.json").path)
    else {
      return try await session.finish(
        media: CapturedMedia(objects: [], durationMs: 0), interruptionReason: "process_terminated")
    }
    let recovered = try CaptureMediaWriter.recover(directory: session.mediaDirectory)
    return try await session.finish(
      media: recovered.media,
      interruptionReason: recovered.interruptionReason)
  }

  private var sessionURL: URL {
    root.appendingPathComponent(callID).appendingPathComponent("capture-session.json")
  }

  private var finalizationURL: URL {
    root.appendingPathComponent(callID).appendingPathComponent("capture-finalization.json")
  }

  private func publishLifecycle(reason: String?) async throws {
    let store = try LocalLifecycleStore(root: root, archiveID: archiveID)
    if try await store.load(callID: callID) == nil {
      _ = try await store.publish(.initial(archiveID: archiveID, callID: callID))
    }
    _ = try await store.update(callID: callID) { snapshot in
      snapshot.capture = .init(
        state: reason == nil ? .stopped : .interrupted,
        failure: try reason.map { try .init(code: $0, retry: .never) })
    }
  }

  private func callBytes(
    media: CapturedMedia?, reason: String?, version: Int,
    reference: [String: Any]?
  ) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    let profile = try MediaProfile.selected()
    let tracks: [[String: Any]] = [
      [
        "trackId": microphoneTrackID, "role": "microphone",
        "inputDevice": microphone.map {
          ["id": $0.id, "name": $0.name]
        } as Any? ?? NSNull(), "mediaProfileId": profile.id.rawValue,
        "intervals": intervalObjects(media?.microphoneIntervals ?? []),
      ],
      [
        "trackId": applicationTrackID, "role": "application", "inputDevice": NSNull(),
        "mediaProfileId": profile.id.rawValue,
        "intervals": intervalObjects(media?.applicationIntervals ?? []),
      ],
    ]
    return try captureJSON([
      "schemaVersion": 1, "archiveId": archiveID, "callId": callID, "documentVersion": version,
      "startedAt": formatter.string(from: startedAt),
      "endedAt": media.map {
        formatter.string(from: startedAt.addingTimeInterval(Double($0.durationMs) / 1000))
      } as Any? ?? NSNull(),
      "durationMs": media?.durationMs as Any? ?? NSNull(),
      "captureState": media == nil ? "recording" : reason == nil ? "stopped" : "interrupted",
      "interruptionReason": reason as Any? ?? NSNull(),
      "source": [
        "applicationName": source.applicationName, "bundleId": source.bundleID,
        "processId": source.processID, "windowId": source.windowID,
        "windowTitle": source.windowTitle as Any? ?? NSNull(),
      ],
      "tracks": tracks, "audioManifest": reference as Any? ?? NSNull(),
      "revisions": [], "activeRevisionId": NSNull(), "speakerNames": [:],
    ])
  }

  private func audioBytes(_ media: CapturedMedia) throws -> Data {
    try captureJSON([
      "schemaVersion": 1, "callId": callID, "manifestId": audioManifestID,
      "durationMs": media.durationMs, "mediaProfileId": MediaProfile.selected().id.rawValue,
      "objects": media.objects.map { object -> [String: Any] in
        [
          "objectId": object.objectID, "index": object.index, "contentType": "audio/wav",
          "byteLength": object.byteLength, "sha256": object.sha256, "startMs": object.startMs,
          "endMs": object.endMs,
          "channelMap": [
            ["channelIndex": 0, "trackId": microphoneTrackID],
            ["channelIndex": 1, "trackId": applicationTrackID],
          ],
        ]
      },
    ])
  }
}

private func captureID() -> String { UUID().uuidString.lowercased() }

private func intervalObjects(_ intervals: [CaptureInterval]) -> [[String: Any]] {
  intervals.map {
    [
      "startMs": $0.startMs, "endMs": $0.endMs, "state": $0.state.rawValue,
      "reason": $0.state == .recorded ? NSNull() : $0.state.rawValue as Any,
    ]
  }
}

private func captureJSON(_ object: [String: Any]) throws -> Data {
  try JSONSerialization.data(
    withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}
