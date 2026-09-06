import AVFoundation
import CoreMedia
import Foundation

public struct CaptureAudioFrames: Sendable {
  public let startFrame: Int
  public let samples: [Int16]
}

/// Converts native PCM (including the microphone's independent hardware format) to the
/// profile rate. Each source owns one converter; both use the same host-clock origin.
public final class CaptureAudioDecoder {
  private var converter: AVAudioConverter?
  public init() {}

  public func decode(_ sample: CMSampleBuffer, origin: CMTime) throws -> CaptureAudioFrames {
    guard sample.isValid, CMSampleBufferDataIsReady(sample),
      let description = sample.formatDescription,
      CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
      sample.presentationTimeStamp.isNumeric, origin.isNumeric,
      sample.numSamples > 0, sample.numSamples <= 192_000
    else { throw CaptureError.invalidAudio }
    let format = AVAudioFormat(cmAudioFormatDescription: description)
    guard format.sampleRate >= 8_000, format.sampleRate <= 192_000,
      format.channelCount > 0, format.channelCount <= 8,
      Double(sample.numSamples) / format.sampleRate <= 1,
      let input = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)),
      let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    else { throw CaptureError.invalidAudio }
    input.frameLength = AVAudioFrameCount(sample.numSamples)
    guard
      CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sample, at: 0, frameCount: Int32(sample.numSamples),
        into: input.mutableAudioBufferList) == noErr
    else { throw CaptureError.invalidAudio }
    if converter?.inputFormat != format {
      converter = AVAudioConverter(from: format, to: outputFormat)
      converter?.primeMethod = .none
    }
    guard let converter,
      let output = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: AVAudioFrameCount(
          ceil(Double(sample.numSamples) * 16_000 / format.sampleRate)) + 64)
    else { throw CaptureError.invalidAudio }
    let supply = CaptureConverterInput(input)
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { requested, inputStatus in
      supply.take(count: requested, status: inputStatus)
    }
    guard error == nil, status != .error, let floats = output.floatChannelData?[0] else {
      throw CaptureError.invalidAudio
    }
    let relative = CMTimeSubtract(sample.presentationTimeStamp, origin)
    let seconds = CMTimeGetSeconds(relative)
    guard seconds.isFinite, seconds >= -2, seconds <= 10_802 else {
      throw CaptureError.invalidAudio
    }
    var samples = [Int16]()
    samples.reserveCapacity(Int(output.frameLength))
    for index in 0..<Int(output.frameLength) {
      let value = floats[index]
      guard value.isFinite else { throw CaptureError.invalidAudio }
      samples.append(Int16(max(-32_768, min(32_767, (value * 32_768).rounded()))))
    }
    return .init(startFrame: Int((seconds * 16_000).rounded()), samples: samples)
  }
}

/// AVAudioConverter may pull less than a complete callback buffer at a time. Advance
/// only by the requested input frames; returning the whole buffer silently drops its tail.
private final class CaptureConverterInput: @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: AVAudioPCMBuffer
  private var offset: AVAudioFrameCount = 0
  init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
  func take(count: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>)
    -> AVAudioBuffer?
  {
    lock.lock()
    defer { lock.unlock() }
    guard offset < buffer.frameLength else {
      status.pointee = .noDataNow
      return nil
    }
    let frames = min(count, buffer.frameLength - offset)
    guard let chunk = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames) else {
      status.pointee = .noDataNow
      return nil
    }
    chunk.frameLength = frames
    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let target = UnsafeMutableAudioBufferListPointer(chunk.mutableAudioBufferList)
    let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    for index in 0..<source.count {
      if let input = source[index].mData, let output = target[index].mData {
        memcpy(output, input.advanced(by: Int(offset) * bytesPerFrame), Int(frames) * bytesPerFrame)
      }
    }
    offset += frames
    status.pointee = .haveData
    return chunk
  }
}
