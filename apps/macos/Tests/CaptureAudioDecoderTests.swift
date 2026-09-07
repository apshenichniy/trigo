import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import TrigoNative

func controlledAudioBuffer(
  sampleRate: Double, frames: Int, time: CMTime, value: Float, channels: AVAudioChannelCount = 1
) throws
  -> CMSampleBuffer
{
  let format = try #require(
    AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
  let pcm = try #require(
    AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
  pcm.frameLength = AVAudioFrameCount(frames)
  for channel in 0..<Int(channels) {
    for frame in 0..<frames { pcm.floatChannelData![channel][frame] = value }
  }
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
  let decoder = try CaptureAudioDecoder()
  let origin = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
  let sample = try controlledAudioBuffer(
    sampleRate: 48_000, frames: 4_800,
    time: CMTime(seconds: 100.25, preferredTimescale: 1_000_000_000), value: 0.25)
  let decoded = try decoder.decode(sample, origin: origin)
  #expect(decoded.startFrame == 4_000)
  #expect(abs(decoded.samples.count - 1_600) <= 1)
  #expect(decoded.samples.dropFirst(64).dropLast(64).allSatisfy { abs(Int($0) - 8_192) <= 2 })
}

@Test(arguments: [48_000.0, 44_100.0], [0.0, 0.00003, 0.00005])
func hardwareMicrophonePacketsDoNotCreatePeriodicHolesInPersistedPCM(
  sampleRate: Double, startOffset: Double
) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-hardware-cadence-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let engine = try CaptureRecordingEngine(
    writer: writer, origin: .zero,
    microphone: .init(id: "fixture", name: "Hardware packet cadence"))
  // Hardware callbacks need not contain an integral number of output frames:
  // 512 frames at 48 kHz span 170 2/3 frames at the persisted 16 kHz rate.
  for packet in 0..<8 {
    try engine.receive(
      controlledAudioBuffer(
        sampleRate: sampleRate, frames: 512,
        time: CMTime(
          seconds: startOffset + Double(packet * 512) / sampleRate,
          preferredTimescale: 1_000_000_000), value: 0.25),
      role: .microphone)
  }
  let media = try engine.stop(at: CMTime(value: 8 * 512, timescale: Int32(sampleRate)))
  let file = try AVAudioFile(
    forReading: writer.master.mediaURL)
  let buffer = try #require(
    AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
  try file.read(into: buffer)
  let mic = try #require(buffer.floatChannelData)[0]
  // Exclude converter startup/tail; every interior sample of this constant source exists.
  let holes = (512..<(Int(buffer.frameLength) - 512)).filter { mic[$0] == 0 }
  #expect(holes.isEmpty, "Periodic PCM holes at output frames \(Array(holes.prefix(12)))")
  let interiorGaps = (try captureIntervals(writer, role: .microphone)).filter {
    $0.state == .unavailable && $0.startMs > 32 && $0.endMs < media.durationMs - 32
  }
  #expect(interiorGaps.isEmpty, "Unexpected interior microphone gaps: \(interiorGaps.count)")
}

@Test func conversionRetainsRealHostClockGapsAndResetsFilterHistory() throws {
  let decoder = try CaptureAudioDecoder()
  let origin = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
  _ = try decoder.decode(
    controlledAudioBuffer(sampleRate: 48_000, frames: 512, time: origin, value: 0.9), origin: origin
  )
  let resumed = try decoder.decode(
    controlledAudioBuffer(
      sampleRate: 48_000, frames: 512,
      time: CMTime(seconds: 100.1, preferredTimescale: 1_000_000_000), value: 0), origin: origin)
  #expect(resumed.startFrame == 1_600)
  #expect(resumed.samples.allSatisfy { $0 == 0 })
}

@Test func fractionalPacketPlacementRemainsBoundedByHostClock() throws {
  let decoder = try CaptureAudioDecoder()
  let origin = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
  var worstClockError = 0
  // A hardware clock can drift relative to the common host clock. Do not replace
  // timestamp placement with an unbounded cumulative sample counter.
  for packet in 0..<1_000 {
    let relative = 0.123456 + Double(packet * 512) / 48_000 * 1.0005
    let decoded = try decoder.decode(
      controlledAudioBuffer(
        sampleRate: 48_000, frames: 512,
        time: CMTime(seconds: 100 + relative, preferredTimescale: 1_000_000_000), value: 0.25),
      origin: origin)
    worstClockError = max(
      worstClockError, abs(decoded.startFrame - Int((relative * 16_000).rounded())))
  }
  #expect(worstClockError <= 1)
}
