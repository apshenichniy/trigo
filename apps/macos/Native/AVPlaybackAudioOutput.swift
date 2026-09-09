import AVFoundation
import Foundation

/// Two source channels stay separate through decoding and the AVAudioEngine output mix.
@MainActor final class AVPlaybackAudioOutput: PlaybackAudioOutput {
  let engine: AVAudioEngine
  private let node = AVAudioPlayerNode()
  private let format: AVAudioFormat

  init(engine: AVAudioEngine = AVAudioEngine()) {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2) else {
      preconditionFailure("The fixed stereo playback format is invalid")
    }
    self.engine = engine
    self.format = format
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
  }

  var renderedFrames: Int {
    guard let renderTime = node.lastRenderTime,
      renderTime.isSampleTimeValid || renderTime.isHostTimeValid,
      let playerTime = node.playerTime(forNodeTime: renderTime),
      playerTime.isSampleTimeValid
    else { return 0 }
    return max(0, Int(playerTime.sampleTime))
  }

  func enqueue(_ pcm: PlaybackPCM, completed: @escaping @MainActor @Sendable () -> Void) throws {
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(pcm.frameCount)
      ),
      let channels = buffer.floatChannelData
    else { throw CallPlaybackError.audioOutput }
    buffer.frameLength = AVAudioFrameCount(pcm.frameCount)
    pcm.samples.withUnsafeBytes { bytes in
      for frame in 0..<pcm.frameCount {
        for channel in 0..<2 {
          let raw = bytes.loadUnaligned(fromByteOffset: frame * 4 + channel * 2, as: Int16.self)
          channels[channel][frame] = Float(Int16(littleEndian: raw)) / 32768
        }
      }
    }
    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
      Task { @MainActor in completed() }
    }
  }

  func play() throws {
    do {
      if !engine.isRunning { try engine.start() }
      node.play()
    } catch { throw CallPlaybackError.audioOutput }
  }

  func pause() { node.pause() }
  func stop() {
    node.stop()
    engine.stop()
  }
}
