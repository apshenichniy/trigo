import Foundation

public enum MediaSourceRole: String, Codable, Sendable {
  case microphone
  case application
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
    public let ordering: String
    public let timeline: String
    public let missingFrames: String
    public let playback: String
  }

  public struct ASR: Codable, Equatable, Sendable {
    public let model: String
    public let requestContentType: String
    public let encoding: String?
    public let channels: Int
    public let multichannel: Bool
    public let diarize: Bool
    public let submission: String
    public let timestampOrigin: String
    public let speakerScope: String
  }

  public let schemaVersion: Int
  public let id: String
  public let container: String
  public let contentType: String
  public let codec: String
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
      return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
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
