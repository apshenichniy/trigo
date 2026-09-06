import Foundation

/// Fixed records bound both the per-commit write and worst-case interval metadata to 2,120 bytes.
/// No commit contains prior intervals. SHA-256 chains bind order, identity and source states.
struct MediaMasterIndex {
  static func header(_ identity: MediaMasterIdentity) -> Data {
    var bytes = Data("TRGIDX01".utf8)
    for id in [
      identity.masterID, identity.callID, identity.microphoneTrackID, identity.applicationTrackID,
    ] {
      var uuid = id.uuid
      withUnsafeBytes(of: &uuid) { bytes.append(contentsOf: $0) }
    }
    bytes.append(Data(repeating: 0, count: 24))
    bytes.append(bytes.masterSHA256)
    return bytes
  }

  static func identity(_ bytes: Data) throws -> MediaMasterIdentity {
    guard bytes.count == MediaMasterProfile.indexHeaderBytes,
      bytes.prefix(8) == Data("TRGIDX01".utf8), bytes.prefix(96).masterSHA256 == bytes.suffix(32),
      bytes.subdata(in: 72..<96) == Data(repeating: 0, count: 24)
    else { throw MediaMasterError.invalidHeader }
    func uuid(_ offset: Int) -> UUID {
      bytes.subdata(in: offset..<(offset + 16)).withUnsafeBytes {
        UUID(uuid: $0.loadUnaligned(as: uuid_t.self))
      }
    }
    return MediaMasterIdentity(
      masterID: uuid(8), callID: uuid(24), microphoneTrackID: uuid(40), applicationTrackID: uuid(56)
    )
  }

  static func states(_ spans: [CaptureInterval], startMs: Int, countMs: Int, microphone: Bool)
    throws -> [UInt8]
  {
    var result = [UInt8]()
    result.reserveCapacity(countMs)
    var next = startMs
    for span in spans {
      guard span.startMs == next, span.endMs > span.startMs, span.endMs <= startMs + countMs,
        microphone || span.state != .muted
      else { throw MediaMasterError.invalidInput }
      result.append(contentsOf: repeatElement(code(span.state), count: span.endMs - span.startMs))
      next = span.endMs
    }
    guard next == startMs + countMs else { throw MediaMasterError.invalidInput }
    return result
  }

  static func code(_ state: CaptureIntervalState) -> UInt8 {
    switch state {
    case .recorded: 1
    case .muted: 2
    case .unavailable: 3
    }
  }

  static func intervals(_ bytes: Data, channel: Int, startMs: Int, countMs: Int) throws
    -> [CaptureInterval]
  {
    var spans = [CaptureInterval]()
    for ms in 0..<countMs {
      let value = bytes[88 + ms * 2 + channel]
      let state: CaptureIntervalState
      switch value {
      case 1: state = .recorded
      case 2 where channel == 0: state = .muted
      case 3: state = .unavailable
      default: throw MediaMasterError.invalidInput
      }
      mergeCaptureInterval(
        .init(startMs: startMs + ms, endMs: startMs + ms + 1, state: state), into: &spans)
    }
    guard
      bytes.subdata(in: (88 + countMs * 2)..<2088) == Data(repeating: 0, count: 2000 - countMs * 2)
    else {
      throw MediaMasterError.invalidInput
    }
    return spans
  }

  static func record(
    final: Bool, frames: Int64, bytes: Int64, hash: Data, previous: Data, states: Data = Data()
  ) -> Data {
    var result = Data((final ? "FINAL001" : "AUDIO001").utf8)
    result.appendInteger(frames)
    result.appendInteger(bytes)
    result.append(hash)
    result.append(previous)
    result.append(states)
    result.append(Data(repeating: 0, count: 2088 - result.count))
    result.append(result.masterSHA256)
    return result
  }
}
