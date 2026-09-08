import Foundation
import TrigoContracts

public enum CallPlaybackPhase: Equatable, Sendable {
  case idle, loading, paused, playing, finished, unavailable, error
}

public struct CallPlaybackState: Equatable, Sendable {
  public var callID: String?
  public var phase: CallPlaybackPhase = .idle
  public var positionMs = 0
  public var durationMs = 0
  public var failure: CallPlaybackError?

  public init() {}
}

public enum CallPlaybackError: Error, Equatable, Sendable {
  case accessBlocked, grantExpired, invalidGrant, invalidMedia, noAudio, deleted, audioOutput
  case transport(code: String, retry: LifecycleRetryClassification)

  public var message: String {
    switch self {
    case .accessBlocked: "Reconnect to this archive to play its audio."
    case .grantExpired, .invalidGrant: "Playback access expired. Resume from this position."
    case .invalidMedia: "The retained audio could not be verified."
    case .noAudio: "This call has no retained audio."
    case .deleted: "This call is no longer available."
    case .audioOutput: "Audio output is unavailable. Check your output device and try again."
    case .transport:
      "The audio server is unavailable. Resume from this position when access returns."
    }
  }

  var renewsGrant: Bool { self == .grantExpired || self == .invalidGrant }
}

/// A capability stays bound to the server/archive that issued it. No owner token is retained here.
public struct PlaybackAccess: Sendable {
  public let grant: PlaybackGrant
  public let binding: ArchiveBinding

  public init(grant: PlaybackGrant, binding: ArchiveBinding) {
    self.grant = grant
    self.binding = binding
  }
}

/// Bounded stereo PCM with an explicit origin in the call's common timeline.
public struct PlaybackPCM: Sendable {
  public let startFrame: Int
  public let frameCount: Int
  public let samples: Data

  public init(startFrame: Int, frameCount: Int, samples: Data) throws {
    guard startFrame >= 0, frameCount > 0, frameCount <= 480_000,
      startFrame <= 172_800_000 - frameCount,
      samples.count == frameCount * 4
    else { throw CallPlaybackError.invalidMedia }
    self.startFrame = startFrame
    self.frameCount = frameCount
    self.samples = samples
  }

  func trimming(before frame: Int) throws -> PlaybackPCM {
    let skipped = max(0, frame - startFrame)
    guard skipped < frameCount else { throw CallPlaybackError.invalidMedia }
    return try .init(
      startFrame: startFrame + skipped,
      frameCount: frameCount - skipped,
      samples: samples.subdata(in: (skipped * 4)..<samples.count)
    )
  }
}

public protocol CallPlaybackTransport: Sendable {
  func grant(callID: String, operationID: String) async throws -> PlaybackAccess
  func segment(access: PlaybackAccess, index: Int) async throws -> PlaybackPCM
}

/// The player owns at most two scheduled segments. Completion means rendered audio,
/// so call time remains independent from network buffering and wall-clock pauses.
@MainActor public protocol PlaybackAudioOutput: AnyObject {
  var renderedFrames: Int { get }
  func enqueue(_ pcm: PlaybackPCM, completed: @escaping @MainActor @Sendable () -> Void) throws
  func play() throws
  func pause()
  func stop()
}

enum PlaybackValidation {
  static func access(_ access: PlaybackAccess, callID: String) throws {
    let grant = access.grant
    let media = grant.media
    _ = try Contract.encode(grant)
    guard grant.callId == callID, grant.archiveId == access.binding.archiveId,
      media.frameCount % 16 == 0,
      media.segmentCount == (media.frameCount + media.segmentFrames - 1) / media.segmentFrames,
      media.channels.count == 2,
      media.channels[0].channelIndex == 0, media.channels[0].role == "microphone",
      media.channels[1].channelIndex == 1, media.channels[1].role == "application",
      media.channels[0].trackId != media.channels[1].trackId
    else { throw CallPlaybackError.invalidGrant }
  }

  static func decodeWave(_ bytes: Data, startFrame: Int, frameCount: Int) throws -> PlaybackPCM {
    guard frameCount > 0, frameCount <= 480_000, bytes.count == 44 + frameCount * 4,
      bytes.prefix(4) == Data("RIFF".utf8),
      bytes.subdata(in: 8..<16) == Data("WAVEfmt ".utf8),
      bytes.subdata(in: 36..<40) == Data("data".utf8)
    else { throw CallPlaybackError.invalidMedia }
    let valid = bytes.withUnsafeBytes { raw in
      func u16(_ offset: Int) -> UInt16 {
        UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
      }
      func u32(_ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
      }
      return u32(4) == UInt32(bytes.count - 8) && u32(16) == 16 && u16(20) == 1
        && u16(22) == 2 && u32(24) == 16_000 && u32(28) == 64_000
        && u16(32) == 4 && u16(34) == 16 && u32(40) == UInt32(frameCount * 4)
    }
    guard valid else { throw CallPlaybackError.invalidMedia }
    return try .init(
      startFrame: startFrame,
      frameCount: frameCount,
      samples: bytes.subdata(in: 44..<bytes.count)
    )
  }
}
