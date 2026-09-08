// Generated from src/document-schema.ts via Effect JSON Schema. Do not edit.
// Decoding through Contract enforces constraints and rejects unknown properties.
// Strings retain wire UUID/date spelling. Required nullable fields encode explicit null.
import Foundation

enum GeneratedContract {
  static let documentKinds = [
    "LocalDevelopmentBridge",
    "CaptureMasterProfile",
    "CallDocument",
    "TranscriptRevision",
    "AudioManifest",
    "StatusResponse",
    "CommandIdentity",
    "ErrorEnvelope",
    "RegisterMasterUpload",
    "MasterUploadSession",
    "UploadPartDescriptor",
    "UploadPartReceipt",
    "FinalizeMasterUpload",
    "VerifiedMasterReceipt",
  ]
}

public typealias CanonicalUUIDv4 = String

public struct LocalDevelopmentBridge: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "LocalDevelopmentBridge"
  public var formatVersion: Int
  public var worktreeId: String
  public var namespaceId: CanonicalUUIDv4
  public var serverURL: String
  public var ownerToken: String
  public init(
    formatVersion: Int,
    worktreeId: String,
    namespaceId: CanonicalUUIDv4,
    serverURL: String,
    ownerToken: String
  ) {
    self.formatVersion = formatVersion
    self.worktreeId = worktreeId
    self.namespaceId = namespaceId
    self.serverURL = serverURL
    self.ownerToken = ownerToken
  }
  enum CodingKeys: String, CodingKey {
    case formatVersion
    case worktreeId
    case namespaceId
    case serverURL
    case ownerToken
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.formatVersion = try container.decode(
      Int.self,
      forKey: .formatVersion
    )
    self.worktreeId = try container.decode(
      String.self,
      forKey: .worktreeId
    )
    self.namespaceId = try container.decode(
      CanonicalUUIDv4.self,
      forKey: .namespaceId
    )
    self.serverURL = try container.decode(
      String.self,
      forKey: .serverURL
    )
    self.ownerToken = try container.decode(
      String.self,
      forKey: .ownerToken
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.formatVersion, forKey: .formatVersion)
    try container.encode(self.worktreeId, forKey: .worktreeId)
    try container.encode(self.namespaceId, forKey: .namespaceId)
    try container.encode(self.serverURL, forKey: .serverURL)
    try container.encode(self.ownerToken, forKey: .ownerToken)
  }
}

public struct CaptureMasterProfile: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "CaptureMasterProfile"
  public var schemaVersion: Int
  public var id: String
  public var container: String
  public var contentType: String
  public var codec: String
  public var sampleRateHz: Int
  public var bitsPerSample: Int
  public var interleaved: Bool
  public var microphoneChannel: Int
  public var applicationChannel: Int
  public var headerBytes: Int
  public var headerPolicy: String
  public var maxCallDurationMs: Int
  public var maxMasterBytes: Int
  public var maxCommitDurationMs: Int
  public var maxUncommittedTailMs: Int
  public var indexHeaderBytes: Int
  public var indexRecordBytes: Int
  public var maxRangeBytes: Int
  public var minimumMultipartPartBytes: Int
  public var timeline: String
  public var nonRecordedSamples: String
  public var extractionTransform: String
  public var cleanupAuthority: String
  public init(
    schemaVersion: Int,
    id: String,
    container: String,
    contentType: String,
    codec: String,
    sampleRateHz: Int,
    bitsPerSample: Int,
    interleaved: Bool,
    microphoneChannel: Int,
    applicationChannel: Int,
    headerBytes: Int,
    headerPolicy: String,
    maxCallDurationMs: Int,
    maxMasterBytes: Int,
    maxCommitDurationMs: Int,
    maxUncommittedTailMs: Int,
    indexHeaderBytes: Int,
    indexRecordBytes: Int,
    maxRangeBytes: Int,
    minimumMultipartPartBytes: Int,
    timeline: String,
    nonRecordedSamples: String,
    extractionTransform: String,
    cleanupAuthority: String
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.container = container
    self.contentType = contentType
    self.codec = codec
    self.sampleRateHz = sampleRateHz
    self.bitsPerSample = bitsPerSample
    self.interleaved = interleaved
    self.microphoneChannel = microphoneChannel
    self.applicationChannel = applicationChannel
    self.headerBytes = headerBytes
    self.headerPolicy = headerPolicy
    self.maxCallDurationMs = maxCallDurationMs
    self.maxMasterBytes = maxMasterBytes
    self.maxCommitDurationMs = maxCommitDurationMs
    self.maxUncommittedTailMs = maxUncommittedTailMs
    self.indexHeaderBytes = indexHeaderBytes
    self.indexRecordBytes = indexRecordBytes
    self.maxRangeBytes = maxRangeBytes
    self.minimumMultipartPartBytes = minimumMultipartPartBytes
    self.timeline = timeline
    self.nonRecordedSamples = nonRecordedSamples
    self.extractionTransform = extractionTransform
    self.cleanupAuthority = cleanupAuthority
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case container
    case contentType
    case codec
    case sampleRateHz
    case bitsPerSample
    case interleaved
    case microphoneChannel
    case applicationChannel
    case headerBytes
    case headerPolicy
    case maxCallDurationMs
    case maxMasterBytes
    case maxCommitDurationMs
    case maxUncommittedTailMs
    case indexHeaderBytes
    case indexRecordBytes
    case maxRangeBytes
    case minimumMultipartPartBytes
    case timeline
    case nonRecordedSamples
    case extractionTransform
    case cleanupAuthority
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.id = try container.decode(
      String.self,
      forKey: .id
    )
    self.container = try container.decode(
      String.self,
      forKey: .container
    )
    self.contentType = try container.decode(
      String.self,
      forKey: .contentType
    )
    self.codec = try container.decode(
      String.self,
      forKey: .codec
    )
    self.sampleRateHz = try container.decode(
      Int.self,
      forKey: .sampleRateHz
    )
    self.bitsPerSample = try container.decode(
      Int.self,
      forKey: .bitsPerSample
    )
    self.interleaved = try container.decode(
      Bool.self,
      forKey: .interleaved
    )
    self.microphoneChannel = try container.decode(
      Int.self,
      forKey: .microphoneChannel
    )
    self.applicationChannel = try container.decode(
      Int.self,
      forKey: .applicationChannel
    )
    self.headerBytes = try container.decode(
      Int.self,
      forKey: .headerBytes
    )
    self.headerPolicy = try container.decode(
      String.self,
      forKey: .headerPolicy
    )
    self.maxCallDurationMs = try container.decode(
      Int.self,
      forKey: .maxCallDurationMs
    )
    self.maxMasterBytes = try container.decode(
      Int.self,
      forKey: .maxMasterBytes
    )
    self.maxCommitDurationMs = try container.decode(
      Int.self,
      forKey: .maxCommitDurationMs
    )
    self.maxUncommittedTailMs = try container.decode(
      Int.self,
      forKey: .maxUncommittedTailMs
    )
    self.indexHeaderBytes = try container.decode(
      Int.self,
      forKey: .indexHeaderBytes
    )
    self.indexRecordBytes = try container.decode(
      Int.self,
      forKey: .indexRecordBytes
    )
    self.maxRangeBytes = try container.decode(
      Int.self,
      forKey: .maxRangeBytes
    )
    self.minimumMultipartPartBytes = try container.decode(
      Int.self,
      forKey: .minimumMultipartPartBytes
    )
    self.timeline = try container.decode(
      String.self,
      forKey: .timeline
    )
    self.nonRecordedSamples = try container.decode(
      String.self,
      forKey: .nonRecordedSamples
    )
    self.extractionTransform = try container.decode(
      String.self,
      forKey: .extractionTransform
    )
    self.cleanupAuthority = try container.decode(
      String.self,
      forKey: .cleanupAuthority
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.id, forKey: .id)
    try container.encode(self.container, forKey: .container)
    try container.encode(self.contentType, forKey: .contentType)
    try container.encode(self.codec, forKey: .codec)
    try container.encode(self.sampleRateHz, forKey: .sampleRateHz)
    try container.encode(self.bitsPerSample, forKey: .bitsPerSample)
    try container.encode(self.interleaved, forKey: .interleaved)
    try container.encode(self.microphoneChannel, forKey: .microphoneChannel)
    try container.encode(self.applicationChannel, forKey: .applicationChannel)
    try container.encode(self.headerBytes, forKey: .headerBytes)
    try container.encode(self.headerPolicy, forKey: .headerPolicy)
    try container.encode(self.maxCallDurationMs, forKey: .maxCallDurationMs)
    try container.encode(self.maxMasterBytes, forKey: .maxMasterBytes)
    try container.encode(self.maxCommitDurationMs, forKey: .maxCommitDurationMs)
    try container.encode(self.maxUncommittedTailMs, forKey: .maxUncommittedTailMs)
    try container.encode(self.indexHeaderBytes, forKey: .indexHeaderBytes)
    try container.encode(self.indexRecordBytes, forKey: .indexRecordBytes)
    try container.encode(self.maxRangeBytes, forKey: .maxRangeBytes)
    try container.encode(self.minimumMultipartPartBytes, forKey: .minimumMultipartPartBytes)
    try container.encode(self.timeline, forKey: .timeline)
    try container.encode(self.nonRecordedSamples, forKey: .nonRecordedSamples)
    try container.encode(self.extractionTransform, forKey: .extractionTransform)
    try container.encode(self.cleanupAuthority, forKey: .cleanupAuthority)
  }
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
    self.applicationName = try container.decode(
      String.self,
      forKey: .applicationName
    )
    self.bundleId = try container.decode(
      String.self,
      forKey: .bundleId
    )
    self.processId = try container.decode(
      NonNegativeInteger.self,
      forKey: .processId
    )
    self.windowId = try container.decode(
      NonNegativeInteger?.self,
      forKey: .windowId
    )
    self.windowTitle = try container.decode(
      String?.self,
      forKey: .windowTitle
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.applicationName, forKey: .applicationName)
    try container.encode(self.bundleId, forKey: .bundleId)
    try container.encode(self.processId, forKey: .processId)
    try container.encode(self.windowId, forKey: .windowId)
    try container.encode(self.windowTitle, forKey: .windowTitle)
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
    self.id = try container.decode(
      String.self,
      forKey: .id
    )
    self.name = try container.decode(
      String.self,
      forKey: .name
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.id, forKey: .id)
    try container.encode(self.name, forKey: .name)
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
    self.startMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .startMs
    )
    self.endMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .endMs
    )
    self.state = try container.decode(
      String.self,
      forKey: .state
    )
    self.reason = try container.decode(
      String?.self,
      forKey: .reason
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.startMs, forKey: .startMs)
    try container.encode(self.endMs, forKey: .endMs)
    try container.encode(self.state, forKey: .state)
    try container.encode(self.reason, forKey: .reason)
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
    self.trackId = try container.decode(
      ExchangeUUID.self,
      forKey: .trackId
    )
    self.role = try container.decode(
      String.self,
      forKey: .role
    )
    self.inputDevice = try container.decode(
      InputDevice?.self,
      forKey: .inputDevice
    )
    self.mediaProfileId = try container.decode(
      String.self,
      forKey: .mediaProfileId
    )
    self.intervals = try container.decode(
      [TrackInterval].self,
      forKey: .intervals
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.trackId, forKey: .trackId)
    try container.encode(self.role, forKey: .role)
    try container.encode(self.inputDevice, forKey: .inputDevice)
    try container.encode(self.mediaProfileId, forKey: .mediaProfileId)
    try container.encode(self.intervals, forKey: .intervals)
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
    self.manifestId = try container.decode(
      ExchangeUUID.self,
      forKey: .manifestId
    )
    self.sha256 = try container.decode(
      SHA256Digest.self,
      forKey: .sha256
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.manifestId, forKey: .manifestId)
    try container.encode(self.sha256, forKey: .sha256)
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
    self.revisionId = try container.decode(
      ExchangeUUID.self,
      forKey: .revisionId
    )
    self.createdAt = try container.decode(
      UTCDateTime.self,
      forKey: .createdAt
    )
    self.sha256 = try container.decode(
      SHA256Digest.self,
      forKey: .sha256
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.revisionId, forKey: .revisionId)
    try container.encode(self.createdAt, forKey: .createdAt)
    try container.encode(self.sha256, forKey: .sha256)
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
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.archiveId = try container.decode(
      ExchangeUUID.self,
      forKey: .archiveId
    )
    self.callId = try container.decode(
      ExchangeUUID.self,
      forKey: .callId
    )
    self.documentVersion = try container.decode(
      PositiveInteger.self,
      forKey: .documentVersion
    )
    self.startedAt = try container.decode(
      UTCDateTime.self,
      forKey: .startedAt
    )
    self.endedAt = try container.decode(
      UTCDateTime?.self,
      forKey: .endedAt
    )
    self.durationMs = try container.decode(
      NonNegativeInteger?.self,
      forKey: .durationMs
    )
    self.captureState = try container.decode(
      String.self,
      forKey: .captureState
    )
    self.interruptionReason = try container.decode(
      String?.self,
      forKey: .interruptionReason
    )
    self.source = try container.decode(
      CaptureSourceDocument.self,
      forKey: .source
    )
    self.tracks = try container.decode(
      [AudioTrack].self,
      forKey: .tracks
    )
    self.audioManifest = try container.decode(
      AudioManifestReference?.self,
      forKey: .audioManifest
    )
    self.revisions = try container.decode(
      [RevisionReference].self,
      forKey: .revisions
    )
    self.activeRevisionId = try container.decode(
      ExchangeUUID?.self,
      forKey: .activeRevisionId
    )
    self.speakerNames = try container.decode(
      [String: [String: String]].self,
      forKey: .speakerNames
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.archiveId, forKey: .archiveId)
    try container.encode(self.callId, forKey: .callId)
    try container.encode(self.documentVersion, forKey: .documentVersion)
    try container.encode(self.startedAt, forKey: .startedAt)
    try container.encode(self.endedAt, forKey: .endedAt)
    try container.encode(self.durationMs, forKey: .durationMs)
    try container.encode(self.captureState, forKey: .captureState)
    try container.encode(self.interruptionReason, forKey: .interruptionReason)
    try container.encode(self.source, forKey: .source)
    try container.encode(self.tracks, forKey: .tracks)
    try container.encode(self.audioManifest, forKey: .audioManifest)
    try container.encode(self.revisions, forKey: .revisions)
    try container.encode(self.activeRevisionId, forKey: .activeRevisionId)
    try container.encode(self.speakerNames, forKey: .speakerNames)
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
    self.adapter = try container.decode(
      String.self,
      forKey: .adapter
    )
    self.model = try container.decode(
      String.self,
      forKey: .model
    )
    self.profileId = try container.decode(
      String.self,
      forKey: .profileId
    )
    self.requestedLanguage = try container.decode(
      String.self,
      forKey: .requestedLanguage
    )
    self.detectedLanguages = try container.decode(
      [String].self,
      forKey: .detectedLanguages
    )
    self.effectiveOptions = try container.decode(
      [String: ProviderOption].self,
      forKey: .effectiveOptions
    )
    self.returnedModelVersion = try container.decode(
      String?.self,
      forKey: .returnedModelVersion
    )
    self.providerRequestIds = try container.decode(
      [String].self,
      forKey: .providerRequestIds
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.adapter, forKey: .adapter)
    try container.encode(self.model, forKey: .model)
    try container.encode(self.profileId, forKey: .profileId)
    try container.encode(self.requestedLanguage, forKey: .requestedLanguage)
    try container.encode(self.detectedLanguages, forKey: .detectedLanguages)
    try container.encode(self.effectiveOptions, forKey: .effectiveOptions)
    try container.encode(self.returnedModelVersion, forKey: .returnedModelVersion)
    try container.encode(self.providerRequestIds, forKey: .providerRequestIds)
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
    self.speakerId = try container.decode(
      ExchangeUUID.self,
      forKey: .speakerId
    )
    self.trackId = try container.decode(
      ExchangeUUID.self,
      forKey: .trackId
    )
    self.diarizationScopeId = try container.decode(
      ExchangeUUID.self,
      forKey: .diarizationScopeId
    )
    self.providerLabel = try container.decode(
      String?.self,
      forKey: .providerLabel
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.speakerId, forKey: .speakerId)
    try container.encode(self.trackId, forKey: .trackId)
    try container.encode(self.diarizationScopeId, forKey: .diarizationScopeId)
    try container.encode(self.providerLabel, forKey: .providerLabel)
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
    self.text = try container.decode(
      String.self,
      forKey: .text
    )
    self.startMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .startMs
    )
    self.endMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .endMs
    )
    self.confidence = try container.decode(
      Double?.self,
      forKey: .confidence
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.text, forKey: .text)
    try container.encode(self.startMs, forKey: .startMs)
    try container.encode(self.endMs, forKey: .endMs)
    try container.encode(self.confidence, forKey: .confidence)
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
    self.turnId = try container.decode(
      ExchangeUUID.self,
      forKey: .turnId
    )
    self.trackId = try container.decode(
      ExchangeUUID.self,
      forKey: .trackId
    )
    self.speakerId = try container.decode(
      ExchangeUUID?.self,
      forKey: .speakerId
    )
    self.startMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .startMs
    )
    self.endMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .endMs
    )
    self.text = try container.decode(
      String.self,
      forKey: .text
    )
    self.words = try container.decode(
      [Word].self,
      forKey: .words
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.turnId, forKey: .turnId)
    try container.encode(self.trackId, forKey: .trackId)
    try container.encode(self.speakerId, forKey: .speakerId)
    try container.encode(self.startMs, forKey: .startMs)
    try container.encode(self.endMs, forKey: .endMs)
    try container.encode(self.text, forKey: .text)
    try container.encode(self.words, forKey: .words)
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
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.callId = try container.decode(
      ExchangeUUID.self,
      forKey: .callId
    )
    self.revisionId = try container.decode(
      ExchangeUUID.self,
      forKey: .revisionId
    )
    self.createdAt = try container.decode(
      UTCDateTime.self,
      forKey: .createdAt
    )
    self.audioManifest = try container.decode(
      AudioManifestReference.self,
      forKey: .audioManifest
    )
    self.normalizationVersion = try container.decode(
      Int.self,
      forKey: .normalizationVersion
    )
    self.asr = try container.decode(
      ASRMetadata.self,
      forKey: .asr
    )
    self.speakers = try container.decode(
      [Speaker].self,
      forKey: .speakers
    )
    self.turns = try container.decode(
      [Turn].self,
      forKey: .turns
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.callId, forKey: .callId)
    try container.encode(self.revisionId, forKey: .revisionId)
    try container.encode(self.createdAt, forKey: .createdAt)
    try container.encode(self.audioManifest, forKey: .audioManifest)
    try container.encode(self.normalizationVersion, forKey: .normalizationVersion)
    try container.encode(self.asr, forKey: .asr)
    try container.encode(self.speakers, forKey: .speakers)
    try container.encode(self.turns, forKey: .turns)
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
    self.channelIndex = try container.decode(
      NonNegativeInteger.self,
      forKey: .channelIndex
    )
    self.trackId = try container.decode(
      ExchangeUUID.self,
      forKey: .trackId
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.channelIndex, forKey: .channelIndex)
    try container.encode(self.trackId, forKey: .trackId)
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
    self.objectId = try container.decode(
      ExchangeUUID.self,
      forKey: .objectId
    )
    self.index = try container.decode(
      NonNegativeInteger.self,
      forKey: .index
    )
    self.contentType = try container.decode(
      String.self,
      forKey: .contentType
    )
    self.byteLength = try container.decode(
      PositiveInteger.self,
      forKey: .byteLength
    )
    self.sha256 = try container.decode(
      SHA256Digest.self,
      forKey: .sha256
    )
    self.startMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .startMs
    )
    self.endMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .endMs
    )
    self.channelMap = try container.decode(
      [ChannelMapping].self,
      forKey: .channelMap
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.objectId, forKey: .objectId)
    try container.encode(self.index, forKey: .index)
    try container.encode(self.contentType, forKey: .contentType)
    try container.encode(self.byteLength, forKey: .byteLength)
    try container.encode(self.sha256, forKey: .sha256)
    try container.encode(self.startMs, forKey: .startMs)
    try container.encode(self.endMs, forKey: .endMs)
    try container.encode(self.channelMap, forKey: .channelMap)
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
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.callId = try container.decode(
      ExchangeUUID.self,
      forKey: .callId
    )
    self.manifestId = try container.decode(
      ExchangeUUID.self,
      forKey: .manifestId
    )
    self.durationMs = try container.decode(
      NonNegativeInteger.self,
      forKey: .durationMs
    )
    self.mediaProfileId = try container.decode(
      String.self,
      forKey: .mediaProfileId
    )
    self.objects = try container.decode(
      [AudioObject].self,
      forKey: .objects
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.callId, forKey: .callId)
    try container.encode(self.manifestId, forKey: .manifestId)
    try container.encode(self.durationMs, forKey: .durationMs)
    try container.encode(self.mediaProfileId, forKey: .mediaProfileId)
    try container.encode(self.objects, forKey: .objects)
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
    self.archive = try container.decode(
      String.self,
      forKey: .archive
    )
    self.ownerAuthentication = try container.decode(
      String.self,
      forKey: .ownerAuthentication
    )
    self.transcription = try container.decode(
      String.self,
      forKey: .transcription
    )
    self.callOperations = try container.decode(
      String.self,
      forKey: .callOperations
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.archive, forKey: .archive)
    try container.encode(self.ownerAuthentication, forKey: .ownerAuthentication)
    try container.encode(self.transcription, forKey: .transcription)
    try container.encode(self.callOperations, forKey: .callOperations)
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
    self.code = try container.decode(
      String.self,
      forKey: .code
    )
    self.retry = try container.decode(
      String.self,
      forKey: .retry
    )
    self.message = try container.decode(
      String.self,
      forKey: .message
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.code, forKey: .code)
    try container.encode(self.retry, forKey: .retry)
    try container.encode(self.message, forKey: .message)
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
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.apiVersion = try container.decode(
      Int.self,
      forKey: .apiVersion
    )
    self.archiveId = try container.decode(
      ExchangeUUID.self,
      forKey: .archiveId
    )
    self.stage = try container.decode(
      String.self,
      forKey: .stage
    )
    self.readiness = try container.decode(
      StatusReadiness.self,
      forKey: .readiness
    )
    self.errors = try container.decode(
      [StatusNotice].self,
      forKey: .errors
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.apiVersion, forKey: .apiVersion)
    try container.encode(self.archiveId, forKey: .archiveId)
    try container.encode(self.stage, forKey: .stage)
    try container.encode(self.readiness, forKey: .readiness)
    try container.encode(self.errors, forKey: .errors)
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
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.operationId = try container.decode(
      ExchangeUUID.self,
      forKey: .operationId
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.operationId, forKey: .operationId)
  }
}

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
    self.code = try container.decode(
      String.self,
      forKey: .code
    )
    self.retry = try container.decode(
      String.self,
      forKey: .retry
    )
    self.message = try container.decode(
      String.self,
      forKey: .message
    )
    self.requestId = try container.decode(
      CanonicalUUIDv4.self,
      forKey: .requestId
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.code, forKey: .code)
    try container.encode(self.retry, forKey: .retry)
    try container.encode(self.message, forKey: .message)
    try container.encode(self.requestId, forKey: .requestId)
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
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.error = try container.decode(
      ErrorDetail.self,
      forKey: .error
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.error, forKey: .error)
  }
}

public struct RegisterMasterUpload: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "RegisterMasterUpload"
  public var schemaVersion: Int
  public var uploadId: ExchangeUUID
  public var masterId: ExchangeUUID
  public var callDocument: String
  public init(
    schemaVersion: Int,
    uploadId: ExchangeUUID,
    masterId: ExchangeUUID,
    callDocument: String
  ) {
    self.schemaVersion = schemaVersion
    self.uploadId = uploadId
    self.masterId = masterId
    self.callDocument = callDocument
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case uploadId
    case masterId
    case callDocument
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.uploadId = try container.decode(
      ExchangeUUID.self,
      forKey: .uploadId
    )
    self.masterId = try container.decode(
      ExchangeUUID.self,
      forKey: .masterId
    )
    self.callDocument = try container.decode(
      String.self,
      forKey: .callDocument
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.uploadId, forKey: .uploadId)
    try container.encode(self.masterId, forKey: .masterId)
    try container.encode(self.callDocument, forKey: .callDocument)
  }
}

public struct MasterUploadSession: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "MasterUploadSession"
  public var schemaVersion: Int
  public var archiveId: ExchangeUUID
  public var callId: ExchangeUUID
  public var uploadId: ExchangeUUID
  public var masterId: ExchangeUUID
  public var partBytes: Int
  public var mediaProfileId: String
  public init(
    schemaVersion: Int,
    archiveId: ExchangeUUID,
    callId: ExchangeUUID,
    uploadId: ExchangeUUID,
    masterId: ExchangeUUID,
    partBytes: Int,
    mediaProfileId: String
  ) {
    self.schemaVersion = schemaVersion
    self.archiveId = archiveId
    self.callId = callId
    self.uploadId = uploadId
    self.masterId = masterId
    self.partBytes = partBytes
    self.mediaProfileId = mediaProfileId
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case archiveId
    case callId
    case uploadId
    case masterId
    case partBytes
    case mediaProfileId
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.archiveId = try container.decode(
      ExchangeUUID.self,
      forKey: .archiveId
    )
    self.callId = try container.decode(
      ExchangeUUID.self,
      forKey: .callId
    )
    self.uploadId = try container.decode(
      ExchangeUUID.self,
      forKey: .uploadId
    )
    self.masterId = try container.decode(
      ExchangeUUID.self,
      forKey: .masterId
    )
    self.partBytes = try container.decode(
      Int.self,
      forKey: .partBytes
    )
    self.mediaProfileId = try container.decode(
      String.self,
      forKey: .mediaProfileId
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.archiveId, forKey: .archiveId)
    try container.encode(self.callId, forKey: .callId)
    try container.encode(self.uploadId, forKey: .uploadId)
    try container.encode(self.masterId, forKey: .masterId)
    try container.encode(self.partBytes, forKey: .partBytes)
    try container.encode(self.mediaProfileId, forKey: .mediaProfileId)
  }
}

public struct UploadPartDescriptor: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "UploadPartDescriptor"
  public var index: Int
  public var byteOffset: NonNegativeInteger
  public var byteLength: Int
  public var sha256: SHA256Digest
  public init(
    index: Int,
    byteOffset: NonNegativeInteger,
    byteLength: Int,
    sha256: SHA256Digest
  ) {
    self.index = index
    self.byteOffset = byteOffset
    self.byteLength = byteLength
    self.sha256 = sha256
  }
  enum CodingKeys: String, CodingKey {
    case index
    case byteOffset
    case byteLength
    case sha256
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.index = try container.decode(
      Int.self,
      forKey: .index
    )
    self.byteOffset = try container.decode(
      NonNegativeInteger.self,
      forKey: .byteOffset
    )
    self.byteLength = try container.decode(
      Int.self,
      forKey: .byteLength
    )
    self.sha256 = try container.decode(
      SHA256Digest.self,
      forKey: .sha256
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.index, forKey: .index)
    try container.encode(self.byteOffset, forKey: .byteOffset)
    try container.encode(self.byteLength, forKey: .byteLength)
    try container.encode(self.sha256, forKey: .sha256)
  }
}

public struct UploadPartReceipt: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "UploadPartReceipt"
  public var schemaVersion: Int
  public var archiveId: ExchangeUUID
  public var callId: ExchangeUUID
  public var uploadId: ExchangeUUID
  public var masterId: ExchangeUUID
  public var index: Int
  public var byteOffset: NonNegativeInteger
  public var byteLength: Int
  public var sha256: SHA256Digest
  public var receiptId: ExchangeUUID
  public init(
    schemaVersion: Int,
    archiveId: ExchangeUUID,
    callId: ExchangeUUID,
    uploadId: ExchangeUUID,
    masterId: ExchangeUUID,
    index: Int,
    byteOffset: NonNegativeInteger,
    byteLength: Int,
    sha256: SHA256Digest,
    receiptId: ExchangeUUID
  ) {
    self.schemaVersion = schemaVersion
    self.archiveId = archiveId
    self.callId = callId
    self.uploadId = uploadId
    self.masterId = masterId
    self.index = index
    self.byteOffset = byteOffset
    self.byteLength = byteLength
    self.sha256 = sha256
    self.receiptId = receiptId
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case archiveId
    case callId
    case uploadId
    case masterId
    case index
    case byteOffset
    case byteLength
    case sha256
    case receiptId
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.archiveId = try container.decode(
      ExchangeUUID.self,
      forKey: .archiveId
    )
    self.callId = try container.decode(
      ExchangeUUID.self,
      forKey: .callId
    )
    self.uploadId = try container.decode(
      ExchangeUUID.self,
      forKey: .uploadId
    )
    self.masterId = try container.decode(
      ExchangeUUID.self,
      forKey: .masterId
    )
    self.index = try container.decode(
      Int.self,
      forKey: .index
    )
    self.byteOffset = try container.decode(
      NonNegativeInteger.self,
      forKey: .byteOffset
    )
    self.byteLength = try container.decode(
      Int.self,
      forKey: .byteLength
    )
    self.sha256 = try container.decode(
      SHA256Digest.self,
      forKey: .sha256
    )
    self.receiptId = try container.decode(
      ExchangeUUID.self,
      forKey: .receiptId
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.archiveId, forKey: .archiveId)
    try container.encode(self.callId, forKey: .callId)
    try container.encode(self.uploadId, forKey: .uploadId)
    try container.encode(self.masterId, forKey: .masterId)
    try container.encode(self.index, forKey: .index)
    try container.encode(self.byteOffset, forKey: .byteOffset)
    try container.encode(self.byteLength, forKey: .byteLength)
    try container.encode(self.sha256, forKey: .sha256)
    try container.encode(self.receiptId, forKey: .receiptId)
  }
}

public struct UploadSourceStates: Codable, Equatable, Sendable {
  public var encoding: String
  public var data: String
  public init(
    encoding: String,
    data: String
  ) {
    self.encoding = encoding
    self.data = data
  }
  enum CodingKeys: String, CodingKey {
    case encoding
    case data
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.encoding = try container.decode(
      String.self,
      forKey: .encoding
    )
    self.data = try container.decode(
      String.self,
      forKey: .data
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.encoding, forKey: .encoding)
    try container.encode(self.data, forKey: .data)
  }
}

public struct FinalizeMasterUpload: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "FinalizeMasterUpload"
  public var schemaVersion: Int
  public var operationId: ExchangeUUID
  public var uploadId: ExchangeUUID
  public var captureState: String
  public var durationMs: Int
  public var sourceStates: UploadSourceStates
  public var audioManifest: String
  public var masterSHA256: SHA256Digest
  public init(
    schemaVersion: Int,
    operationId: ExchangeUUID,
    uploadId: ExchangeUUID,
    captureState: String,
    durationMs: Int,
    sourceStates: UploadSourceStates,
    audioManifest: String,
    masterSHA256: SHA256Digest
  ) {
    self.schemaVersion = schemaVersion
    self.operationId = operationId
    self.uploadId = uploadId
    self.captureState = captureState
    self.durationMs = durationMs
    self.sourceStates = sourceStates
    self.audioManifest = audioManifest
    self.masterSHA256 = masterSHA256
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case operationId
    case uploadId
    case captureState
    case durationMs
    case sourceStates
    case audioManifest
    case masterSHA256
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.operationId = try container.decode(
      ExchangeUUID.self,
      forKey: .operationId
    )
    self.uploadId = try container.decode(
      ExchangeUUID.self,
      forKey: .uploadId
    )
    self.captureState = try container.decode(
      String.self,
      forKey: .captureState
    )
    self.durationMs = try container.decode(
      Int.self,
      forKey: .durationMs
    )
    self.sourceStates = try container.decode(
      UploadSourceStates.self,
      forKey: .sourceStates
    )
    self.audioManifest = try container.decode(
      String.self,
      forKey: .audioManifest
    )
    self.masterSHA256 = try container.decode(
      SHA256Digest.self,
      forKey: .masterSHA256
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.operationId, forKey: .operationId)
    try container.encode(self.uploadId, forKey: .uploadId)
    try container.encode(self.captureState, forKey: .captureState)
    try container.encode(self.durationMs, forKey: .durationMs)
    try container.encode(self.sourceStates, forKey: .sourceStates)
    try container.encode(self.audioManifest, forKey: .audioManifest)
    try container.encode(self.masterSHA256, forKey: .masterSHA256)
  }
}

public struct VerifiedMasterChannel: Codable, Equatable, Sendable {
  public var channelIndex: Int
  public var trackId: ExchangeUUID
  public init(
    channelIndex: Int,
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
    self.channelIndex = try container.decode(
      Int.self,
      forKey: .channelIndex
    )
    self.trackId = try container.decode(
      ExchangeUUID.self,
      forKey: .trackId
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.channelIndex, forKey: .channelIndex)
    try container.encode(self.trackId, forKey: .trackId)
  }
}

public struct VerifiedMasterReceipt: ContractDocument, Codable, Equatable, Sendable {
  public static let documentKind = "VerifiedMasterReceipt"
  public var schemaVersion: Int
  public var archiveId: ExchangeUUID
  public var callId: ExchangeUUID
  public var uploadId: ExchangeUUID
  public var masterId: ExchangeUUID
  public var operationId: ExchangeUUID
  public var receiptId: ExchangeUUID
  public var verification: String
  public var mediaProfileId: String
  public var masterSHA256: SHA256Digest
  public var sourceStatesSHA256: SHA256Digest
  public var byteLength: Int
  public var durationMs: Int
  public var channelMap: [VerifiedMasterChannel]
  public var audioManifest: AudioManifestReference
  public var storedAt: UTCDateTime
  public init(
    schemaVersion: Int,
    archiveId: ExchangeUUID,
    callId: ExchangeUUID,
    uploadId: ExchangeUUID,
    masterId: ExchangeUUID,
    operationId: ExchangeUUID,
    receiptId: ExchangeUUID,
    verification: String,
    mediaProfileId: String,
    masterSHA256: SHA256Digest,
    sourceStatesSHA256: SHA256Digest,
    byteLength: Int,
    durationMs: Int,
    channelMap: [VerifiedMasterChannel],
    audioManifest: AudioManifestReference,
    storedAt: UTCDateTime
  ) {
    self.schemaVersion = schemaVersion
    self.archiveId = archiveId
    self.callId = callId
    self.uploadId = uploadId
    self.masterId = masterId
    self.operationId = operationId
    self.receiptId = receiptId
    self.verification = verification
    self.mediaProfileId = mediaProfileId
    self.masterSHA256 = masterSHA256
    self.sourceStatesSHA256 = sourceStatesSHA256
    self.byteLength = byteLength
    self.durationMs = durationMs
    self.channelMap = channelMap
    self.audioManifest = audioManifest
    self.storedAt = storedAt
  }
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case archiveId
    case callId
    case uploadId
    case masterId
    case operationId
    case receiptId
    case verification
    case mediaProfileId
    case masterSHA256
    case sourceStatesSHA256
    case byteLength
    case durationMs
    case channelMap
    case audioManifest
    case storedAt
  }
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(
      Int.self,
      forKey: .schemaVersion
    )
    self.archiveId = try container.decode(
      ExchangeUUID.self,
      forKey: .archiveId
    )
    self.callId = try container.decode(
      ExchangeUUID.self,
      forKey: .callId
    )
    self.uploadId = try container.decode(
      ExchangeUUID.self,
      forKey: .uploadId
    )
    self.masterId = try container.decode(
      ExchangeUUID.self,
      forKey: .masterId
    )
    self.operationId = try container.decode(
      ExchangeUUID.self,
      forKey: .operationId
    )
    self.receiptId = try container.decode(
      ExchangeUUID.self,
      forKey: .receiptId
    )
    self.verification = try container.decode(
      String.self,
      forKey: .verification
    )
    self.mediaProfileId = try container.decode(
      String.self,
      forKey: .mediaProfileId
    )
    self.masterSHA256 = try container.decode(
      SHA256Digest.self,
      forKey: .masterSHA256
    )
    self.sourceStatesSHA256 = try container.decode(
      SHA256Digest.self,
      forKey: .sourceStatesSHA256
    )
    self.byteLength = try container.decode(
      Int.self,
      forKey: .byteLength
    )
    self.durationMs = try container.decode(
      Int.self,
      forKey: .durationMs
    )
    self.channelMap = try container.decode(
      [VerifiedMasterChannel].self,
      forKey: .channelMap
    )
    self.audioManifest = try container.decode(
      AudioManifestReference.self,
      forKey: .audioManifest
    )
    self.storedAt = try container.decode(
      UTCDateTime.self,
      forKey: .storedAt
    )
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.schemaVersion, forKey: .schemaVersion)
    try container.encode(self.archiveId, forKey: .archiveId)
    try container.encode(self.callId, forKey: .callId)
    try container.encode(self.uploadId, forKey: .uploadId)
    try container.encode(self.masterId, forKey: .masterId)
    try container.encode(self.operationId, forKey: .operationId)
    try container.encode(self.receiptId, forKey: .receiptId)
    try container.encode(self.verification, forKey: .verification)
    try container.encode(self.mediaProfileId, forKey: .mediaProfileId)
    try container.encode(self.masterSHA256, forKey: .masterSHA256)
    try container.encode(self.sourceStatesSHA256, forKey: .sourceStatesSHA256)
    try container.encode(self.byteLength, forKey: .byteLength)
    try container.encode(self.durationMs, forKey: .durationMs)
    try container.encode(self.channelMap, forKey: .channelMap)
    try container.encode(self.audioManifest, forKey: .audioManifest)
    try container.encode(self.storedAt, forKey: .storedAt)
  }
}
