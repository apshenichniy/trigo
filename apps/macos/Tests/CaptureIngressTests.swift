import CoreMedia
import Foundation
import Testing

@testable import TrigoNative

private final class IngressFixtureState: @unchecked Sendable {
  let lock = NSLock()
  var count = 0
  var overflow = false
  @discardableResult func consumed() -> Int {
    lock.withLock {
      count += 1
      return count
    }
  }
  func failed() { lock.withLock { overflow = true } }
}

@Test func captureIngressRejectsOverloadWithoutAnUnboundedAudioQueue() async throws {
  let queue = DispatchQueue(label: "trigo.test.blocked-capture")
  queue.suspend()
  let state = IngressFixtureState()
  let ingress = CaptureAudioIngress(
    queue: queue, consume: { _ in state.consumed() },
    overflow: { state.failed() })
  let stream = NSObject()
  ingress.select(ObjectIdentifier(stream), for: .microphone)
  let sample = try controlledAudioBuffer(sampleRate: 48_000, frames: 4_800, time: .zero, value: 0.5)
  for _ in 0..<10 {
    #expect(
      ingress.submit(
        sample, role: .microphone, streamID: ObjectIdentifier(stream), deliveredAt: .zero))
  }
  for _ in 0..<1000 {
    #expect(
      !ingress.submit(
        sample, role: .microphone, streamID: ObjectIdentifier(stream), deliveredAt: .zero))
  }
  #expect(ingress.statistics.maximumPendingBuffers == 10)
  #expect(ingress.statistics.maximumPendingSourceSeconds <= 1.000_001)
  queue.resume()
  await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
  #expect(state.lock.withLock { state.count == 10 && state.overflow })
}

private final class ReplenishingIngress: @unchecked Sendable {
  var ingress: CaptureAudioIngress!
}

@Test func captureIngressYieldsToControlsWhileAProducerReplenishesItsQueue() async throws {
  let queue = DispatchQueue(label: "trigo.test.replenishing-capture")
  queue.suspend()
  let state = IngressFixtureState()
  let holder = ReplenishingIngress()
  let stream = NSObject()
  let id = ObjectIdentifier(stream)
  let sample = try controlledAudioBuffer(sampleRate: 48_000, frames: 48, time: .zero, value: 0.5)
  let done = AsyncStream<Void> { continuation in
    holder.ingress = CaptureAudioIngress(
      queue: queue,
      consume: { next in
        if state.consumed() < 1000 {
          #expect(
            holder.ingress.submit(next.sample, role: .microphone, streamID: id, deliveredAt: .zero))
        } else {
          continuation.finish()
        }
      }, overflow: { state.failed() })
  }
  holder.ingress.select(id, for: .microphone)
  #expect(holder.ingress.submit(sample, role: .microphone, streamID: id, deliveredAt: .zero))
  let countAtControl = await withCheckedContinuation { continuation in
    queue.async { continuation.resume(returning: state.lock.withLock { state.count }) }
    queue.resume()
  }
  #expect(countAtControl > 0 && countAtControl <= 8)
  for await _ in done {}
  #expect(state.lock.withLock { state.count == 1000 && !state.overflow })
  #expect(holder.ingress.statistics.maximumPendingBuffers <= 2)
}

@Test @MainActor func productionSinkRejectsStaleForeignAndReplacedStreamsBeforeCapacity()
  async throws
{
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let queue = DispatchQueue(label: "trigo.test.sink-admission")
  let failures = IngressFixtureState()
  let sink = try CaptureStreamSink(
    session: session, queue: queue, origin: .zero,
    microphone: session.microphone, onSnapshot: { _ in },
    onMicrophoneFailure: { _ in failures.failed() },
    onFailure: { _ in failures.failed() })
  let old = RecordingTransportFixture()
  let current = RecordingTransportFixture()
  let application = RecordingTransportFixture()
  let foreign = RecordingTransportFixture()
  sink.acceptMicrophoneStream(old)
  sink.acceptApplicationStream(application)
  let sample = try controlledAudioBuffer(sampleRate: 48_000, frames: 4800, time: .zero, value: 0.5)
  queue.suspend()
  for _ in 0..<10 {
    #expect(
      sink.enqueue(sample, role: .microphone, streamID: ObjectIdentifier(old), deliveredAt: .zero))
  }
  sink.acceptMicrophoneStream(current)
  for _ in 0..<1000 {
    #expect(
      !sink.enqueue(sample, role: .microphone, streamID: ObjectIdentifier(old), deliveredAt: .zero))
    #expect(
      !sink.enqueue(
        sample, role: .application, streamID: ObjectIdentifier(foreign), deliveredAt: .zero))
    #expect(
      !sink.enqueue(
        sample, role: .microphone, streamID: ObjectIdentifier(application), deliveredAt: .zero))
  }
  #expect(
    sink.enqueue(sample, role: .microphone, streamID: ObjectIdentifier(current), deliveredAt: .zero)
  )
  #expect(
    sink.enqueue(
      sample, role: .application, streamID: ObjectIdentifier(application), deliveredAt: .zero))
  queue.resume()
  let master = try await sink.perform { try $0.stop(at: CMTime(value: 1, timescale: 10)) }
  let result = try await session.complete(media: master, interruptionReason: nil)
  #expect(result.call.captureState == .stopped)
  #expect(result.call.durationMs == 100)
  #expect(!sink.ingressStatistics.rejected)
  #expect(!failures.lock.withLock { failures.overflow })
}

@Test @MainActor func productionSinkStopPersistsAllAudioAdmittedAcrossMultipleDrainBatches()
  async throws
{
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let queue = DispatchQueue(label: "trigo.test.stop-drain")
  let failures = IngressFixtureState()
  let sink = try CaptureStreamSink(
    session: session, queue: queue, origin: .zero,
    microphone: session.microphone, onSnapshot: { _ in },
    onMicrophoneFailure: { _ in failures.failed() },
    onFailure: { _ in failures.failed() })
  let microphone = RecordingTransportFixture()
  let application = RecordingTransportFixture()
  sink.acceptMicrophoneStream(microphone)
  sink.acceptApplicationStream(application)
  queue.suspend()
  for part in 0..<50 {
    let time = CMTime(value: Int64(part), timescale: 50)
    let sample = try controlledAudioBuffer(sampleRate: 16_000, frames: 320, time: time, value: 0.5)
    #expect(
      sink.enqueue(
        sample, role: .microphone, streamID: ObjectIdentifier(microphone), deliveredAt: time))
    #expect(
      sink.enqueue(
        sample, role: .application, streamID: ObjectIdentifier(application), deliveredAt: time))
  }
  #expect(sink.ingressStatistics.pendingBuffers == 100)
  queue.resume()
  let result = try await sink.finish(at: CMTime(value: 1, timescale: 1), reason: nil)
  _ = try await session.complete(media: result.0, interruptionReason: nil)
  let repository = try LocalRepository(root: root, archiveID: session.archiveID)
  let spans = try repository.captureIntervals(callID: session.callID, through: result.0.cursor)
  #expect(spans.allSatisfy { $0 == [.init(startMs: 0, endMs: 1000, state: .recorded)] })
  #expect(!failures.lock.withLock { failures.overflow })
  #expect(sink.ingressStatistics.pendingBuffers == 0)
}

@Test @MainActor func productionTimerWaitsForAdmittedAudioAfterQueueDelayWithoutInventingGaps()
  async throws
{
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let queue = DispatchQueue(label: "trigo.test.delayed-timer")
  let failures = IngressFixtureState()
  let sink = try CaptureStreamSink(
    session: session, queue: queue, origin: .zero,
    microphone: session.microphone, onSnapshot: { _ in },
    onMicrophoneFailure: { _ in failures.failed() },
    onFailure: { _ in failures.failed() })
  let microphone = RecordingTransportFixture()
  let application = RecordingTransportFixture()
  sink.acceptMicrophoneStream(microphone)
  sink.acceptApplicationStream(application)
  let input = try (0..<50).map { part in
    let time = CMTime(value: Int64(part), timescale: 50)
    return (
      try controlledAudioBuffer(sampleRate: 16_000, frames: 320, time: time, value: 0.5), time
    )
  }
  queue.suspend()
  let began = ContinuousClock.now
  for (sample, time) in input {
    #expect(
      sink.enqueue(
        sample, role: .microphone, streamID: ObjectIdentifier(microphone), deliveredAt: time))
    #expect(
      sink.enqueue(
        sample, role: .application, streamID: ObjectIdentifier(application), deliveredAt: time))
  }
  let timer = AsyncThrowingStream<(FinalizedMediaMaster, ContinuousClock.Instant), any Error> {
    continuation in
    // Queued behind the first drain, before its follow-up. The real timer uses this
    // identical clock method, while 92 already-admitted buffers are still pending.
    queue.async {
      do {
        #expect(sink.ingressStatistics.pendingBuffers > 0)
        try sink.advanceClock(at: CMTime(value: 5, timescale: 4))
        let result = try sink.finishOnQueue(at: CMTime(value: 1, timescale: 1), reason: nil)
        continuation.yield((result.0, .now))
        continuation.finish()
      } catch { continuation.finish(throwing: error) }
    }
  }
  // The hold is released independently of MainActor test scheduling. Measure the
  // durable commit on the engine queue; report subsequent caller delivery separately.
  DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(300)) {
    queue.resume()
  }
  var finished: (FinalizedMediaMaster, ContinuousClock.Instant)?
  for try await value in timer { finished = value }
  let result = try #require(finished)
  let elapsed = began.duration(to: result.1).components
  let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
  let delivered = result.1.duration(to: .now).components
  let deliverySeconds = Double(delivered.seconds) + Double(delivered.attoseconds) / 1e18
  #expect(1 + seconds <= 2)
  _ = try await session.complete(media: result.0, interruptionReason: nil)
  let repository = try LocalRepository(root: root, archiveID: session.archiveID)
  let spans = try repository.captureIntervals(callID: session.callID, through: result.0.cursor)
  #expect(spans.allSatisfy { $0 == [.init(startMs: 0, endMs: 1000, state: .recorded)] })
  #expect(!failures.lock.withLock { failures.overflow })
  print(
    "PRODUCTION_DELAY input_ms=1000 blocked_ms=300 queue_and_final_commit_ms=\(seconds * 1000) max_input_plus_commit_ms=\(1000 + seconds * 1000) pending_timer_source_coverage=complete post_commit_caller_delivery_ms=\(deliverySeconds * 1000)"
  )
}
