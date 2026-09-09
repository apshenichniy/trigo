import AVFoundation
import CoreMedia
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

private final class LateIngressFailures: @unchecked Sendable {
  let lock = NSLock()
  private var reasons: [String] = []
  func record(_ reason: String) { lock.withLock { reasons.append(reason) } }
  var values: [String] { lock.withLock { reasons } }
}

@Test(arguments: [MediaSourceRole.application, .microphone], [false, true])
@MainActor func productionSinkSurvivesSilentStartupAndDelayedAudioBurst(
  role: MediaSourceRole,
  soundAppears: Bool
) async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let queue = DispatchQueue(label: "trigo.test.silent-startup-burst")
  let failures = LateIngressFailures()
  let sink = try CaptureStreamSink(
    session: session,
    queue: queue,
    origin: CMTime(value: 100, timescale: 1),
    microphone: session.microphone,
    onSnapshot: { _ in },
    onMicrophoneFailure: { _ in failures.record("microphone_unavailable") },
    onFailure: { failures.record($0) }
  )
  let stream = RecordingTransportFixture()
  if role == .application {
    sink.acceptApplicationStream(stream)
  } else {
    sink.acceptMicrophoneStream(stream)
  }
  // No callbacks during silence. The real timer has already committed 0...1.475 s
  // as unavailable when SCK delivers its first application burst at 2.08 s.
  try await sink.perform { _ in
    try sink.advanceClock(at: CMTime(value: 101_725, timescale: 1000))
  }
  // Deliver the observed 48 kHz / 20 ms packet pattern as one callback turn.
  // Holding the consumer makes that burst deterministic, not a throughput test.
  let samples = try (20..<104)
    .map { packet in
      let time = CMTime(value: Int64(5000 + packet), timescale: 50)
      return try controlledAudioBuffer(
        sampleRate: 48_000,
        frames: 960,
        time: time,
        value: soundAppears && packet >= 75 ? 0.5 : 0
      )
    }
  queue.suspend()
  for sample in samples {
    sink.enqueue(
      sample,
      role: role,
      streamID: ObjectIdentifier(stream),
      deliveredAt: CMTime(value: 102_080, timescale: 1000)
    )
  }
  queue.resume()
  let result = try await sink.finish(at: CMTime(value: 102_080, timescale: 1000), reason: nil)
  _ = try await session.complete(media: result.0, interruptionReason: nil)
  #expect(failures.values.isEmpty)
  #expect(!sink.ingressStatistics.rejected)
  #expect(sink.ingressStatistics.maximumPendingSourceSeconds <= 1.000_001)
  #expect(sink.ingressStatistics.pendingBuffers == 0)
  let repository = try LocalRepository(root: root, archiveID: session.archiveID)
  let spans = try repository.captureIntervals(callID: session.callID, through: result.0.cursor)
  let channel = role == .microphone ? 0 : 1
  #expect(
    spans[channel] == [
      .init(startMs: 0, endMs: 1475, state: .unavailable),
      .init(startMs: 1475, endMs: 2080, state: .recorded),
    ]
  )
  let file = try AVAudioFile(
    forReading: session.mediaDirectory.appendingPathComponent("master.caf")
  )
  let pcm = try #require(
    AVAudioPCMBuffer(
      pcmFormat: file.processingFormat,
      frameCapacity: AVAudioFrameCount(file.length)
    )
  )
  try file.read(into: pcm)
  let channels = try #require(pcm.floatChannelData)
  #expect((0..<1475 * 16).allSatisfy { channels[channel][$0] == 0 })
  #expect(abs(channels[channel][2000 * 16] - (soundAppears ? 0.5 : 0)) < 0.001)
  #expect((0..<Int(file.length)).allSatisfy { channels[1 - channel][$0] == 0 })
}

@Test @MainActor func productionSinkContinuesThroughSilenceWithoutCallbacks() async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let failures = LateIngressFailures()
  let sink = try CaptureStreamSink(
    session: session,
    queue: DispatchQueue(label: "trigo.test.silent-capture"),
    origin: .zero,
    microphone: session.microphone,
    onSnapshot: { _ in },
    onMicrophoneFailure: { _ in failures.record("microphone_unavailable") },
    onFailure: { failures.record($0) }
  )
  try await sink.perform { engine in
    for halfSecond in 1...20 {
      try sink.advanceClock(at: CMTime(value: Int64(halfSecond), timescale: 2))
      #expect(engine.snapshot.state == .recording)
    }
  }
  let result = try await sink.finish(at: CMTime(value: 10, timescale: 1), reason: nil)
  _ = try await session.complete(media: result.0, interruptionReason: nil)
  #expect(result.1.state == .stopped)
  #expect(result.0.durationMs == 10_000)
  #expect(failures.values.isEmpty)
  let repository = try LocalRepository(root: root, archiveID: session.archiveID)
  let spans = try repository.captureIntervals(callID: session.callID, through: result.0.cursor)
  #expect(spans.allSatisfy { $0 == [.init(startMs: 0, endMs: 10_000, state: .unavailable)] })
}
