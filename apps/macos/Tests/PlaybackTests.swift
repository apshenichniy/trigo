import AVFoundation
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Suite(.serialized, .timeLimit(.minutes(1)))
struct PlaybackTests {
  @Test @MainActor func renewsAtTheSameFrameAndPreservesPauseSeekAndBoundedBuffers() async throws {
    let transport = PlaybackTransportFixture()
    await transport.expireOneSegment()
    let output = PlaybackOutputFixture()
    let player = CallAudioPlayer(transport: transport, output: output)
    defer { player.clear() }
    await player.load(callID: playbackCallID, positionMs: 45_000, autoplay: true)
    #expect(player.state.phase == .playing && player.state.positionMs == 45_000)
    #expect(await transport.operations.count == 2)
    #expect(await transport.segmentRequests == [1, 1, 2])
    #expect(output.buffers.map(\.pcm.startFrame) == [720_000, 960_000])
    #expect(output.buffers.map(\.pcm.frameCount) == [240_000, 240_000])
    output.advance(frames: 16_000)
    player.updatePosition()
    #expect(player.state.positionMs == 46_000)
    player.pause()
    output.advance(frames: 100_000)
    player.updatePosition()
    #expect(player.state.phase == .paused && player.state.positionMs == 46_000)
    await player.seek(positionMs: 5_000)
    #expect(player.state.phase == .paused && player.state.positionMs == 5_000)
    #expect(output.buffers.first?.pcm.startFrame == 80_000)
    await player.play()
    output.advance(frames: 32_000)
    player.updatePosition()
    #expect(player.state.positionMs == 7_000 && output.maximumQueued == 2)
    player.clear(callID: playbackCallID)
    #expect(player.state.phase == .idle && output.buffers.isEmpty && !output.playing)
  }

  @Test @MainActor func freezesAtAnUnderrunAndContinuesAtTheNextSourceFrame() async throws {
    let transport = PlaybackTransportFixture()
    let output = PlaybackOutputFixture()
    let player = CallAudioPlayer(transport: transport, output: output)
    defer { player.clear() }
    await player.load(callID: playbackCallID, autoplay: true)
    await transport.hold(index: 2)
    output.advance(frames: 960_000)
    for await index in transport.requests where index == 2 { break }
    #expect(player.state.phase == .loading && player.state.positionMs == 60_000)
    output.advance(frames: 1_000_000)
    player.updatePosition()
    #expect(player.state.positionMs == 60_000)
    await transport.release()
    for await start in output.enqueues where start == 960_000 { break }
    #expect(player.state.phase == .playing && output.buffers.first?.pcm.startFrame == 960_000)
    output.advance(frames: 16_000)
    player.updatePosition()
    #expect(player.state.positionMs == 61_000)
    output.advance(frames: 224_000)
    #expect(player.state.phase == .finished && player.state.positionMs == 75_000)
    await player.play()
    #expect(player.state.phase == .playing && player.state.positionMs == 0)
  }

  @Test @MainActor func switchingAndClearingCallsRejectLateLoadedAudio() async throws {
    let transport = PlaybackTransportFixture()
    let output = PlaybackOutputFixture()
    let player = CallAudioPlayer(transport: transport, output: output)
    defer { player.clear() }
    await transport.hold(index: 0)
    let old = Task { await player.load(callID: playbackCallID, autoplay: true) }
    for await index in transport.requests where index == 0 { break }
    let other = UUID().uuidString.lowercased()
    await player.load(callID: other, positionMs: 45_000)
    await transport.release()
    await old.value
    #expect(player.state.callID == other && player.state.phase == .paused)
    #expect(output.buffers.first?.pcm.startFrame == 720_000)
    player.clear(callID: playbackCallID)
    #expect(player.state.callID == other)
    await transport.hold(index: 0)
    let loading = Task { await player.seek(positionMs: 0) }
    for await index in transport.requests where index == 0 { break }
    player.clear(callID: other)
    await transport.release()
    await loading.value
    #expect(player.state.phase == .idle && output.buffers.isEmpty)
  }

  @Test @MainActor func aServerFailurePreservesTheSelectedPassage() async throws {
    let transport = PlaybackTransportFixture()
    await transport.fail(index: 1)
    let output = PlaybackOutputFixture()
    let player = CallAudioPlayer(transport: transport, output: output)
    defer { player.clear() }
    await player.load(callID: playbackCallID, positionMs: 45_000, autoplay: true)
    #expect(player.state.phase == .error && player.state.positionMs == 45_000)
    #expect(output.buffers.isEmpty)
    await player.play()
    #expect(player.state.phase == .playing && player.state.positionMs == 45_000)
  }

  @Test func strictWaveDecodingPreservesSourceChannelsAndRejectsBadLengths() throws {
    let wave = playbackWave(frames: 1600)
    let pcm = try PlaybackValidation.decodeWave(wave, startFrame: 480_000, frameCount: 1600)
    let trimmed = try pcm.trimming(before: 480_016)
    #expect(trimmed.startFrame == 480_016 && trimmed.frameCount == 1584)
    let samples = pcm.samples.withUnsafeBytes { raw in
      (
        Int16(littleEndian: raw.loadUnaligned(as: Int16.self)),
        Int16(littleEndian: raw.loadUnaligned(fromByteOffset: 2, as: Int16.self))
      )
    }
    #expect(samples == (12_000, -8_000))
    #expect(throws: CallPlaybackError.invalidMedia) {
      try PlaybackValidation.decodeWave(wave.dropLast(), startFrame: 0, frameCount: 1600)
    }
    var altered = wave
    altered[22] = 1
    #expect(throws: CallPlaybackError.invalidMedia) {
      try PlaybackValidation.decodeWave(altered, startFrame: 0, frameCount: 1600)
    }
  }

  @Test @MainActor func theRealAudioEngineRendersBothChannelsInTheSameFrames() throws {
    let engine = AVAudioEngine()
    let output = AVPlaybackAudioOutput(engine: engine)
    defer { output.stop() }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    let pcm = try PlaybackValidation.decodeWave(
      playbackWave(frames: 1600),
      startFrame: 0,
      frameCount: 1600
    )
    try output.enqueue(pcm) {}
    try output.play()
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
    #expect(try engine.renderOffline(1600, to: buffer) == .success)
    let channels = try #require(buffer.floatChannelData)
    #expect(buffer.frameLength == 1600)
    for frame in [0, 128, 1599] {
      #expect(abs(channels[0][frame] - Float(12000) / 32768) < 0.0001)
      #expect(abs(channels[1][frame] - Float(-8000) / 32768) < 0.0001)
    }
  }
}
