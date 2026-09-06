import CryptoKit
import Foundation

/// Proof profile; the selected production exchange profile is deliberately unchanged.
public enum MediaMasterProfile {
  public static let id = "caf-lpcm-s16le-16000-stereo-v1"
  public static let sampleRate = 16_000
  public static let bytesPerFrame = 4
  public static let headerBytes = 68
  public static let maximumCommitFrames = 16_000
  public static let maximumFrames: Int64 = 172_800_000
  public static let maximumRequestBytes = 8 * 1_024 * 1_024
  public static let indexHeaderBytes = 128
  public static let indexRecordBytes = 2_120

  // CAF chunk metadata is big-endian; interleaved sample data is little-endian.
  // The last data chunk retains size -1 forever. Finalization changes no media bytes.
  public static var header: Data {
    var data = Data("caff".utf8)
    data.appendInteger(UInt16(1))
    data.appendInteger(UInt16(0))
    data.append(Data("desc".utf8))
    data.appendInteger(Int64(32))
    data.appendInteger(Double(sampleRate).bitPattern)
    data.append(Data("lpcm".utf8))
    for value: UInt32 in [2, 4, 1, 2, 16] { data.appendInteger(value) }
    data.append(Data("data".utf8))
    data.appendInteger(Int64(-1))
    data.appendInteger(UInt32(0))
    return data
  }
}

/// Allocated by the call repository before media creation; never regenerated on reopen.
public struct MediaMasterIdentity: Equatable, Sendable {
  public let masterID: UUID
  public let callID: UUID
  public let microphoneTrackID: UUID
  public let applicationTrackID: UUID

  public init(masterID: UUID, callID: UUID, microphoneTrackID: UUID, applicationTrackID: UUID) {
    self.masterID = masterID
    self.callID = callID
    self.microphoneTrackID = microphoneTrackID
    self.applicationTrackID = applicationTrackID
  }
}

/// A certificate issued only after media sync, index append and index sync, in that order.
/// SQLite may publish this value after append returns. A file length is not a certificate.
public struct MediaMasterCursor: Equatable, Sendable {
  public let identity: MediaMasterIdentity
  public let frames: Int64
  public let stableBytes: Int64
  public let commitCount: Int64
  public let integritySHA256: String
}

public struct MediaMasterCommit: Equatable, Sendable {
  public let cursor: MediaMasterCursor
  public let startFrame: Int64
  public let pcmSHA256: String
  public let microphoneIntervals: [CaptureInterval]
  public let applicationIntervals: [CaptureInterval]
}

public struct FinalizedMediaMaster: Equatable, Sendable {
  public let cursor: MediaMasterCursor
  public let sha256: String
  public var profileID: String { MediaMasterProfile.id }
}

public struct MediaMasterExtraction: Equatable, Sendable {
  public let master: FinalizedMediaMaster
  public let startFrame: Int64
  public let endFrame: Int64
  public let sha256: String
  public let byteLength: Int64
  public var profileID: String { MediaMasterProfile.id }
  public var transform: String { "identity-stereo-pcm-frame-slice-v1" }
  public var microphoneChannel: Int { 0 }
  public var applicationChannel: Int { 1 }
}

/// A bounded callback of clipped, call-relative source evidence for an extracted interval.
public struct MediaMasterSourceIntervals: Equatable, Sendable {
  public let startFrame: Int64
  public let endFrame: Int64
  public let microphoneIntervals: [CaptureInterval]
  public let applicationIntervals: [CaptureInterval]
}

public enum MediaMasterError: Error, Equatable {
  case invalidInput
  case closed
  case invalidHeader
  case identityMismatch
  case corruptIndex(record: Int64)
  case committedAudioCorruption(record: Int64)
  case confirmedCursorMissing
  case io(Int32)
}

extension Data {
  mutating func appendInteger<T: FixedWidthInteger>(_ value: T) {
    var big = value.bigEndian
    Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
  }

  func integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type) -> T {
    subdata(in: offset..<(offset + MemoryLayout<T>.size)).withUnsafeBytes {
      T(bigEndian: $0.loadUnaligned(as: T.self))
    }
  }

  var masterSHA256: Data { Data(SHA256.hash(data: self)) }
  var masterHex: String {
    let alphabet = Array("0123456789abcdef".utf8)
    var bytes = [UInt8]()
    bytes.reserveCapacity(count * 2)
    for value in self {
      bytes.append(alphabet[Int(value >> 4)])
      bytes.append(alphabet[Int(value & 15)])
    }
    return String(decoding: bytes, as: UTF8.self)
  }
}
