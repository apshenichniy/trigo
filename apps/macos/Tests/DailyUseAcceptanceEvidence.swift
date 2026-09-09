import AVFoundation
import Foundation
import TrigoContracts

@testable import TrigoNative

@MainActor func verifyDailyUseResult(
  context: DailyUseAcceptanceContext,
  plan: DailyUsePlan,
  repository: LocalRepository,
  transport: DailyUseAdmittedSync,
  synchronization: CanonicalSyncCoordinator,
  runFolder: URL,
  operation: TranscriptionOperation
) async throws -> [String: Any] {
  let result = try requiredDailyUse(operation.result, "The operation has no retained result.")
  try requireDailyUse(
    operation.state == "result_available" && operation.failure == nil
      && operation.operationId == plan.transcriptionOperationID && operation.callId == plan.callID
      && operation.archiveId == plan.archiveID && operation.revisionId == plan.revisionID
      && (1...2).contains(operation.attemptCount) && result.revisionId == plan.revisionID,
    "The automatic operation did not publish the admitted complete result."
  )
  let revisionBytes = try await repository.transcriptRevisionBytes(
    callID: plan.callID,
    revisionID: plan.revisionID
  )
  let provenanceBytes = try requiredDailyUse(
    try repository.transcriptProvenanceBytes(revisionID: plan.revisionID),
    "Local import did not retain provenance."
  )
  let revision = try Contract.decode(TranscriptRevision.self, bytes: revisionBytes).value
  let receipt = try requiredDailyUse(
    try repository.verifiedMasterReceipt(callID: plan.callID),
    "The master receipt is missing."
  )
  try requireDailyUse(
    result.sha256 == Contract.hash(revisionBytes) && result.byteLength == revisionBytes.count
      && result.provenanceSHA256 == Contract.hash(provenanceBytes)
      && result.provenanceByteLength == provenanceBytes.count
      && revision.callId == plan.callID && revision.revisionId == plan.revisionID,
    "Imported transcript or provenance bytes differ from the available server result."
  )
  try writeDailyUseBytes(revisionBytes, to: runFolder.appending(path: "revision.json"))
  try writeDailyUseBytes(provenanceBytes, to: runFolder.appending(path: "provenance.json"))
  let providerProof = try verifyDailyUseProvenance(
    bytes: provenanceBytes,
    revision: revision,
    receipt: receipt.value,
    plan: plan,
    template: context.template,
    local: context.invocation.local
  )
  try writeDailyUseJSON(providerProof, to: runFolder.appending(path: "provider-proof.json"))
  if !context.invocation.local {
    let markers = providerProof["markerCoverage"] as? [String: Any]
    try requireDailyUse(
      markers?["startMiddleFinalSourcesPresent"] as? Bool == true,
      "The hosted transcript lacks a controlled start, middle or final source marker. Inspect the retained coverage report."
    )
  }
  let annotationProof = try await verifyDailyUseAnnotations(
    repository: repository,
    synchronization: synchronization,
    plan: plan,
    revision: revision,
    revisionBytes: revisionBytes,
    local: context.invocation.local
  )
  let annotated = try await repository.loadCall(callID: plan.callID)
  try writeDailyUseBytes(
    annotated.manifest.storedBytes,
    to: runFolder.appending(path: "canonical.json")
  )
  let fresh = try LocalRepository(
    root: runFolder.appending(path: "Restored", directoryHint: .isDirectory),
    archiveID: plan.archiveID
  )
  let restoration = CanonicalSyncCoordinator(
    repository: fresh,
    transport: transport,
    language: { "en" }
  )
  try await awaitDailyUseReplica(
    repository: fresh,
    synchronization: restoration,
    callID: plan.callID
  )
  let restored = try await fresh.loadCall(callID: plan.callID)
  try requireDailyUse(
    restored.manifest.storedBytes == annotated.manifest.storedBytes
      && restored.transcriptRevisions[plan.revisionID] == revisionBytes
      && restored.audioManifest == annotated.audioManifest
      && restored.manifest.value.activeRevisionId == plan.revisionID
      && (try fresh.transcriptProvenanceBytes(revisionID: plan.revisionID)) == provenanceBytes,
    "Fresh restoration did not preserve exact canonical, transcript, annotation and provenance bytes."
  )
  try requireDailyUse(
    try await fresh.captureSession(callID: plan.callID) == nil,
    "Fresh restoration unexpectedly relies on a local capture or media session."
  )
  let playbackProof = try await verifyDailyUseReaderPlayback(
    context: context,
    plan: plan,
    fresh: fresh,
    revision: revision
  )
  return [
    "revisionSHA256": result.sha256, "provenanceSHA256": result.provenanceSHA256,
    "canonicalSHA256": annotated.manifest.sha256, "turnCount": revision.turns.count,
    "speakerCount": revision.speakers.count, "provider": providerProof,
    "annotations": annotationProof, "freshRestorationExact": true,
    "playback": playbackProof,
  ]
}

@MainActor private func awaitDailyUseReplica(
  repository: LocalRepository,
  synchronization: CanonicalSyncCoordinator,
  callID: String
) async throws {
  for _ in 0..<60 {
    let report = try await synchronization.runPass(retryAfterCorrection: false)
    try requireDailyUse(report.catalogFailure == nil, "Restoration cannot read the server catalog.")
    if let failure = report.failures[callID], failure.retry != .retryable {
      throw DailyUseAcceptanceFailure(description: "Replica needs correction: \(failure.code).")
    }
    if try await repository.isCallSavedOnMacAndServer(callID: callID) { return }
    try await Task.sleep(for: .seconds(1))
  }
  throw DailyUseAcceptanceFailure(
    description: "The admitted call's canonical replica did not become confirmed."
  )
}

@MainActor private func verifyDailyUseAnnotations(
  repository: LocalRepository,
  synchronization: CanonicalSyncCoordinator,
  plan: DailyUsePlan,
  revision: TranscriptRevision,
  revisionBytes: Data,
  local: Bool
) async throws -> [String: Any] {
  if local {
    return ["applicable": false, "reason": "The fake provider intentionally returns no speakers."]
  }
  let microphone = try requiredDailyUse(
    revision.speakers.first { $0.trackId == plan.microphoneTrackID },
    "Hosted microphone speaker is absent."
  )
  let application = try requiredDailyUse(
    revision.speakers.first { $0.trackId == plan.applicationTrackID },
    "Hosted application speaker is absent."
  )
  try requireDailyUse(
    microphone.speakerId != application.speakerId
      && microphone.diarizationScopeId != application.diarizationScopeId,
    "Provider speaker labels were collapsed across source scopes."
  )
  let name = "Zoë · Олена 🎙️"
  let groupName = "Controlled source attribution"
  let groupID = synchronizationIdentity("daily-use-group:\(plan.callID)")
  var current = try await repository.call(callID: plan.callID)
  if current.speakerNames[plan.revisionID]?[microphone.speakerId] != name {
    _ = try await repository.editSpeakerAnnotations(
      .init(
        operationID: synchronizationIdentity("daily-use-name:\(plan.callID)"),
        callID: plan.callID,
        revisionID: plan.revisionID,
        expectedDocumentVersion: current.documentVersion,
        mutation: .rename(speakerID: microphone.speakerId, name: name)
      )
    )
  }
  current = try await repository.call(callID: plan.callID)
  if current.speakerGroups[plan.revisionID]?.contains(where: { $0.groupId == groupID }) != true {
    _ = try await repository.editSpeakerAnnotations(
      .init(
        operationID: synchronizationIdentity("daily-use-group-edit:\(plan.callID)"),
        callID: plan.callID,
        revisionID: plan.revisionID,
        expectedDocumentVersion: current.documentVersion,
        mutation: .group(
          groupID: groupID,
          displayName: groupName,
          speakerIDs: [microphone.speakerId, application.speakerId]
        )
      )
    )
  }
  try await awaitDailyUseReplica(
    repository: repository,
    synchronization: synchronization,
    callID: plan.callID
  )
  current = try await repository.call(callID: plan.callID)
  let group = current.speakerGroups[plan.revisionID]?.first { $0.groupId == groupID }
  let unchanged = try await repository.transcriptRevisionBytes(
    callID: plan.callID,
    revisionID: plan.revisionID
  )
  try requireDailyUse(
    unchanged == revisionBytes && current.activeRevisionId == plan.revisionID
      && current.speakerNames[plan.revisionID]?[microphone.speakerId] == name
      && group?.displayName == groupName
      && Set(group?.speakerIds ?? []) == Set([microphone.speakerId, application.speakerId]),
    "Confirmed naming/grouping changed evidence or lost scoped annotations."
  )
  return [
    "applicable": true, "unicodeNameExact": true, "crossScopeGroupConfirmed": true,
    "immutableRevisionUnchanged": true,
  ]
}

@MainActor private func verifyDailyUseReaderPlayback(
  context: DailyUseAcceptanceContext,
  plan: DailyUsePlan,
  fresh: LocalRepository,
  revision: TranscriptRevision
) async throws -> [String: Any] {
  let engine = AVAudioEngine()
  let output = AVPlaybackAudioOutput(engine: engine)
  let format = try requiredDailyUse(
    AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2),
    "Audio format unavailable."
  )
  try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
  let player = CallAudioPlayer(
    transport: HTTPPlaybackTransport(connection: context.connection, archiveID: plan.archiveID),
    output: output
  )
  defer { player.clear() }
  let preferencesName = "test.trigo.daily-use.\(context.invocation.invocationId)"
  let preferences = try requiredDailyUse(
    UserDefaults(suiteName: preferencesName),
    "Reader preferences unavailable."
  )
  defer { preferences.removePersistentDomain(forName: preferencesName) }
  let reader = LibraryModel(preferences: preferences) {
    .init(repository: fresh, player: player, retry: { _ in })
  }
  defer { reader.close() }
  reader.selectCall(plan.callID)
  await reader.refresh()
  let selected = try requiredDailyUse(
    reader.selectedCall,
    "The restored call is absent from the reader."
  )
  try requireDailyUse(
    reader.failure == nil && reader.selectedRevisionID == plan.revisionID
      && reader.selectedRevision?.turnCount == revision.turns.count
      && LibraryCallStatus(selected).title == "Ready — saved on this Mac and server"
      && reader.canPlay,
    "The actual reader does not expose the restored Ready call with retained audio."
  )
  let passages = try await dailyUseReaderPassages(reader, revision: revision)
  // The same paged projections rendered by the reader supply these timestamp actions.
  let transcriptPositions =
    passages.isEmpty
    ? []
    : [
      passages[0].startMs, passages[passages.count / 2].startMs,
      passages[passages.count - 1].startMs,
    ]
  let blocks = plan.durationMs / 20_000
  let sourcePositions = [0, blocks / 2, blocks - 1]
    .flatMap { block in
      [1500, 6000, 12_500].map { block * 20_000 + $0 }
    }
  let positions = Set(
    transcriptPositions + sourcePositions + [29_998, 30_000, plan.durationMs - 8]
  )
  .sorted()
  var nonzeroSamples = [0, 0]
  for position in positions {
    try requireDailyUse(
      position >= 0 && position + 8 <= plan.durationMs,
      "A playback sample exceeds the master."
    )
    await reader.seek(to: position, play: true)
    try requireDailyUse(
      reader.playback.phase == .playing && reader.playback.positionMs == position
        && reader.playback.durationMs == plan.durationMs,
      "Timestamp playback could not reach \(position) ms after local cleanup."
    )
    let buffer = try requiredDailyUse(
      AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128),
      "Audio buffer unavailable."
    )
    try requireDailyUse(
      try engine.renderOffline(128, to: buffer) == .success && buffer.frameLength == 128,
      "Audio rendering failed."
    )
    let channels = try requiredDailyUse(
      buffer.floatChannelData,
      "Stereo audio samples unavailable."
    )
    for frame in 0..<128 {
      for channel in 0..<2 {
        let expected = context.template.sample(
          frame: position * 16 + frame,
          channel: channel,
          durationMs: plan.durationMs
        )
        if expected != 0 { nonzeroSamples[channel] += 1 }
        try requireDailyUse(
          abs(channels[channel][frame] - Float(expected) / 32768) < 0.0001,
          "Rendered source \(channel) at \(position) ms differs from its retained master frame \(frame)."
        )
      }
    }
    player.pause()
  }
  try requireDailyUse(
    nonzeroSamples.allSatisfy { $0 > 0 },
    "Playback evidence contains only silence for a source."
  )
  reader.close()
  try requireDailyUse(player.state.phase != .playing, "Closing the reader left playback active.")
  return [
    "adapter": "actual-http-and-AVAudioEngine-offline", "audioDeviceUsed": false,
    "positionsMs": positions, "transcriptPositionsMs": transcriptPositions,
    "readerPassagesVerified": passages.count,
    "samplesComparedPerChannelPerPosition": 128, "nonzeroSamplesPerChannel": nonzeroSamples,
    "sourceChannelsExact": true, "readerClosePaused": true,
  ]
}

@MainActor func dailyUseReaderPassages(
  _ reader: LibraryModel,
  revision: TranscriptRevision
) async throws -> [LocalTurn] {
  while reader.hasMoreTurns {
    let priorCount = reader.turns.count
    await reader.loadMoreTurns()
    try requireDailyUse(
      reader.failure == nil && reader.turns.count > priorCount
        && reader.turns.count <= revision.turns.count,
      "The reader cannot reach a remaining page of the retained transcript."
    )
  }
  try requireDailyUse(
    reader.turns.count == revision.turns.count
      && zip(reader.turns, revision.turns)
        .allSatisfy { projected, evidence in
          projected.turnID == evidence.turnId && projected.trackID == evidence.trackId
            && projected.speakerID == evidence.speakerId && projected.text == evidence.text
            && projected.startMs == evidence.startMs && projected.endMs == evidence.endMs
        },
    "The reader's complete paged transcript differs from retained evidence."
  )
  return reader.turns
}
