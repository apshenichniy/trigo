// Generated from src/document-schema.ts via Effect JSON Schema. Do not edit.
// Decoding through Contract enforces constraints and rejects unknown properties.
// Strings retain wire UUID/date spelling. Required nullable fields encode explicit null.
import Foundation

enum GeneratedContract {
  static let documentKinds = [
    "CallDocument",
    "TranscriptRevision",
    "AudioManifest",
    "StatusResponse",
    "CommandIdentity",
    "ErrorEnvelope",
  ]
}

public typealias ExchangeUUID = String

public typealias PositiveInteger = Int

public typealias UTCDateTime = String

public typealias NonNegativeInteger = Int

public struct CaptureSourceDocument: Codable, Equatable, Sendable {
  public var applicationName: String
  public var bundleId: String
  public var processId: NonNegativeInteger
  public var windowId: NonNegativeInteger?
  public var windowTitle: String?
  public init(
    applicationName: String,
    bundleId: String,
    processId: NonNegativeInteger,
    windowId: NonNegativeInteger?,
    windowTitle: String?
  ) {
    self.applicationName = applicationName
    self.bundleId = bundleId
    self.processId = processId
    self.windowId = windowId
    self.windowTitle = windowTitle
  }
  enum CodingKeys: String, CodingKey {
    case applicationName
    case bundleId
    case processId
    case windowId
    case windowTitle
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    applicationName = try container.decode(
      String.self, forKey: .applicationName)
    bundleId = try container.decode(
      String.self, forKey: .bundleId)
    processId = try container.decode(
      NonNegativeInteger.self, forKey: .processId)
    windowId = try container.decode(
      NonNegativeInteger?.self, forKey: .windowId)
    windowTitle = try container.decode(
      String?.self, forKey: .windowTitle)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(applicationName, forKey: .applicationName)
    try container.encode(bundleId, forKey: .bundleId)
    try container.encode(processId, forKey: .processId)
    try container.encode(windowId, forKey: .windowId)
    try container.encode(windowTitle, forKey: .windowTitle)
  }
}

public struct InputDevice: Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public init(
    id: String,
    name: String
  ) {
    self.id = id
    self.name = name
  }
  enum CodingKeys: String, CodingKey {
    case id
    case name
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(
      String.self, forKey: .id)
    name = try container.decode(
      String.self, forKey: .name)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
  }
}

public struct TrackInterval: Codable, Equatable, Sendable {
  public var startMs: NonNegativeInteger
  public var endMs: NonNegativeInteger
  public var state: String
  public var reason: String?
  public init(
    startMs: NonNegativeInteger,
    endMs: NonNegativeInteger,
    state: String,
    reason: String?
  ) {
    self.startMs = startMs
    self.endMs = endMs
    self.state = state
    self.reason = reason
  }
  enum CodingKeys: String, CodingKey {
    case startMs
    case endMs
    case state
    case reason
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    startMs = try container.decode(
      NonNegativeInteger.self, forKey: .startMs)
    endMs = try container.decode(
      NonNegativeInteger.self, forKey: .endMs)
    state = try container.decode(
      String.self, forKey: .state)
    reason = try container.decode(
      String?.self, forKey: .reason)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(startMs, forKey: .startMs)
    try container.encode(endMs, forKey: .endMs)
    try container.encode(state, forKey: .state)
    try container.encode(reason, forKey: .reason)
  }
}

public struct AudioTrack: Codable, Equatable, Sendable {
  public var trackId: ExchangeUUID
  public var role: String
  public var inputDevice: InputDevice?
  public var mediaProfileId: String
  public var intervals: [TrackInterval]
  public init(
    trackId: ExchangeUUID,
    role: String,
    inputDevice: InputDevice?,
    mediaProfileId: String,
    intervals: [TrackInterval]
  ) {
    self.trackId = trackId
    self.role = role
    self.inputDevice = inputDevice
    self.mediaProfileId = mediaProfileId
    self.intervals = intervals
  }
  enum CodingKeys: String, CodingKey {
    case trackId
    case role
    case inputDevice
    case mediaProfileId
    case intervals
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    trackId = try container.decode(
      ExchangeUUID.self, forKey: .trackId)
    role = try container.decode(
      String.self, forKey: .role)
    inputDevice = try container.decode(
      InputDevice?.self, forKey: .inputDevice)
    mediaProfileId = try container.decode(
      String.self, forKey: .mediaProfileId)
    intervals = try container.decode(
      [TrackInterval].self, forKey: .intervals)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(trackId, forKey: .trackId)
    try container.encode(role, forKey: .role)
    try container.encode(inputDevice, forKey: .inputDevice)
    try container.encode(mediaProfileId, forKey: .mediaProfileId)
    try container.encode(intervals, forKey: .intervals)
  }
}

public typealias SHA256Digest = String

public struct AudioManifestReference: Codable, Equatable, Sendable {
  public var manifestId: ExchangeUUID
  public var sha256: SHA256Digest
  public init(
    manifestId: ExchangeUUID,
    sha256: SHA256Digest
  ) {
    self.manifestId = manifestId
    self.sha256 = sha256
  }
  enum CodingKeys: String, CodingKey {
    case manifestId
    case sha256
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    manifestId = try container.decode(
      ExchangeUUID.self, forKey: .manifestId)
    sha256 = try container.decode(
      SHA256Digest.self, forKey: .sha256)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(manifestId, forKey: .manifestId)
    try container.encode(sha256, forKey: .sha256)
  }
}

public struct RevisionReference: Codable, Equatable, Sendable {
  public var revisionId: ExchangeUUID
  public var createdAt: UTCDateTime
  public var sha256: SHA256Digest
  public init(
    revisionId: ExchangeUUID,
    createdAt: UTCDateTime,
    sha256: SHA256Digest
  ) {
    self.revisionId = revisionId
    self.createdAt = createdAt
    self.sha256 = sha256
  }
  enum CodingKeys: String, CodingKey {
    case revisionId
    case createdAt
    case sha256
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    revisionId = try container.decode(
      ExchangeUUID.self, forKey: .revisionId)
    createdAt = try container.decode(
      UTCDateTime.self, forKey: .createdAt)
    sha256 = try container.decode(
      SHA256Digest.self, forKey: .sha256)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(revisionId, forKey: .revisionId)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(sha256, forKey: .sha256)
  }
}

public struct CallDocument: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "CallDocument"
  public var schemaVersion: Int
  public var archiveId: ExchangeUUID
  public var callId: ExchangeUUID
  public var documentVersion: PositiveInteger
  public var startedAt: UTCDateTime
  public var endedAt: UTCDateTime?
  public var durationMs: NonNegativeInteger?
  public var captureState: String
  public var interruptionReason: String?
  public var source: CaptureSourceDocument
  public var tracks: [AudioTrack]
  public var audioManifest: AudioManifestReference?
  public var revisions: [RevisionReference]
  public var activeRevisionId: ExchangeUUID?
  public var speakerNames: [String: [String: String]]
  public init(
    schemaVersion: Int,
    archiveId: ExchangeUUID,
    callId: ExchangeUUID,
    documentVersion: PositiveInteger,
    startedAt: UTCDateTime,
    endedAt: UTCDateTime?,
    durationMs: NonNegativeInteger?,
    captureState: String,
    interruptionReason: String?,
    source: CaptureSourceDocument,
    tracks: [AudioTrack],
    audioManifest: AudioManifestReference?,
    revisions: [RevisionReference],
    activeRevisionId: ExchangeUUID?,
    speakerNames: [String: [String: String]]
  ) {
    self.schemaVersion = schemaVersion
    self.archiveId = archiveId
    self.callId = callId
    self.documentVersion = documentVersion
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.durationMs = durationMs
    self.captureState = captureState
    self.interruptionReason = interruptionReason
    self.source = source
    self.tracks = tracks
    self.audioManifest = audioManifest
    self.revisions = revisions
    self.activeRevisionId = activeRevisionId
    self.speakerNames = speakerNames
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case archiveId
    case callId
    case documentVersion
    case startedAt
    case endedAt
    case durationMs
    case captureState
    case interruptionReason
    case source
    case tracks
    case audioManifest
    case revisions
    case activeRevisionId
    case speakerNames
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(
      Int.self, forKey: .schemaVersion)
    archiveId = try container.decode(
      ExchangeUUID.self, forKey: .archiveId)
    callId = try container.decode(
      ExchangeUUID.self, forKey: .callId)
    documentVersion = try container.decode(
      PositiveInteger.self, forKey: .documentVersion)
    startedAt = try container.decode(
      UTCDateTime.self, forKey: .startedAt)
    endedAt = try container.decode(
      UTCDateTime?.self, forKey: .endedAt)
    durationMs = try container.decode(
      NonNegativeInteger?.self, forKey: .durationMs)
    captureState = try container.decode(
      String.self, forKey: .captureState)
    interruptionReason = try container.decode(
      String?.self, forKey: .interruptionReason)
    source = try container.decode(
      CaptureSourceDocument.self, forKey: .source)
    tracks = try container.decode(
      [AudioTrack].self, forKey: .tracks)
    audioManifest = try container.decode(
      AudioManifestReference?.self, forKey: .audioManifest)
    revisions = try container.decode(
      [RevisionReference].self, forKey: .revisions)
    activeRevisionId = try container.decode(
      ExchangeUUID?.self, forKey: .activeRevisionId)
    speakerNames = try container.decode(
      [String: [String: String]].self, forKey: .speakerNames)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(archiveId, forKey: .archiveId)
    try container.encode(callId, forKey: .callId)
    try container.encode(documentVersion, forKey: .documentVersion)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(endedAt, forKey: .endedAt)
    try container.encode(durationMs, forKey: .durationMs)
    try container.encode(captureState, forKey: .captureState)
    try container.encode(interruptionReason, forKey: .interruptionReason)
    try container.encode(source, forKey: .source)
    try container.encode(tracks, forKey: .tracks)
    try container.encode(audioManifest, forKey: .audioManifest)
    try container.encode(revisions, forKey: .revisions)
    try container.encode(activeRevisionId, forKey: .activeRevisionId)
    try container.encode(speakerNames, forKey: .speakerNames)
  }
}

public typealias ProviderOption = JSONScalar

public struct ASRMetadata: Codable, Equatable, Sendable {
  public var adapter: String
  public var model: String
  public var profileId: String
  public var requestedLanguage: String
  public var detectedLanguages: [String]
  public var effectiveOptions: [String: ProviderOption]
  public var returnedModelVersion: String?
  public var providerRequestIds: [String]
  public init(
    adapter: String,
    model: String,
    profileId: String,
    requestedLanguage: String,
    detectedLanguages: [String],
    effectiveOptions: [String: ProviderOption],
    returnedModelVersion: String?,
    providerRequestIds: [String]
  ) {
    self.adapter = adapter
    self.model = model
    self.profileId = profileId
    self.requestedLanguage = requestedLanguage
    self.detectedLanguages = detectedLanguages
    self.effectiveOptions = effectiveOptions
    self.returnedModelVersion = returnedModelVersion
    self.providerRequestIds = providerRequestIds
  }
  enum CodingKeys: String, CodingKey {
    case adapter
    case model
    case profileId
    case requestedLanguage
    case detectedLanguages
    case effectiveOptions
    case returnedModelVersion
    case providerRequestIds
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    adapter = try container.decode(
      String.self, forKey: .adapter)
    model = try container.decode(
      String.self, forKey: .model)
    profileId = try container.decode(
      String.self, forKey: .profileId)
    requestedLanguage = try container.decode(
      String.self, forKey: .requestedLanguage)
    detectedLanguages = try container.decode(
      [String].self, forKey: .detectedLanguages)
    effectiveOptions = try container.decode(
      [String: ProviderOption].self, forKey: .effectiveOptions)
    returnedModelVersion = try container.decode(
      String?.self, forKey: .returnedModelVersion)
    providerRequestIds = try container.decode(
      [String].self, forKey: .providerRequestIds)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(adapter, forKey: .adapter)
    try container.encode(model, forKey: .model)
    try container.encode(profileId, forKey: .profileId)
    try container.encode(requestedLanguage, forKey: .requestedLanguage)
    try container.encode(detectedLanguages, forKey: .detectedLanguages)
    try container.encode(effectiveOptions, forKey: .effectiveOptions)
    try container.encode(returnedModelVersion, forKey: .returnedModelVersion)
    try container.encode(providerRequestIds, forKey: .providerRequestIds)
  }
}

public struct Speaker: Codable, Equatable, Sendable {
  public var speakerId: ExchangeUUID
  public var trackId: ExchangeUUID
  public var diarizationScopeId: ExchangeUUID
  public var providerLabel: String?
  public init(
    speakerId: ExchangeUUID,
    trackId: ExchangeUUID,
    diarizationScopeId: ExchangeUUID,
    providerLabel: String?
  ) {
    self.speakerId = speakerId
    self.trackId = trackId
    self.diarizationScopeId = diarizationScopeId
    self.providerLabel = providerLabel
  }
  enum CodingKeys: String, CodingKey {
    case speakerId
    case trackId
    case diarizationScopeId
    case providerLabel
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    speakerId = try container.decode(
      ExchangeUUID.self, forKey: .speakerId)
    trackId = try container.decode(
      ExchangeUUID.self, forKey: .trackId)
    diarizationScopeId = try container.decode(
      ExchangeUUID.self, forKey: .diarizationScopeId)
    providerLabel = try container.decode(
      String?.self, forKey: .providerLabel)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(speakerId, forKey: .speakerId)
    try container.encode(trackId, forKey: .trackId)
    try container.encode(diarizationScopeId, forKey: .diarizationScopeId)
    try container.encode(providerLabel, forKey: .providerLabel)
  }
}

public struct Word: Codable, Equatable, Sendable {
  public var text: String
  public var startMs: NonNegativeInteger
  public var endMs: NonNegativeInteger
  public var confidence: Double?
  public init(
    text: String,
    startMs: NonNegativeInteger,
    endMs: NonNegativeInteger,
    confidence: Double?
  ) {
    self.text = text
    self.startMs = startMs
    self.endMs = endMs
    self.confidence = confidence
  }
  enum CodingKeys: String, CodingKey {
    case text
    case startMs
    case endMs
    case confidence
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    text = try container.decode(
      String.self, forKey: .text)
    startMs = try container.decode(
      NonNegativeInteger.self, forKey: .startMs)
    endMs = try container.decode(
      NonNegativeInteger.self, forKey: .endMs)
    confidence = try container.decode(
      Double?.self, forKey: .confidence)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(text, forKey: .text)
    try container.encode(startMs, forKey: .startMs)
    try container.encode(endMs, forKey: .endMs)
    try container.encode(confidence, forKey: .confidence)
  }
}

public struct Turn: Codable, Equatable, Sendable {
  public var turnId: ExchangeUUID
  public var trackId: ExchangeUUID
  public var speakerId: ExchangeUUID?
  public var startMs: NonNegativeInteger
  public var endMs: NonNegativeInteger
  public var text: String
  public var words: [Word]
  public init(
    turnId: ExchangeUUID,
    trackId: ExchangeUUID,
    speakerId: ExchangeUUID?,
    startMs: NonNegativeInteger,
    endMs: NonNegativeInteger,
    text: String,
    words: [Word]
  ) {
    self.turnId = turnId
    self.trackId = trackId
    self.speakerId = speakerId
    self.startMs = startMs
    self.endMs = endMs
    self.text = text
    self.words = words
  }
  enum CodingKeys: String, CodingKey {
    case turnId
    case trackId
    case speakerId
    case startMs
    case endMs
    case text
    case words
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    turnId = try container.decode(
      ExchangeUUID.self, forKey: .turnId)
    trackId = try container.decode(
      ExchangeUUID.self, forKey: .trackId)
    speakerId = try container.decode(
      ExchangeUUID?.self, forKey: .speakerId)
    startMs = try container.decode(
      NonNegativeInteger.self, forKey: .startMs)
    endMs = try container.decode(
      NonNegativeInteger.self, forKey: .endMs)
    text = try container.decode(
      String.self, forKey: .text)
    words = try container.decode(
      [Word].self, forKey: .words)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(turnId, forKey: .turnId)
    try container.encode(trackId, forKey: .trackId)
    try container.encode(speakerId, forKey: .speakerId)
    try container.encode(startMs, forKey: .startMs)
    try container.encode(endMs, forKey: .endMs)
    try container.encode(text, forKey: .text)
    try container.encode(words, forKey: .words)
  }
}

public struct TranscriptRevision: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "TranscriptRevision"
  public var schemaVersion: Int
  public var callId: ExchangeUUID
  public var revisionId: ExchangeUUID
  public var createdAt: UTCDateTime
  public var audioManifest: AudioManifestReference
  public var normalizationVersion: Int
  public var asr: ASRMetadata
  public var speakers: [Speaker]
  public var turns: [Turn]
  public init(
    schemaVersion: Int,
    callId: ExchangeUUID,
    revisionId: ExchangeUUID,
    createdAt: UTCDateTime,
    audioManifest: AudioManifestReference,
    normalizationVersion: Int,
    asr: ASRMetadata,
    speakers: [Speaker],
    turns: [Turn]
  ) {
    self.schemaVersion = schemaVersion
    self.callId = callId
    self.revisionId = revisionId
    self.createdAt = createdAt
    self.audioManifest = audioManifest
    self.normalizationVersion = normalizationVersion
    self.asr = asr
    self.speakers = speakers
    self.turns = turns
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case callId
    case revisionId
    case createdAt
    case audioManifest
    case normalizationVersion
    case asr
    case speakers
    case turns
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(
      Int.self, forKey: .schemaVersion)
    callId = try container.decode(
      ExchangeUUID.self, forKey: .callId)
    revisionId = try container.decode(
      ExchangeUUID.self, forKey: .revisionId)
    createdAt = try container.decode(
      UTCDateTime.self, forKey: .createdAt)
    audioManifest = try container.decode(
      AudioManifestReference.self, forKey: .audioManifest)
    normalizationVersion = try container.decode(
      Int.self, forKey: .normalizationVersion)
    asr = try container.decode(
      ASRMetadata.self, forKey: .asr)
    speakers = try container.decode(
      [Speaker].self, forKey: .speakers)
    turns = try container.decode(
      [Turn].self, forKey: .turns)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(callId, forKey: .callId)
    try container.encode(revisionId, forKey: .revisionId)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(audioManifest, forKey: .audioManifest)
    try container.encode(normalizationVersion, forKey: .normalizationVersion)
    try container.encode(asr, forKey: .asr)
    try container.encode(speakers, forKey: .speakers)
    try container.encode(turns, forKey: .turns)
  }
}

public struct ChannelMapping: Codable, Equatable, Sendable {
  public var channelIndex: NonNegativeInteger
  public var trackId: ExchangeUUID
  public init(
    channelIndex: NonNegativeInteger,
    trackId: ExchangeUUID
  ) {
    self.channelIndex = channelIndex
    self.trackId = trackId
  }
  enum CodingKeys: String, CodingKey {
    case channelIndex
    case trackId
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    channelIndex = try container.decode(
      NonNegativeInteger.self, forKey: .channelIndex)
    trackId = try container.decode(
      ExchangeUUID.self, forKey: .trackId)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(channelIndex, forKey: .channelIndex)
    try container.encode(trackId, forKey: .trackId)
  }
}

public struct AudioObject: Codable, Equatable, Sendable {
  public var objectId: ExchangeUUID
  public var index: NonNegativeInteger
  public var contentType: String
  public var byteLength: PositiveInteger
  public var sha256: SHA256Digest
  public var startMs: NonNegativeInteger
  public var endMs: NonNegativeInteger
  public var channelMap: [ChannelMapping]
  public init(
    objectId: ExchangeUUID,
    index: NonNegativeInteger,
    contentType: String,
    byteLength: PositiveInteger,
    sha256: SHA256Digest,
    startMs: NonNegativeInteger,
    endMs: NonNegativeInteger,
    channelMap: [ChannelMapping]
  ) {
    self.objectId = objectId
    self.index = index
    self.contentType = contentType
    self.byteLength = byteLength
    self.sha256 = sha256
    self.startMs = startMs
    self.endMs = endMs
    self.channelMap = channelMap
  }
  enum CodingKeys: String, CodingKey {
    case objectId
    case index
    case contentType
    case byteLength
    case sha256
    case startMs
    case endMs
    case channelMap
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    objectId = try container.decode(
      ExchangeUUID.self, forKey: .objectId)
    index = try container.decode(
      NonNegativeInteger.self, forKey: .index)
    contentType = try container.decode(
      String.self, forKey: .contentType)
    byteLength = try container.decode(
      PositiveInteger.self, forKey: .byteLength)
    sha256 = try container.decode(
      SHA256Digest.self, forKey: .sha256)
    startMs = try container.decode(
      NonNegativeInteger.self, forKey: .startMs)
    endMs = try container.decode(
      NonNegativeInteger.self, forKey: .endMs)
    channelMap = try container.decode(
      [ChannelMapping].self, forKey: .channelMap)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(objectId, forKey: .objectId)
    try container.encode(index, forKey: .index)
    try container.encode(contentType, forKey: .contentType)
    try container.encode(byteLength, forKey: .byteLength)
    try container.encode(sha256, forKey: .sha256)
    try container.encode(startMs, forKey: .startMs)
    try container.encode(endMs, forKey: .endMs)
    try container.encode(channelMap, forKey: .channelMap)
  }
}

public struct AudioManifest: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "AudioManifest"
  public var schemaVersion: Int
  public var callId: ExchangeUUID
  public var manifestId: ExchangeUUID
  public var durationMs: NonNegativeInteger
  public var mediaProfileId: String
  public var objects: [AudioObject]
  public init(
    schemaVersion: Int,
    callId: ExchangeUUID,
    manifestId: ExchangeUUID,
    durationMs: NonNegativeInteger,
    mediaProfileId: String,
    objects: [AudioObject]
  ) {
    self.schemaVersion = schemaVersion
    self.callId = callId
    self.manifestId = manifestId
    self.durationMs = durationMs
    self.mediaProfileId = mediaProfileId
    self.objects = objects
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case callId
    case manifestId
    case durationMs
    case mediaProfileId
    case objects
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(
      Int.self, forKey: .schemaVersion)
    callId = try container.decode(
      ExchangeUUID.self, forKey: .callId)
    manifestId = try container.decode(
      ExchangeUUID.self, forKey: .manifestId)
    durationMs = try container.decode(
      NonNegativeInteger.self, forKey: .durationMs)
    mediaProfileId = try container.decode(
      String.self, forKey: .mediaProfileId)
    objects = try container.decode(
      [AudioObject].self, forKey: .objects)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(callId, forKey: .callId)
    try container.encode(manifestId, forKey: .manifestId)
    try container.encode(durationMs, forKey: .durationMs)
    try container.encode(mediaProfileId, forKey: .mediaProfileId)
    try container.encode(objects, forKey: .objects)
  }
}

public struct StatusReadiness: Codable, Equatable, Sendable {
  public var archive: String
  public var ownerAuthentication: String
  public var transcription: String
  public var callOperations: String
  public init(
    archive: String,
    ownerAuthentication: String,
    transcription: String,
    callOperations: String
  ) {
    self.archive = archive
    self.ownerAuthentication = ownerAuthentication
    self.transcription = transcription
    self.callOperations = callOperations
  }
  enum CodingKeys: String, CodingKey {
    case archive
    case ownerAuthentication
    case transcription
    case callOperations
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    archive = try container.decode(
      String.self, forKey: .archive)
    ownerAuthentication = try container.decode(
      String.self, forKey: .ownerAuthentication)
    transcription = try container.decode(
      String.self, forKey: .transcription)
    callOperations = try container.decode(
      String.self, forKey: .callOperations)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(archive, forKey: .archive)
    try container.encode(ownerAuthentication, forKey: .ownerAuthentication)
    try container.encode(transcription, forKey: .transcription)
    try container.encode(callOperations, forKey: .callOperations)
  }
}

public struct StatusNotice: Codable, Equatable, Sendable {
  public var code: String
  public var retry: String
  public var message: String
  public init(
    code: String,
    retry: String,
    message: String
  ) {
    self.code = code
    self.retry = retry
    self.message = message
  }
  enum CodingKeys: String, CodingKey {
    case code
    case retry
    case message
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(
      String.self, forKey: .code)
    retry = try container.decode(
      String.self, forKey: .retry)
    message = try container.decode(
      String.self, forKey: .message)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encode(retry, forKey: .retry)
    try container.encode(message, forKey: .message)
  }
}

public struct StatusResponse: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "StatusResponse"
  public var schemaVersion: Int
  public var apiVersion: Int
  public var archiveId: ExchangeUUID
  public var stage: String
  public var readiness: StatusReadiness
  public var errors: [StatusNotice]
  public init(
    schemaVersion: Int,
    apiVersion: Int,
    archiveId: ExchangeUUID,
    stage: String,
    readiness: StatusReadiness,
    errors: [StatusNotice]
  ) {
    self.schemaVersion = schemaVersion
    self.apiVersion = apiVersion
    self.archiveId = archiveId
    self.stage = stage
    self.readiness = readiness
    self.errors = errors
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case apiVersion
    case archiveId
    case stage
    case readiness
    case errors
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(
      Int.self, forKey: .schemaVersion)
    apiVersion = try container.decode(
      Int.self, forKey: .apiVersion)
    archiveId = try container.decode(
      ExchangeUUID.self, forKey: .archiveId)
    stage = try container.decode(
      String.self, forKey: .stage)
    readiness = try container.decode(
      StatusReadiness.self, forKey: .readiness)
    errors = try container.decode(
      [StatusNotice].self, forKey: .errors)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(apiVersion, forKey: .apiVersion)
    try container.encode(archiveId, forKey: .archiveId)
    try container.encode(stage, forKey: .stage)
    try container.encode(readiness, forKey: .readiness)
    try container.encode(errors, forKey: .errors)
  }
}

public struct CommandIdentity: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "CommandIdentity"
  public var schemaVersion: Int
  public var operationId: ExchangeUUID
  public init(
    schemaVersion: Int,
    operationId: ExchangeUUID
  ) {
    self.schemaVersion = schemaVersion
    self.operationId = operationId
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case operationId
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(
      Int.self, forKey: .schemaVersion)
    operationId = try container.decode(
      ExchangeUUID.self, forKey: .operationId)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(operationId, forKey: .operationId)
  }
}

public typealias CanonicalUUIDv4 = String

public struct ErrorDetail: Codable, Equatable, Sendable {
  public var code: String
  public var retry: String
  public var message: String
  public var requestId: CanonicalUUIDv4
  public init(
    code: String,
    retry: String,
    message: String,
    requestId: CanonicalUUIDv4
  ) {
    self.code = code
    self.retry = retry
    self.message = message
    self.requestId = requestId
  }
  enum CodingKeys: String, CodingKey {
    case code
    case retry
    case message
    case requestId
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    code = try container.decode(
      String.self, forKey: .code)
    retry = try container.decode(
      String.self, forKey: .retry)
    message = try container.decode(
      String.self, forKey: .message)
    requestId = try container.decode(
      CanonicalUUIDv4.self, forKey: .requestId)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(code, forKey: .code)
    try container.encode(retry, forKey: .retry)
    try container.encode(message, forKey: .message)
    try container.encode(requestId, forKey: .requestId)
  }
}

public struct ErrorEnvelope: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "ErrorEnvelope"
  public var schemaVersion: Int
  public var error: ErrorDetail
  public init(
    schemaVersion: Int,
    error: ErrorDetail
  ) {
    self.schemaVersion = schemaVersion
    self.error = error
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case error
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(
      Int.self, forKey: .schemaVersion)
    error = try container.decode(
      ErrorDetail.self, forKey: .error)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(error, forKey: .error)
  }
}
