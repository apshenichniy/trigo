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
    let proposed = try Contract.validate("CallDocument", bytes: bytes)
    let metadata = try callMetadata(bytes)
    try requireArchiveIdentity(metadata.archiveID)
    let destination = manifestURL(callID: metadata.callID)

    if FileManager.default.fileExists(atPath: destination.path) {
      let current = try loadCall(callID: metadata.callID)
      if current.manifest.storedBytes == bytes { return .alreadyPresent }
      let currentVersion = current.manifest.documentVersion ?? 0
      guard metadata.documentVersion > currentVersion else {
        throw LocalPersistenceError.staleDocumentVersion(
          current: currentVersion, proposed: metadata.documentVersion)
      }
    }

    let references = try referenceBytes(for: metadata)
    _ = try Contract.validateArchive(proposed.storedBytes, references: references)
    try writer.write(bytes, to: destination, domain: .archive)
    return .committed
  }

  /// Publishes exact transcript bytes once. Repeating identical bytes is idempotent.
  public func publishTranscriptRevision(_ bytes: Data) throws -> PublicationResult {
    let document = try Contract.validate("TranscriptRevision", bytes: bytes)
    let object = try jsonObject(document.storedBytes)
    let callID = try string(object, key: "callId")
    let revisionID = try string(object, key: "revisionId")
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(revisionID)
    _ = try loadCall(callID: callID)
    try validateRevisionAudioReference(object, callID: callID)
    return try publishImmutable(
      bytes, to: revisionURL(callID: callID, revisionID: revisionID), identity: revisionID)
  }

  /// Publishes exact audio-manifest bytes once. Media objects remain owned by later modules.
  public func publishAudioManifest(_ bytes: Data) throws -> PublicationResult {
    let document = try Contract.validate("AudioManifest", bytes: bytes)
    let object = try jsonObject(document.storedBytes)
    let callID = try string(object, key: "callId")
    let manifestID = try string(object, key: "manifestId")
    try requireCanonicalIdentifier(callID)
    try requireCanonicalIdentifier(manifestID)
    _ = try loadCall(callID: callID)
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
    let metadata = try callMetadata(bytes)
    guard metadata.callID == callID else {
      throw LocalPersistenceError.invalidStoredDocument(
        "Call directory and document identity differ")
    }
    try requireArchiveIdentity(metadata.archiveID)
    let references = try referenceBytes(for: metadata)
    let manifest = try Contract.validateArchive(bytes, references: references)
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
    let document = try Contract.validate("TranscriptRevision", bytes: bytes)
    let object = try jsonObject(document.storedBytes)
    guard try string(object, key: "callId") == callID,
      try string(object, key: "revisionId") == revisionID
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
    let revision = try jsonObject(revisionBytes)
    let speakers = revision["speakers"] as? [[String: Any]] ?? []
    guard speakers.contains(where: { $0["speakerId"] as? String == speakerID }) else {
      throw LocalPersistenceError.invalidSpeakerReference(
        revisionID: revisionID, speakerID: speakerID)
    }

    var manifest = try jsonObject(current.manifest.storedBytes)
    var names = manifest["speakerNames"] as? [String: Any] ?? [:]
    var revisionNames = names[revisionID] as? [String: Any] ?? [:]
    if revisionNames[speakerID] as? String == name
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
    manifest["speakerNames"] = names
    manifest["documentVersion"] = (current.manifest.documentVersion ?? 0) + 1
    let bytes = try JSONSerialization.data(
      withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    _ = try publishManifest(bytes)
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

  private func validateRevisionAudioReference(_ revision: [String: Any], callID: String) throws {
    guard let reference = revision["audioManifest"] as? [String: Any] else {
      throw LocalPersistenceError.invalidStoredDocument("Transcript has no audio reference")
    }
    let manifestID = try string(reference, key: "manifestId")
    let expectedHash = try string(reference, key: "sha256")
    let bytes = try Data(contentsOf: audioManifestURL(callID: callID, manifestID: manifestID))
    guard Contract.hash(bytes) == expectedHash else { throw ContractError.checksum }
    let audio = try Contract.validate("AudioManifest", bytes: bytes)
    guard try string(jsonObject(audio.storedBytes), key: "callId") == callID else {
      throw ContractError.reference
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

private struct CallMetadata {
  let archiveID: String
  let callID: String
  let documentVersion: Int
  let audioManifestID: String?
  let revisionIDs: [String]
}

private func callMetadata(_ bytes: Data) throws -> CallMetadata {
  let object = try jsonObject(bytes)
  let archiveID = try string(object, key: "archiveId")
  let callID = try string(object, key: "callId")
  let documentVersion = try integer(object, key: "documentVersion")
  let audioManifestID = (object["audioManifest"] as? [String: Any]).flatMap {
    $0["manifestId"] as? String
  }
  let revisions = object["revisions"] as? [[String: Any]] ?? []
  let revisionIDs = try revisions.map { try string($0, key: "revisionId") }
  return CallMetadata(
    archiveID: archiveID, callID: callID, documentVersion: documentVersion,
    audioManifestID: audioManifestID, revisionIDs: revisionIDs)
}

private func string(_ object: [String: Any], key: String) throws -> String {
  guard let value = object[key] as? String else {
    throw LocalPersistenceError.invalidStoredDocument("Missing string field \(key)")
  }
  return value
}

private func integer(_ object: [String: Any], key: String) throws -> Int {
  guard let number = object[key] as? NSNumber else {
    throw LocalPersistenceError.invalidStoredDocument("Missing integer field \(key)")
  }
  return number.intValue
}
