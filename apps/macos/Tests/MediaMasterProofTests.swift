import AVFoundation
import CoreMedia
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func mediaMasterWaveCAFComparison() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let pcm = (0..<16000).flatMap { _ in [Int16(8192), Int16(-4096)] }.withUnsafeBytes { Data($0) }
  // Same simple LPCM payload in both candidates. Provisional WAVE lengths must be rewritten.
  func wave(_ payload: Int) -> Data {
    func le<T: FixedWidthInteger>(_ value: T) -> Data {
      var x = value.littleEndian
      return withUnsafeBytes(of: &x) { Data($0) }
    }
    var result = Data("RIFF".utf8)
    result += le(UInt32(36 + payload))
    result += Data("WAVEfmt ".utf8)
    result += le(UInt32(16))
    result += le(UInt16(1))
    result += le(UInt16(2))
    result += le(UInt32(16000))
    result += le(UInt32(64000))
    result += le(UInt16(4))
    result += le(UInt16(16))
    result += Data("data".utf8)
    result += le(UInt32(payload))
    return result
  }
  let initialWave = wave(0)
  let finalizedWave = wave(pcm.count)
  #expect(initialWave != finalizedWave)
  #expect(
    zip(initialWave, finalizedWave).enumerated().filter { $0.element.0 != $0.element.1 }
      .allSatisfy { (4..<8).contains($0.offset) || (40..<44).contains($0.offset) }
  )
  for (name, header) in [
    ("candidate.wav", finalizedWave), ("candidate.caf", MediaMasterProfile.header),
  ] {
    let url = root.appendingPathComponent(name)
    try (header + pcm).write(to: url)
    let audio = try AVAudioFile(forReading: url)
    #expect(audio.length == 16000)
    audio.framePosition = 8123
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 97)
    )
    try audio.read(into: buffer)
    #expect(buffer.floatChannelData?[0][0] == 0.25)
    #expect(buffer.floatChannelData?[1][96] == -0.125)
  }
  #expect(68 + Int64(10800) * 64000 < Int64(UInt32.max))
  print(
    "Candidate comparison: WAVE/CAF exact stereo decode and seek pass; WAVE changes size fields; CAF sentinel header remains immutable"
  )
}

private func proveLongMaster(seconds: Int) throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  let writer = try RecoverableMediaMaster(directory: root, identity: identity)
  let start = Date()
  var firstRange: Data?
  for second in 0..<seconds {
    try masterFixtureSecond(second, into: writer)
    if second == 132 {
      firstRange = try writer.readStableBytes(in: 0..<Int64(MediaMasterProfile.maximumRequestBytes))
      let active = try AVAudioFile(forReading: writer.mediaURL)
      #expect(active.length == 133 * 16000)
      active.framePosition = 100 * 16000 + 123
      let b = try #require(AVAudioPCMBuffer(pcmFormat: active.processingFormat, frameCapacity: 77))
      try active.read(into: b)
      try checkMasterSamples(b, startFrame: 100 * 16000 + 123)
    }
  }
  let appendSeconds = Date().timeIntervalSince(start)
  masterResources("append-\(seconds)")
  if seconds == 10800 {
    #expect(throws: MediaMasterError.invalidInput) { try appendMasterSecond(writer) }
  }
  #expect(throws: MediaMasterError.invalidInput) {
    try writer.readStableBytes(in: writer.cursor.stableBytes..<(writer.cursor.stableBytes + 1))
  }
  let final = try writer.finish()
  #expect(try writer.finish() == final)
  #expect(final.cursor.frames == Int64(seconds) * 16000)
  #expect(final.cursor.stableBytes == 68 + Int64(seconds) * 64000)
  #expect(
    try writer.readStableBytes(in: 0..<Int64(MediaMasterProfile.maximumRequestBytes)) == firstRange
  )
  let file = try AVAudioFile(forReading: writer.mediaURL)
  #expect(file.length == Int64(seconds) * 16000)
  #expect(file.fileFormat.sampleRate == 16000 && file.fileFormat.channelCount == 2)
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000)
  )
  let decodeStart = Date()
  for second in 0..<seconds {
    try file.read(into: buffer)
    #expect(buffer.frameLength == 16000)
    try checkMasterSamples(buffer, startFrame: Int64(second) * 16000)
  }
  let decodeSeconds = Date().timeIntervalSince(decodeStart)
  masterResources("decode-\(seconds)")
  for frame in [
    Int64(0), 1599, 1601, Int64(seconds / 2) * 16000 + 15993, Int64(seconds) * 16000 - 77,
  ] {
    file.framePosition = frame
    try file.read(into: buffer, frameCount: 77)
    try checkMasterSamples(buffer, startFrame: frame)
  }
  let reopenStart = Date()
  let reopened = try RecoverableMediaMaster(
    reopening: root,
    expectedIdentity: identity,
    confirmed: final.cursor
  )
  #expect(reopened.finalized == final)
  #expect(try reopened.finish() == final)
  #expect(try masterFileHash(writer.mediaURL) == final.sha256)
  var commits = 0
  var intervals = 0
  try reopened.forEachCommit(intersecting: 0..<final.cursor.frames) { commit in
    #expect(commit.startFrame == Int64(commits) * 16000)
    for (channel, spans) in [commit.microphoneIntervals, commit.applicationIntervals].enumerated() {
      for span in spans {
        #expect(
          span.state
            == masterState(second: commits, millisecond: span.startMs % 1000, channel: channel)
        )
        intervals += 1
      }
    }
    commits += 1
  }
  #expect(commits == seconds)
  let members = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
  #expect(members == ["master.caf", "master.index"])
  let indexSize =
    try
    FileManager.default
    .attributesOfItem(
      atPath: root.appendingPathComponent("master.index").path
    )[.size] as? Int
  #expect(indexSize == 128 + (seconds + 1) * 2120)
  let recoverySeconds = Date().timeIntervalSince(reopenStart)
  let extractionStart = Date()
  masterResources("reopen-index-\(seconds)")
  let extractionURL = root.appendingPathComponent("transient-interval.caf")
  var extractedRecords = 0
  let extraction = try reopened.extract(frames: 0..<final.cursor.frames, to: extractionURL) { _ in
    extractedRecords += 1
  }
  #expect(extractedRecords == seconds)
  #expect(extraction.sha256 == final.sha256)
  #expect(try masterFileHash(extractionURL) == final.sha256)
  try FileManager.default.removeItem(at: extractionURL)
  masterResources("extraction-\(seconds)")
  print(
    "MASTER_EXTRACTION seconds=\(seconds) extraction_and_hash_s=\(Date().timeIntervalSince(extractionStart)) callback_records=\(extractedRecords) pcm_block_bytes=64000"
  )
  print(
    "MASTER_PROOF seconds=\(seconds) frames=\(file.length) media_bytes=\(final.cursor.stableBytes) index_bytes=\(indexSize ?? -1) intervals=\(intervals) append_s=\(appendSeconds) decode_s=\(decodeSeconds) reopen_hash_index_s=\(recoverySeconds) sha256=\(final.sha256)"
  )
}

@Test func mediaMasterOneHourFrequentIntervals() throws { try proveLongMaster(seconds: 3600) }
@Test func mediaMasterThreeHourFrequentIntervals() throws { try proveLongMaster(seconds: 10800) }

@Test func mediaMasterOneHourCommonClockDrift() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try RecoverableMediaMaster(directory: root, identity: masterFixtureIdentity())
  let microphone = try CaptureAudioDecoder()
  let application = try CaptureAudioDecoder()
  for second in 0..<3600 {
    var pcm = Array(repeating: Int16(0), count: 32000)
    for part in 0..<10 {
      let time = CMTime(value: Int64(second * 10 + part), timescale: 10)
      let pulse: Float = part == 0 ? 0.25 : 0
      for (channel, decoder, rate, count) in [
        (0, microphone, 44100.0, 4410), (1, application, 48000.0, 4800),
      ] {
        let output = try decoder.decode(
          controlledAudioBuffer(
            sampleRate: rate,
            frames: count,
            time: time,
            value: channel == 0 ? pulse : -pulse
          ),
          origin: .zero
        )
        for (offset, value) in output.samples.enumerated() {
          let frame = output.startFrame + offset - second * 16000
          guard (0..<16000).contains(frame) else { throw MediaMasterError.invalidInput }
          pcm[frame * 2 + channel] = value
        }
      }
    }
    let span = CaptureInterval(startMs: second * 1000, endMs: (second + 1) * 1000, state: .recorded)
    try writer.append(interleaved: pcm, microphoneIntervals: [span], applicationIntervals: [span])
  }
  _ = try writer.finish()
  let file = try AVAudioFile(forReading: writer.mediaURL)
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16000)
  )
  var worst = 0
  for _ in 0..<3600 {
    try file.read(into: buffer)
    let channels = try #require(buffer.floatChannelData)
    let mic = try #require((0..<3200).first { channels[0][$0] > 0.1 })
    let app = try #require((0..<3200).first { channels[1][$0] < -0.1 })
    worst = max(worst, abs(mic - app))
  }
  #expect(file.length == 57_600_000)
  #expect(worst <= 3200)
  print("MASTER_DRIFT seconds=3600 source_rates=44100,48000 worst_ms=\(Double(worst) / 16)")
}
