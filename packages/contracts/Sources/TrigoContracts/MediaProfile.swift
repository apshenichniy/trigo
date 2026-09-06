import Foundation

public enum MediaSourceRole: String, Codable, Sendable {
  case microphone
  case application
}

public enum MediaProfileID: String, Codable, Sendable {
  case selected = "trigo-call-wav-s16le-16khz-stereo-60s-v1"
}

public enum MediaContainer: String, Codable, Sendable {
  case wave
}

public enum MediaContentType: String, Codable, Sendable {
  case wave = "audio/wav"
}

public enum MediaCodec: String, Codable, Sendable {
  case pcmS16LE = "pcm_s16le"
}

public enum MediaObjectOrdering: String, Codable, Sendable {
  case objectIndex = "object-index"
}

public enum MediaTimeline: String, Codable, Sendable {
  case manifestStartEndMilliseconds = "manifest-start-end-ms"
}

public enum MissingFramePolicy: String, Codable, Sendable {
  case silence
}

public enum MediaPlaybackAssembly: String, Codable, Sendable {
  case decodeOrderedWaveObjectsAndMixAtOutput = "decode-ordered-wave-objects-and-mix-at-output"
}

public enum ASRModel: String, Codable, Sendable {
  case cloudflareNova3 = "@cf/deepgram/nova-3"
}

public enum ASRSubmission: String, Codable, Sendable {
  case oneObjectPerRequest = "one-object-per-request"
}

public enum ASRTimestampOrigin: String, Codable, Sendable {
  case object
}

public enum ASRSpeakerScope: String, Codable, Sendable {
  case objectChannel = "object-channel"
}

public struct MediaProfile: Codable, Equatable, Sendable {
  public struct Channel: Codable, Equatable, Sendable {
    public let index: Int
    public let role: MediaSourceRole
  }

  public struct Limits: Codable, Equatable, Sendable {
    public let uploadRequestBytes: Int
    public let batchEnvelopeBytes: Int
    public let base64ObjectBytes: Int
  }

  public struct Assembly: Codable, Equatable, Sendable {
    public let ordering: MediaObjectOrdering
    public let timeline: MediaTimeline
    public let missingFrames: MissingFramePolicy
    public let playback: MediaPlaybackAssembly
  }

  public struct ASR: Codable, Equatable, Sendable {
    public let model: ASRModel
    public let requestContentType: MediaContentType
    public let encoding: String?
    public let channels: Int
    public let multichannel: Bool
    public let diarize: Bool
    public let submission: ASRSubmission
    public let timestampOrigin: ASRTimestampOrigin
    public let speakerScope: ASRSpeakerScope
  }

  public let schemaVersion: Int
  public let id: MediaProfileID
  public let container: MediaContainer
  public let contentType: MediaContentType
  public let codec: MediaCodec
  public let sampleRateHz: Int
  public let bitsPerSample: Int
  public let interleaved: Bool
  public let objectDurationMs: Int
  public let checkpointDurationMs: Int
  public let waveHeaderBytes: Int
  public let maxObjectBytes: Int
  public let maxCallDurationMs: Int
  public let maxObjectsPerCall: Int
  public let limits: Limits
  public let channels: [Channel]
  public let assembly: Assembly
  public let asr: ASR

  public static func selected() throws -> Self {
    guard let url = Bundle.module.url(forResource: "media-profile.v1", withExtension: "json") else {
      throw ContractError.structure
    }
    do {
      let profile = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
      guard
        profile.schemaVersion == 1,
        profile.id == .selected,
        profile.sampleRateHz == 16_000,
        profile.bitsPerSample == 16,
        profile.interleaved,
        profile.objectDurationMs == 60_000,
        profile.checkpointDurationMs == 2_000,
        profile.waveHeaderBytes == 44,
        profile.maxObjectBytes == 3_840_044,
        profile.maxCallDurationMs == 10_800_000,
        profile.maxObjectsPerCall == 180,
        profile.limits.uploadRequestBytes == 8_388_608,
        profile.limits.batchEnvelopeBytes == 10_000_000,
        profile.limits.base64ObjectBytes == 5_120_060,
        profile.channels == [
          .init(index: 0, role: .microphone),
          .init(index: 1, role: .application),
        ],
        profile.assembly.ordering == .objectIndex,
        profile.assembly.timeline == .manifestStartEndMilliseconds,
        profile.assembly.missingFrames == .silence,
        profile.assembly.playback == .decodeOrderedWaveObjectsAndMixAtOutput,
        profile.asr.model == .cloudflareNova3,
        profile.asr.requestContentType == .wave,
        profile.asr.encoding == nil,
        profile.asr.channels == 2,
        profile.asr.multichannel,
        profile.asr.diarize,
        profile.asr.submission == .oneObjectPerRequest,
        profile.asr.timestampOrigin == .object,
        profile.asr.speakerScope == .objectChannel
      else {
        throw ContractError.structure
      }
      return profile
    } catch {
      throw ContractError.structure
    }
  }

  public func frameCount(durationMs: Int) -> Int {
    (durationMs * sampleRateHz + 999) / 1000
  }

  public func waveByteLength(frameCount: Int) -> Int {
    waveHeaderBytes + frameCount * channels.count * (bitsPerSample / 8)
  }

  public func objectCount(durationMs: Int) -> Int {
    (durationMs + objectDurationMs - 1) / objectDurationMs
  }
}
