import AVFoundation
import Foundation
import Testing

@testable import TrigoNative

/// Local R2-compatible multipart fixture only. Part identifiers are transport receipts, not hashes.
/// Every non-final part is the same 8 MiB (>=5 MiB); final may be smaller; <=10,000 total parts.
final class MasterMultipartFixture {
  let directory: URL
  private var completed = false
  private(set) var parts = 0
  private(set) var bytes: Int64 = 0
  let partSize = MediaMasterProfile.maximumRequestBytes

  init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func put(_ data: Data, number: Int, final: Bool) throws {
    guard !completed, number == parts + 1, number <= 10000, !data.isEmpty,
      data.count <= partSize, final || data.count == partSize,
      final || data.count >= 5 * 1024 * 1024
    else { throw MediaMasterError.invalidInput }
    try data.write(
      to: directory.appendingPathComponent("part-\(number)"), options: .withoutOverwriting)
    parts = number
    bytes += Int64(data.count)
    completed = final
  }

  func uploadAvailable(_ writer: RecoverableMediaMaster, final: Bool) throws {
    while writer.cursor.stableBytes - bytes >= Int64(partSize) {
      let end = bytes + Int64(partSize)
      try put(
        writer.readStableBytes(in: bytes..<end), number: parts + 1,
        final: final && end == writer.cursor.stableBytes)
    }
    if final && bytes < writer.cursor.stableBytes {
      try put(
        writer.readStableBytes(in: bytes..<writer.cursor.stableBytes), number: parts + 1,
        final: true)
    }
  }

  func reconstruct(to url: URL) throws {
    guard completed else { throw MediaMasterError.invalidInput }
    let destination = try MediaMasterIO.create(url)
    defer { try? destination.close() }
    for part in 1...parts {
      let source = try FileHandle(forReadingFrom: directory.appendingPathComponent("part-\(part)"))
      defer { try? source.close() }
      while let block = try source.readMasterBytes(upToCount: 64000), !block.isEmpty {
        try destination.write(contentsOf: block)
      }
    }
    try destination.synchronize()
  }
}

@Test func mediaMasterMultipartAndBoundedExtractionRetainProvenance() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let mediaRoot = root.appendingPathComponent("media")
  let identity = masterFixtureIdentity()
  let writer = try RecoverableMediaMaster(directory: mediaRoot, identity: identity)
  let sink = try MasterMultipartFixture(directory: root.appendingPathComponent("upload"))
  for second in 0..<265 {
    try masterFixtureSecond(second, into: writer)
    try sink.uploadAvailable(writer, final: false)
  }
  #expect(sink.parts == 2)
  let firstHash = try masterFileHash(sink.directory.appendingPathComponent("part-1"))
  let confirmed = writer.cursor
  let reopened = try RecoverableMediaMaster(
    reopening: mediaRoot, expectedIdentity: identity, confirmed: confirmed)
  let final = try reopened.finish()
  #expect(reopened.cursor == confirmed)
  #expect(
    try reopened.readStableBytes(in: 0..<Int64(sink.partSize)).masterSHA256.masterHex == firstHash)
  try sink.uploadAvailable(reopened, final: true)
  #expect(sink.parts == 3)
  let reconstructed = root.appendingPathComponent("reconstructed.caf")
  try sink.reconstruct(to: reconstructed)
  #expect(try masterFileHash(reconstructed) == final.sha256)
  #expect(try AVAudioFile(forReading: reconstructed).length == final.cursor.frames)
  #expect(throws: MediaMasterError.invalidInput) {
    try reopened.readStableBytes(in: 0..<Int64(sink.partSize + 1))
  }
  let invalidSink = try MasterMultipartFixture(
    directory: root.appendingPathComponent("invalid-upload"))
  #expect(throws: MediaMasterError.invalidInput) {
    try invalidSink.put(Data([1]), number: 1, final: false)
  }
  #expect(throws: MediaMasterError.invalidInput) {
    try invalidSink.put(Data([1]), number: 10001, final: true)
  }

  for (startMs, endMs) in [(0, 2051), (999, 2104), (130999, 264997)] {
    let output = root.appendingPathComponent("interval-\(startMs).caf")
    var microphone: [CaptureInterval] = []
    var application: [CaptureInterval] = []
    var largestCallback = 0
    let extraction = try reopened.extract(
      frames: Int64(startMs * 16)..<Int64(endMs * 16), to: output
    ) { commit in
      largestCallback = max(
        largestCallback, commit.microphoneIntervals.count + commit.applicationIntervals.count)
      for span in commit.microphoneIntervals { mergeCaptureInterval(span, into: &microphone) }
      for span in commit.applicationIntervals { mergeCaptureInterval(span, into: &application) }
    }
    #expect(extraction.master == final)
    #expect(
      extraction.startFrame == Int64(startMs * 16) && extraction.endFrame == Int64(endMs * 16))
    #expect(extraction.profileID == MediaMasterProfile.id)
    #expect(extraction.microphoneChannel == 0 && extraction.applicationChannel == 1)
    #expect(try masterFileHash(output) == extraction.sha256)
    #expect(largestCallback <= 2000)
    #expect(microphone.first?.startMs == startMs && microphone.last?.endMs == endMs)
    #expect(application.first?.startMs == startMs && application.last?.endMs == endMs)
    for (channel, spans) in [microphone, application].enumerated() {
      for span in spans {
        for ms in span.startMs..<span.endMs {
          #expect(
            span.state == masterState(second: ms / 1000, millisecond: ms % 1000, channel: channel))
        }
      }
    }
    let audio = try AVAudioFile(forReading: output)
    #expect(audio.length == Int64(endMs - startMs) * 16)
    let buffer = try #require(
      AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16000))
    var readFrames: Int64 = 0
    while readFrames < audio.length {
      try audio.read(into: buffer)
      try checkMasterSamples(buffer, startFrame: Int64(startMs) * 16 + readFrames)
      readFrames += Int64(buffer.frameLength)
    }
  }
  print(
    "MASTER_TRANSPORT during_capture_parts=2 final_parts=3 request_cap=8388608 exact_whole_sha256=true extracted_call_intervals_ms=0:2051,999:2104,130999:264997"
  )
}

@Test func mediaMasterWorstCaseMetadataIsBoundedAndSuppressionPrecedesPersistence() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try RecoverableMediaMaster(directory: root, identity: masterFixtureIdentity())
  let mic = (0..<1000).map {
    CaptureInterval(startMs: $0, endMs: $0 + 1, state: $0 % 2 == 0 ? .muted : .unavailable)
  }
  let app = (0..<1000).map {
    CaptureInterval(startMs: $0, endMs: $0 + 1, state: $0 % 2 == 0 ? .recorded : .unavailable)
  }
  try writer.append(
    interleaved: Array(repeating: 30000, count: 32000), microphoneIntervals: mic,
    applicationIntervals: app)
  let bytes = try writer.readStableBytes(in: 68..<64068)
  bytes.withUnsafeBytes { raw in
    let samples = raw.bindMemory(to: Int16.self)
    #expect((0..<16000).allSatisfy { samples[$0 * 2] == 0 })
    #expect((0..<16000).allSatisfy { samples[$0 * 2 + 1] == ($0 / 16 % 2 == 0 ? 30000 : 0) })
  }
  _ = try writer.finish()
  let recovered = try RecoverableMediaMaster(
    reopening: root, expectedIdentity: writer.identity, confirmed: writer.cursor)
  try recovered.forEachCommit(intersecting: 0..<16000) { commit in
    #expect(commit.microphoneIntervals == mic && commit.applicationIntervals == app)
  }
  let indexSize =
    try FileManager.default.attributesOfItem(
      atPath: root.appendingPathComponent("master.index").path)[.size] as? Int
  #expect(indexSize == 128 + 2120 * 2)
}

@Test func mediaMasterRejectsIncompleteSourceEvidenceBeforeWriting() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try RecoverableMediaMaster(directory: root, identity: masterFixtureIdentity())
  let initial = writer.cursor
  let recorded = CaptureInterval(startMs: 0, endMs: 1000, state: .recorded)
  let pcm = Array(repeating: Int16(30000), count: 32000)
  let invalidMicrophoneSpans: [[CaptureInterval]] = [
    [], [.init(startMs: 1, endMs: 1000, state: CaptureIntervalState.recorded)],
    [.init(startMs: 0, endMs: 999, state: .recorded)],
  ]
  for badMic in invalidMicrophoneSpans {
    #expect(throws: MediaMasterError.invalidInput) {
      try writer.append(
        interleaved: pcm, microphoneIntervals: badMic, applicationIntervals: [recorded])
    }
  }
  #expect(throws: MediaMasterError.invalidInput) {
    try writer.append(
      interleaved: pcm, microphoneIntervals: [recorded],
      applicationIntervals: [.init(startMs: 0, endMs: 1000, state: .muted)])
  }
  for size in [0, 31, 32032] {
    #expect(throws: MediaMasterError.invalidInput) {
      try writer.append(
        interleaved: Array(repeating: 30000, count: size),
        microphoneIntervals: [recorded], applicationIntervals: [recorded])
    }
  }
  #expect(writer.cursor == initial)
  #expect(
    try FileManager.default.attributesOfItem(atPath: writer.mediaURL.path)[.size] as? Int == 68)
}
