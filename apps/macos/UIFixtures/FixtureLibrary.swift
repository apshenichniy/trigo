import AppKit
import TrigoContracts

@testable import TrigoNative

/// This factory is compiled only into the isolated UI executable. It restores explicitly
/// synthetic, validated snapshots through the real repository and uses no HTTP or audio device.
enum FixtureLibrary {
  static let readyID = "00000000-0000-4000-8000-000000000200"
  static let pendingID = "00000000-0000-4000-8000-000000000201"
  static let quietID = "00000000-0000-4000-8000-000000000202"
  static let conflictID = "00000000-0000-4000-8000-000000000203"

  @MainActor static func model(
    configuration: FixtureConfiguration,
    namespace: AppNamespace
  ) -> LibraryModel {
    let clock = LibraryDate.date(configuration.clock)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: configuration.timeZone)!
    return LibraryModel(
      preferences: UserDefaults(suiteName: namespace.preferences)!,
      clock: { clock },
      calendar: { calendar }
    ) {
      let repository = try LocalRepository(
        root: namespace.archive,
        archiveID: FixtureConfiguration.archiveID
      )
      if try await repository.callIDs().isEmpty { try await seed(repository, clock: clock) }
      return .init(
        repository: repository,
        player: .init(transport: FixtureReaderPlayback(), output: FixtureReaderOutput()),
        retry: { _ in }
      )
    }
  }

  private static func seed(_ repository: LocalRepository, clock: Date) async throws {
    let ready = try contents(
      callID: readyID,
      title: "Synthetic review",
      started: clock.addingTimeInterval(-300),
      twoRevisions: true
    )
    _ = try await repository.restoreReplica(ready)
    let quiet = try contents(
      callID: quietID,
      title: "Synthetic quiet recording",
      started: clock.addingTimeInterval(-86_400),
      noSpeech: true
    )
    _ = try await repository.restoreReplica(quiet)
    let conflict = try contents(
      callID: conflictID,
      title: "Synthetic annotation conflict",
      started: clock.addingTimeInterval(-172_800)
    )
    _ = try await repository.restoreReplica(conflict)
    var remote = try Contract.decodeCallSnapshot(conflict.document).value
    let revisionID = remote.activeRevisionId!
    let revision =
      try Contract.decode(TranscriptRevision.self, bytes: conflict.revisions[revisionID]!).value
    _ = try await repository.setSpeakerName(
      "This Mac's fixture name",
      callID: conflictID,
      revisionID: revisionID,
      speakerID: revision.speakers[0].speakerId
    )
    remote.documentVersion += 1
    remote.speakerNames[revisionID] = [revision.speakers[0].speakerId: "Server fixture name"]
    try await repository.recordReplicaConflict(
      .init(
        document: Contract.encode(remote),
        audioManifest: conflict.audioManifest,
        revisions: conflict.revisions,
        provenance: conflict.provenance,
        receipt: conflict.receipt
      )
    )

    var pending = try Contract.decodeCallSnapshot(ready.document).value
    pending.callId = pendingID
    pending.source.applicationName = "Synthetic capture"
    pending.startedAt = timestamp(clock.addingTimeInterval(-3600))
    pending.endedAt = timestamp(clock.addingTimeInterval(-3599))
    pending.audioManifest = nil; pending.revisions = []; pending.activeRevisionId = nil
    pending.speakerNames = [:]; pending.speakerGroups = [:]
    _ = try await repository.publishManifest(Contract.encode(pending))
    try repository.recordSynchronizationStatus(.init(code: "server_unavailable", retry: .retryable))
  }

  private static func contents(
    callID: String,
    title: String,
    started: Date,
    noSpeech: Bool = false,
    twoRevisions: Bool = false
  ) throws -> ServerReplicaContents {
    var call = try Contract.decode(CallDocument.self, bytes: fixture("call")).value
    call.archiveId = FixtureConfiguration.archiveID; call.callId = callID
    call.documentVersion = 2
    call.startedAt = timestamp(started); call.endedAt = timestamp(started.addingTimeInterval(1))
    call.source.applicationName = title
    call.source.bundleId = "io.github.apshenichniy.trigo.fixture.focus"
    call.source.windowTitle =
      "Controlled sample for wrapping paragraphs, retained revisions and explicit speaker names"
    call.speakerNames = [:]; call.speakerGroups = [:]
    for index in call.tracks.indices { call.tracks[index].mediaProfileId = MediaMasterProfile.id }
    var audio = try Contract.decode(AudioManifest.self, bytes: fixture("valid-audio")).value
    audio.callId = callID; audio.manifestId = UUID().uuidString.lowercased()
    audio.mediaProfileId = MediaMasterProfile.id
    audio.objects[0].objectId = UUID().uuidString.lowercased()
    audio.objects[0].contentType = "audio/x-caf"
    let media = MediaMasterProfile.header + Data(repeating: 0, count: 64_000)
    audio.objects[0].byteLength = media.count
    audio.objects[0].sha256 = Contract.hash(media)
    let audioBytes = try Contract.encode(audio)
    call.audioManifest = .init(manifestId: audio.manifestId, sha256: Contract.hash(audioBytes))
    var revisions: [String: Data] = [:]
    call.revisions = []
    for index in 0..<(twoRevisions ? 2 : 1) {
      var revision =
        try Contract.decode(TranscriptRevision.self, bytes: fixture("grouping-revision")).value
      revision.callId = callID; revision.revisionId = UUID().uuidString.lowercased()
      revision.createdAt = timestamp(started.addingTimeInterval(Double(60 + index * 60)))
      revision.audioManifest = call.audioManifest!
      revision.asr.adapter = "synthetic-ui-fixture"; revision.asr.model = "synthetic-ui-fixture"
      let replacements = Dictionary(
        uniqueKeysWithValues: revision.speakers.map {
          ($0.speakerId, UUID().uuidString.lowercased())
        }
      )
      for i in revision.speakers.indices {
        revision.speakers[i].speakerId = replacements[revision.speakers[i].speakerId]!
      }
      for i in revision.turns.indices {
        revision.turns[i].turnId = UUID().uuidString.lowercased()
        revision.turns[i].speakerId = revision.turns[i].speakerId.flatMap { replacements[$0] }
        revision.turns[i].words = []
      }
      revision.turns[0].text =
        "This is a controlled transcript paragraph for the library acceptance run. It contains no private call content. The text should wrap naturally when the reader becomes narrow, while its original timestamp and scoped speaker label remain accessible."
      revision.turns[1].text =
        index == 0
        ? "This retained revision stays readable while a newer result is available."
        : "This is the current synthetic revision. Names and groups remain explicit annotations."
      revision.turns[1].speakerId = revision.speakers[1].speakerId
      revision.turns[1].trackId = revision.speakers[1].trackId
      for index in 0..<2 {
        var speaker = revision.speakers[index]
        speaker.speakerId = UUID().uuidString.lowercased()
        speaker.diarizationScopeId = UUID().uuidString.lowercased()
        speaker.trackId = call.tracks.first(where: { $0.role == "microphone" })!.trackId
        revision.speakers.append(speaker)
        var turn = revision.turns[index]
        turn.turnId = UUID().uuidString.lowercased()
        turn.speakerId = speaker.speakerId
        turn.trackId = speaker.trackId
        turn.text =
          "Synthetic microphone passage \(index + 1). This separate source and scope remain inspectable when the owner groups labels."
        revision.turns.append(turn)
      }
      for index in revision.turns.indices {
        revision.turns[index].startMs = 100 + index * 200
        revision.turns[index].endMs = 250 + index * 200
      }
      var unknown = revision.turns[0]
      unknown.turnId = UUID().uuidString.lowercased(); unknown.speakerId = nil
      unknown.startMs = 900; unknown.endMs = 950
      unknown.text = "This passage has unknown speaker attribution. No identity is inferred."
      if twoRevisions && index == 1 {
        revision.normalizationVersion = 2
        revision.turns[0].endMs = 1000
        revision.turns[0].words = [
          .init(
            text: revision.turns[0].text,
            startMs: 100,
            endMs: 1200,
            confidence: nil,
            timingUncertain: true
          )
        ]
        unknown.startMs = 1000; unknown.endMs = 1000
        unknown.words = [
          .init(
            text: unknown.text,
            startMs: 1050,
            endMs: 1200,
            confidence: nil,
            timingUncertain: true
          )
        ]
      }
      revision.turns.append(unknown)
      if noSpeech { revision.turns = []; revision.speakers = [] }
      let bytes = try Contract.encode(revision)
      revisions[revision.revisionId] = bytes
      call.revisions.append(
        .init(
          revisionId: revision.revisionId,
          createdAt: revision.createdAt,
          sha256: Contract.hash(bytes)
        )
      )
      call.activeRevisionId = revision.revisionId
    }
    var states = try MasterUploadSourceStates(durationMs: 1000)
    for (channel, track) in call.tracks.enumerated() {
      for interval in track.intervals { try states.append(interval, channel: channel) }
    }
    let receipt = VerifiedMasterReceipt(
      schemaVersion: 1,
      archiveId: call.archiveId,
      callId: callID,
      uploadId: UUID().uuidString.lowercased(),
      masterId: audio.objects[0].objectId,
      operationId: UUID().uuidString.lowercased(),
      receiptId: UUID().uuidString.lowercased(),
      verification: "complete-master-sha256-v1",
      mediaProfileId: MediaMasterProfile.id,
      masterSHA256: Contract.hash(media),
      sourceStatesSHA256: Contract.hash(try states.finish()),
      byteLength: media.count,
      durationMs: 1000,
      channelMap: call.tracks.enumerated()
        .map { .init(channelIndex: $0.offset, trackId: $0.element.trackId) },
      audioManifest: call.audioManifest!,
      storedAt: timestamp(started.addingTimeInterval(2))
    )
    return try .init(
      document: Contract.encode(call),
      audioManifest: audioBytes,
      revisions: revisions,
      provenance: [:],
      receipt: Contract.decode(VerifiedMasterReceipt.self, bytes: Contract.encode(receipt))
    )
  }

  private static func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json") else {
      throw FixtureFailure.invalidConfiguration
    }
    return try Data(contentsOf: url)
  }

  private static func timestamp(_ value: Date) -> String {
    ISO8601DateFormatter().string(from: value)
  }
}

private actor FixtureReaderPlayback: CallPlaybackTransport {
  private var expiredReady = false
  private var failedQuiet = false
  func grant(callID: String, operationID: String) throws -> PlaybackAccess {
    guard
      [FixtureLibrary.readyID, FixtureLibrary.quietID, FixtureLibrary.conflictID].contains(callID)
    else { throw CallPlaybackError.notStored }
    let grant = PlaybackGrant(
      schemaVersion: 1,
      operationId: operationID,
      grantId: UUID().uuidString.lowercased(),
      archiveId: FixtureConfiguration.archiveID,
      callId: callID,
      expiresAt: "2099-01-01T00:00:00Z",
      token: "trigo_playback_v1_" + String(repeating: "a", count: 64),
      media: .init(
        masterId: "00000000-0000-4000-8000-000000000204",
        masterSHA256: String(repeating: "a", count: 64),
        profileId: "wav-pcm-s16le-16000-stereo-segment-v1",
        sampleRateHz: 16000,
        frameCount: 16000,
        segmentFrames: 480000,
        segmentCount: 1,
        channels: [
          .init(
            channelIndex: 0,
            trackId: "00000000-0000-4000-8000-000000000002",
            role: "microphone"
          ),
          .init(
            channelIndex: 1,
            trackId: "00000000-0000-4000-8000-000000000003",
            role: "application"
          ),
        ]
      )
    )
    return .init(
      grant: grant,
      binding: .init(
        serverURL: URL(string: "https://fixture.invalid")!,
        archiveId: FixtureConfiguration.archiveID,
        stage: .dev
      )
    )
  }

  func segment(access: PlaybackAccess, index: Int) throws -> PlaybackPCM {
    guard index == 0 else { throw CallPlaybackError.invalidMedia }
    if access.grant.callId == FixtureLibrary.readyID && !expiredReady {
      expiredReady = true
      throw CallPlaybackError.grantExpired
    }
    if access.grant.callId == FixtureLibrary.quietID && !failedQuiet {
      failedQuiet = true
      throw CallPlaybackError.transport(code: "playback_storage_unavailable", retry: .retryable)
    }
    return try .init(startFrame: 0, frameCount: 16000, samples: Data(repeating: 0, count: 64000))
  }
}

/// Holds the rendered cursor for deterministic control assertions; no device is opened.
@MainActor private final class FixtureReaderOutput: PlaybackAudioOutput {
  var renderedFrames: Int { 0 }
  func enqueue(_ pcm: PlaybackPCM, completed: @escaping @MainActor @Sendable () -> Void) {}
  func play() {}
  func pause() {}
  func stop() {}
}
