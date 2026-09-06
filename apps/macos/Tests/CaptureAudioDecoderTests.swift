import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import TrigoNative

func controlledAudioBuffer(sampleRate: Double, frames: Int, time: CMTime, value: Float) throws
  -> CMSampleBuffer
{
  let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
  let pcm = try #require(
    AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
  pcm.frameLength = AVAudioFrameCount(frames)
  for frame in 0..<frames { pcm.floatChannelData![0][frame] = value }
  var description: CMAudioFormatDescription?
  #expect(
    CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr)
  var timing = CMSampleTimingInfo(
    duration: CMTime(value: 1, timescale: Int32(sampleRate)),
    presentationTimeStamp: time, decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  #expect(
    CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: nil,
      formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1,
      sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
      sampleBufferOut: &sample) == noErr)
  let result = try #require(sample)
  #expect(
    CMSampleBufferSetDataBufferFromAudioBufferList(
      result, blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList)
      == noErr)
  return result
}

@Test func nativeSampleBufferConversionPreservesHostClockOffsetAndMonoLevel() throws {
  let decoder = CaptureAudioDecoder()
  let origin = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
  let sample = try controlledAudioBuffer(
    sampleRate: 48_000, frames: 4_800,
    time: CMTime(seconds: 100.25, preferredTimescale: 1_000_000_000), value: 0.25)
  let decoded = try decoder.decode(sample, origin: origin)
  #expect(decoded.startFrame == 4_000)
  #expect(abs(decoded.samples.count - 1_600) <= 1)
  #expect(decoded.samples.dropFirst(64).dropLast(64).allSatisfy { abs(Int($0) - 8_192) <= 2 })
}
