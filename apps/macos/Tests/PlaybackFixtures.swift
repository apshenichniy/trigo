import Foundation
import TrigoContracts

@testable import TrigoNative

let playbackCallID = "00000000-0000-4000-8000-000000000073"
let playbackArchiveID = "00000000-0000-4000-8000-000000000074"

actor PlaybackTransportFixture: CallPlaybackTransport {
  let requests: AsyncStream<Int>
  private let requestContinuation: AsyncStream<Int>.Continuation
  private var held: [CheckedContinuation<Void, Never>] = []
  private var holdIndex: Int?
  private var expireNext = false
  private var failureIndex: Int?
  private(set) var operations: [String] = []
  private(set) var segmentRequests: [Int] = []
  let durationMs: Int

  init(durationMs: Int = 75_000) {
    self.durationMs = durationMs
    (requests, requestContinuation) = AsyncStream.makeStream(of: Int.self)
  }

  func expireOneSegment() { expireNext = true }
  func hold(index: Int) { holdIndex = index }
  func fail(index: Int) { failureIndex = index }
  func release() {
    let pending = held; held = []; for continuation in pending { continuation.resume() }
  }

  func grant(callID: String, operationID: String) throws -> PlaybackAccess {
    operations.append(operationID)
    let binding = ArchiveBinding(
      serverURL: URL(string: "https://playback.example.test")!,
      archiveId: playbackArchiveID,
      stage: .dev
    )
    let grant = PlaybackGrant(
      schemaVersion: 1,
      operationId: operationID,
      grantId: UUID().uuidString.lowercased(),
      archiveId: playbackArchiveID,
      callId: callID,
      expiresAt: "2099-01-01T00:00:00Z",
      token: "trigo_playback_v1_" + String(repeating: "a", count: 64),
      media: .init(
        masterId: "00000000-0000-4000-8000-000000000075",
        masterSHA256: String(repeating: "c", count: 64),
        profileId: "wav-pcm-s16le-16000-stereo-segment-v1",
        sampleRateHz: 16_000,
        frameCount: durationMs * 16,
        segmentFrames: 480_000,
        segmentCount: (durationMs + 29_999) / 30_000,
        channels: [
          .init(
            channelIndex: 0,
            trackId: "00000000-0000-4000-8000-000000000076",
            role: "microphone"
          ),
          .init(
            channelIndex: 1,
            trackId: "00000000-0000-4000-8000-000000000077",
            role: "application"
          ),
        ]
      )
    )
    return .init(grant: grant, binding: binding)
  }

  func segment(access: PlaybackAccess, index: Int) async throws -> PlaybackPCM {
    segmentRequests.append(index)
    requestContinuation.yield(index)
    if holdIndex == index {
      holdIndex = nil
      await withCheckedContinuation { held.append($0) }
    }
    try Task.checkCancellation()
    if expireNext { expireNext = false; throw CallPlaybackError.grantExpired }
    if failureIndex == index {
      failureIndex = nil
      throw CallPlaybackError.transport(code: "playback_storage_unavailable", retry: .retryable)
    }
    let start = index * 480_000
    let frames = min(480_000, access.grant.media.frameCount - start)
    return try .init(
      startFrame: start,
      frameCount: frames,
      samples: Data(repeating: 0, count: frames * 4)
    )
  }
}

@MainActor final class PlaybackOutputFixture: PlaybackAudioOutput {
  struct Buffer {
    let pcm: PlaybackPCM
    let completion: @MainActor @Sendable () -> Void
  }
  let enqueues: AsyncStream<Int>
  private let enqueueContinuation: AsyncStream<Int>.Continuation
  private(set) var renderedFrames = 0
  private(set) var playing = false
  private(set) var buffers: [Buffer] = []
  private(set) var maximumQueued = 0
  private var consumedInFirst = 0

  init() { (enqueues, enqueueContinuation) = AsyncStream.makeStream(of: Int.self) }
  func enqueue(_ pcm: PlaybackPCM, completed: @escaping @MainActor @Sendable () -> Void) {
    buffers.append(.init(pcm: pcm, completion: completed))
    maximumQueued = max(maximumQueued, buffers.count)
    enqueueContinuation.yield(pcm.startFrame)
  }
  func play() { playing = true }
  func pause() { playing = false }
  func stop() { playing = false; renderedFrames = 0; consumedInFirst = 0; buffers = [] }

  func advance(frames: Int) {
    var remaining = frames
    while playing && remaining > 0, let first = buffers.first {
      let count = min(remaining, first.pcm.frameCount - consumedInFirst)
      renderedFrames += count
      consumedInFirst += count
      remaining -= count
      if consumedInFirst == first.pcm.frameCount {
        buffers.removeFirst()
        consumedInFirst = 0
        first.completion()
      }
    }
  }
}

func playbackWave(frames: Int, microphone: Int16 = 12_000, application: Int16 = -8_000) -> Data {
  var bytes = Data(count: 44 + frames * 4)
  bytes.withUnsafeMutableBytes { raw in
    func u16(_ offset: Int, _ value: UInt16) {
      raw.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt16.self)
    }
    func u32(_ offset: Int, _ value: UInt32) {
      raw.storeBytes(of: value.littleEndian, toByteOffset: offset, as: UInt32.self)
    }
    u32(4, UInt32(36 + frames * 4)); u32(16, 16); u16(20, 1); u16(22, 2)
    u32(24, 16_000); u32(28, 64_000); u16(32, 4); u16(34, 16); u32(40, UInt32(frames * 4))
    for frame in 0..<frames {
      u16(44 + frame * 4, UInt16(bitPattern: microphone))
      u16(46 + frame * 4, UInt16(bitPattern: application))
    }
  }
  bytes.replaceSubrange(0..<4, with: Data("RIFF".utf8))
  bytes.replaceSubrange(8..<16, with: Data("WAVEfmt ".utf8))
  bytes.replaceSubrange(36..<40, with: Data("data".utf8))
  return bytes
}
