import Foundation
import TrigoContracts

public actor LocalArchive {
  private let root: URL
  private let archiveID: String
  private let writer: AtomicFileWriter

  public init(
    root: URL, archiveID: String,
    interruption: @escaping PersistenceInterruption = { _ in }
  ) throws {
    try requireCanonicalIdentifier(archiveID)
    self.root = root
    self.archiveID = archiveID
    self.writer = AtomicFileWriter(interruption: interruption)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  /// Publishes a validated manifest by atomic replacement.
  ///
  /// A changed manifest must advance `documentVersion`, match this archive's supplied identity,
  /// and resolve every reference to already-published immutable bytes.
  public func publishManifest(_ bytes: Data) throws -> PublicationResult {
    try publishManifest(bytes, allowedSpeakerNameChange: nil)
  }

  private func publishManifest(
    _ bytes: Data, allowedSpeakerNameChange: SpeakerNameChange?
  ) throws -> PublicationResult {
    let proposed = try Contract.decode(CallDocument.self, bytes: bytes)
    let metadata = callMetadata(proposed.value)
    try requireArchiveIdentity(metadata.archiveID)
    let destination = manifestURL(callID: metadata.callID)

    if FileManager.default.fileExists(atPath: destination.path) {
      let current = try loadCall(callID: metadata.callID)
      if current.manifest.storedBytes == bytes { return .alreadyPresent }
      let currentVersion = current.manifest.value.documentVersion
      guard metadata.documentVersion > currentVersion else {
        throw LocalPersistenceError.staleDocumentVersion(
          current: currentVersion, proposed: metadata.documentVersion)
      }
      try validateEvolution(
        from: current.manifest.value, to: proposed.value,
        allowedSpeakerNameChange: allowedSpeakerNameChange)
    }

    let references = try referenceBytes(for: metadata)
    _ = try Contract.validateArchive(proposed.storedBytes, references: references)
    try writer.write(bytes, to: destination, domain: .archive)
    return .committed
  }

  /// Publishes exact transcript bytes once. Repeating identical bytes is idempotent.
  public func publishTranscriptRevision(_ bytes: Data) throws -> PublicationResult {
    let document = try Contract.decode(TranscriptRevision.self, bytes: bytes)
    let callID = document.value.callId
    let revisionID = document.value.revisionId
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(revisionID)
    _ = try loadCall(callID: callID)
    try validateRevisionAudioReference(document.value, callID: callID)
    return try publishImmutable(
      bytes, to: revisionURL(callID: callID, revisionID: revisionID), identity: revisionID)
  }

  /// Publishes exact audio-manifest bytes once. Media objects remain owned by later modules.
  public func publishAudioManifest(_ bytes: Data) throws -> PublicationResult {
    let document = try Contract.decode(AudioManifest.self, bytes: bytes)
    let callID = document.value.callId
    let manifestID = document.value.manifestId
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(manifestID)
    let call = try loadCall(callID: callID)
    try validateAudioManifest(document.value, against: call.manifest.value)
    return try publishImmutable(
      bytes, to: audioManifestURL(callID: callID, manifestID: manifestID), identity: manifestID)
  }

  /// Loads a call only when its manifest, references, hashes, and archive identity all validate.
  public func loadCall(callID: String) throws -> LocalCallAggregate {
    try requireCanonicalIdentifier(callID)
    let destination = manifestURL(callID: callID)
    guard FileManager.default.fileExists(atPath: destination.path) else {
      throw LocalPersistenceError.callNotFound(callID)
    }
    let bytes = try Data(contentsOf: destination)
    let metadata = callMetadata(try Contract.decode(CallDocument.self, bytes: bytes).value)
    guard metadata.callID == callID else {
      throw LocalPersistenceError.invalidStoredDocument(
        "Call directory and document identity differ")
    }
    try requireArchiveIdentity(metadata.archiveID)
    let references = try referenceBytes(for: metadata)
    let manifest = try Contract.decodeArchive(bytes, references: references)
    let revisions = Dictionary(
      uniqueKeysWithValues: metadata.revisionIDs.compactMap { revisionID in
        references[revisionID].map { (revisionID, $0) }
      })
    return LocalCallAggregate(
      manifest: manifest, transcriptRevisions: revisions,
      audioManifest: metadata.audioManifestID.flatMap { references[$0] })
  }

  /// Returns exact stored transcript bytes, including staged immutable revisions.
  public func transcriptRevisionBytes(callID: String, revisionID: String) throws -> Data {
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(revisionID)
    _ = try loadCall(callID: callID)
    let bytes = try Data(contentsOf: revisionURL(callID: callID, revisionID: revisionID))
    let document = try Contract.decode(TranscriptRevision.self, bytes: bytes)
    guard document.value.callId == callID,
      document.value.revisionId == revisionID
    else {
      throw LocalPersistenceError.invalidStoredDocument("Transcript revision identity differs")
    }
    return document.storedBytes
  }

  /// Changes one revision-scoped annotation without rewriting transcript evidence.
  /// Pass `nil` to remove an existing name.
  public func setSpeakerName(
    _ name: String?, callID: String, revisionID: String, speakerID: String
  ) throws -> LocalCallAggregate {
    try requireCanonicalIdentifier(revisionID)
    try requireCanonicalIdentifier(speakerID)
    let current = try loadCall(callID: callID)
    guard let revisionBytes = current.transcriptRevisions[revisionID] else {
      throw LocalPersistenceError.invalidSpeakerReference(
        revisionID: revisionID, speakerID: speakerID)
    }
    let revision = try Contract.decode(TranscriptRevision.self, bytes: revisionBytes).value
    guard revision.speakers.contains(where: { $0.speakerId == speakerID }) else {
      throw LocalPersistenceError.invalidSpeakerReference(
        revisionID: revisionID, speakerID: speakerID)
    }

    var manifest = current.manifest.value
    var names = manifest.speakerNames
    var revisionNames = names[revisionID] ?? [:]
    if revisionNames[speakerID] == name
      || (name == nil && revisionNames[speakerID] == nil)
    {
      return current
    }
    if let name {
      revisionNames[speakerID] = name
    } else {
      revisionNames.removeValue(forKey: speakerID)
    }
    if revisionNames.isEmpty {
      names.removeValue(forKey: revisionID)
    } else {
      names[revisionID] = revisionNames
    }
    manifest.speakerNames = names
    manifest.documentVersion += 1
    let bytes = try Contract.encode(manifest)
    _ = try publishManifest(
      bytes,
      allowedSpeakerNameChange: SpeakerNameChange(
        revisionID: revisionID, speakerID: speakerID, name: name))
    return try loadCall(callID: callID)
  }

  /// Reports canonical call directories without treating an invalid call as absent.
  public func callIDs() throws -> [String] {
    let urls = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    return try urls.compactMap { url in
      let values = try url.resourceValues(forKeys: [.isDirectoryKey])
      return values.isDirectory == true && isCanonicalIdentifier(url.lastPathComponent)
        ? url.lastPathComponent : nil
    }.sorted()
  }

  /// Removes incomplete atomic-write artifacts and reports every invalid canonical call intact.
  public func reconcile() throws -> ArchiveReconciliationReport {
    var removed = 0
    if let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants]
    ) {
      for case let url as URL in enumerator
      where url.lastPathComponent.hasPrefix(AtomicFileWriter.temporaryPrefix) {
        try writer.remove(url)
        removed += 1
      }
    }

    var valid: [String] = []
    var rejected: [String] = []
    for callID in try callIDs() {
      do {
        _ = try loadCall(callID: callID)
        valid.append(callID)
      } catch {
        rejected.append(callID)
      }
    }
    return ArchiveReconciliationReport(
      validCallIDs: valid, rejectedCallIDs: rejected, removedTemporaryFiles: removed)
  }

  private func publishImmutable(_ bytes: Data, to destination: URL, identity: String) throws
    -> PublicationResult
  {
    if FileManager.default.fileExists(atPath: destination.path) {
      let existing = try Data(contentsOf: destination)
      if existing == bytes { return .alreadyPresent }
      throw LocalPersistenceError.immutableConflict(identity)
    }
    try writer.write(bytes, to: destination, domain: .archive)
    return .committed
  }

  private func validateRevisionAudioReference(_ revision: TranscriptRevision, callID: String) throws
  {
    let reference = revision.audioManifest
    let bytes = try Data(
      contentsOf: audioManifestURL(callID: callID, manifestID: reference.manifestId))
    guard Contract.hash(bytes) == reference.sha256 else { throw ContractError.checksum }
    let stored = try Contract.decode(AudioManifest.self, bytes: bytes).value
    guard stored.callId == callID, stored.manifestId == reference.manifestId else {
      throw ContractError.reference
    }
  }

  private func validateAudioManifest(_ audio: AudioManifest, against call: CallDocument) throws {
    guard audio.callId == call.callId,
      call.captureState == "stopped" || call.captureState == "interrupted",
      let callDuration = call.durationMs, audio.durationMs == callDuration
    else { throw ContractError.reference }
    let trackIDs = Set(call.tracks.map(\.trackId))
    guard call.tracks.allSatisfy({ $0.mediaProfileId == audio.mediaProfileId }) else {
      throw ContractError.reference
    }
    for object in audio.objects {
      guard object.channelMap.allSatisfy({ trackIDs.contains($0.trackId) }) else {
        throw ContractError.reference
      }
    }
    for trackID in trackIDs {
      var cursor = 0
      for object in audio.objects where object.channelMap.contains(where: { $0.trackId == trackID })
      {
        guard object.startMs == cursor else { throw ContractError.reference }
        cursor = object.endMs
      }
      guard cursor == callDuration else { throw ContractError.reference }
    }
  }

  private func validateEvolution(
    from current: CallDocument, to proposed: CallDocument,
    allowedSpeakerNameChange: SpeakerNameChange?
  ) throws {
    let currentRevisions = current.revisions
    let proposedRevisions = proposed.revisions
    guard proposedRevisions.count >= currentRevisions.count else {
      throw LocalPersistenceError.manifestWouldDiscardRevision(
        currentRevisions[proposedRevisions.count].revisionId)
    }
    for (index, retained) in currentRevisions.enumerated() {
      guard retained == proposedRevisions[index] else {
        throw LocalPersistenceError.manifestWouldDiscardRevision(retained.revisionId)
      }
    }
    if current.audioManifest != nil, current.audioManifest != proposed.audioManifest {
      throw LocalPersistenceError.manifestWouldChangeAudioManifest
    }
    let currentNames = current.speakerNames
    let proposedNames = proposed.speakerNames
    guard let allowedSpeakerNameChange else {
      guard currentNames == proposedNames else {
        throw LocalPersistenceError.manifestWouldChangeSpeakerAnnotations
      }
      return
    }
    let currentWithoutTarget = removingSpeakerName(
      revisionID: allowedSpeakerNameChange.revisionID,
      speakerID: allowedSpeakerNameChange.speakerID, from: currentNames)
    let proposedWithoutTarget = removingSpeakerName(
      revisionID: allowedSpeakerNameChange.revisionID,
      speakerID: allowedSpeakerNameChange.speakerID, from: proposedNames)
    let proposedTarget = proposedNames[allowedSpeakerNameChange.revisionID]?[
      allowedSpeakerNameChange.speakerID]
    guard currentWithoutTarget == proposedWithoutTarget,
      proposedTarget == allowedSpeakerNameChange.name
    else {
      throw LocalPersistenceError.manifestWouldChangeSpeakerAnnotations
    }
  }

  private func referenceBytes(for metadata: CallMetadata) throws -> [String: Data] {
    var references: [String: Data] = [:]
    if let manifestID = metadata.audioManifestID {
      let url = audioManifestURL(callID: metadata.callID, manifestID: manifestID)
      if FileManager.default.fileExists(atPath: url.path) {
        references[manifestID] = try Data(contentsOf: url)
      }
    }
    for revisionID in metadata.revisionIDs {
      let url = revisionURL(callID: metadata.callID, revisionID: revisionID)
      if FileManager.default.fileExists(atPath: url.path) {
        references[revisionID] = try Data(contentsOf: url)
      }
    }
    return references
  }

  private func requireArchiveIdentity(_ actual: String) throws {
    guard actual == archiveID else {
      throw LocalPersistenceError.archiveIdentityMismatch(expected: archiveID, actual: actual)
    }
  }

  private func manifestURL(callID: String) -> URL {
    callDirectory(callID).appendingPathComponent("call.json")
  }

  private func revisionURL(callID: String, revisionID: String) -> URL {
    callDirectory(callID).appendingPathComponent("revisions", isDirectory: true)
      .appendingPathComponent(revisionID).appendingPathExtension("json")
  }

  private func audioManifestURL(callID: String, manifestID: String) -> URL {
    callDirectory(callID).appendingPathComponent("audio-manifests", isDirectory: true)
      .appendingPathComponent(manifestID).appendingPathExtension("json")
  }

  private func callDirectory(_ callID: String) -> URL {
    root.appendingPathComponent(callID, isDirectory: true)
  }
}

private struct SpeakerNameChange {
  let revisionID: String
  let speakerID: String
  let name: String?
}

private func removingSpeakerName(
  revisionID: String, speakerID: String, from names: [String: [String: String]]
) -> [String: [String: String]] {
  var result = names
  var revisionNames = result[revisionID] ?? [:]
  revisionNames.removeValue(forKey: speakerID)
  if revisionNames.isEmpty {
    result.removeValue(forKey: revisionID)
  } else {
    result[revisionID] = revisionNames
  }
  return result
}

private struct CallMetadata {
  let archiveID: String
  let callID: String
  let documentVersion: Int
  let audioManifestID: String?
  let revisionIDs: [String]
}

private func callMetadata(_ call: CallDocument) -> CallMetadata {
  CallMetadata(
    archiveID: call.archiveId, callID: call.callId, documentVersion: call.documentVersion,
    audioManifestID: call.audioManifest?.manifestId, revisionIDs: call.revisions.map(\.revisionId))
}
