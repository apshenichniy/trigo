import AVFoundation
import CoreMedia
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

/// Full-sync contention proof: new captures share a namespace with retained calls, imports,
/// large typed transcript reads, lifecycle changes and durable operation attempts/acks.
@Test(arguments: [false, true])
func repositoryBackgroundImportAndLargeTypedReadsStayInsideCaptureWindow(production: Bool)
  async throws
{
  let root = repositoryRoot("contention")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root, finalized: true)
  let audio = try repositoryFixture("audio.json")
  _ = try await repository.publishAudioManifest(audio)
  var call = try await repository.call(callID: repositoryCallID)
  call.documentVersion = 2
  call.audioManifest = .init(
    manifestId: "00000000-0000-4000-8000-000000000004", sha256: Contract.hash(audio))
  _ = try await repository.publishManifest(Contract.encode(call))
  let session = try repositorySession(root)
  try await session.prepare()
  let workload = RepositoryWorkload()
  let background = Task.detached(priority: .background) {
    defer { workload.complete() }
    var byteCount = 0
    for _ in 0..<3 {
      let captureStart = workload.captureCount
      var revision = try Contract.decode(
        TranscriptRevision.self, bytes: repositoryFixture("revision.json")
      ).value
      revision.revisionId = UUID().uuidString.lowercased()
      let speaker = UUID().uuidString.lowercased()
      revision.speakers = [revision.speakers[0]]
      revision.speakers[0].speakerId = speaker
      let template = revision.turns[0]
      revision.turns = (0..<4000).map { index in
        Turn(
          turnId: UUID().uuidString.lowercased(), trackId: template.trackId, speakerId: speaker,
          startMs: template.startMs, endMs: template.endMs,
          text: index == 0
            ? String(repeating: "retained evidence ", count: 160000) : "Turn \(index)", words: [])
      }
      let bytes = try Contract.encode(revision)
      byteCount += bytes.count
      let work = repositoryIntent(
        kind: .replica, payload: Data("replicate \(revision.revisionId)".utf8))
      _ = try await repository.importRevision(bytes, associatedWork: work)
      _ = try await repository.markRunning(work.operationID)
      _ = try await repository.markFailed(
        work.operationID, failure: .init(code: "offline", retry: .retryable))
      _ = try await repository.markRunning(work.operationID)
      try await repository.acknowledge(work.operationID)
      for _ in 0..<8 {
        let page = try await repository.turns(
          callID: repositoryCallID, revisionID: revision.revisionId, limit: 1)
        #expect(page.first?.text == revision.turns[0].text)
        #expect(page.first?.turnID == revision.turns[0].turnId)
        _ = try await repository.calls(limit: 128)
      }
      workload.imported()
      #expect(workload.captureCount > captureStart)
      print(
        "SQLITE_BACKGROUND completed_revision=\(workload.importCount) imported_bytes=\(byteCount) capture_start=\(captureStart) capture_end=\(workload.captureCount)"
      )
    }
    return byteCount
  }
  let capture = Task.detached(priority: .userInitiated) {
    if production { return try await productionSinkCapture(session: session, workload: workload) }
    let writer = try RecoverableMediaMaster(
      directory: session.mediaDirectory, identity: session.mediaMasterIdentity)
    var latency: [Double] = []
    var worstCycle = (elapsed: 0.0, phases: "")
    defer { print(worstCycle.phases) }
    while !workload.isComplete || latency.count < 120 {
      guard latency.count < 10800 else { throw RepositoryInjectedFailure() }
      let start = ContinuousClock.now
      // Worst source-state density accepted by #51: both channels change every millisecond.
      let ms = Int(writer.cursor.frames / 16)
      let microphone = (0..<1000).map {
        CaptureInterval(
          startMs: ms + $0, endMs: ms + $0 + 1, state: $0 % 2 == 0 ? .recorded : .muted)
      }
      let application = (0..<1000).map {
        CaptureInterval(
          startMs: ms + $0, endMs: ms + $0 + 1, state: $0 % 2 == 0 ? .recorded : .unavailable)
      }
      let samples = Array(repeating: Int16(123), count: 32000)
      let preparedAt = ContinuousClock.now
      let commit = try writer.append(
        interleaved: samples,
        microphoneIntervals: microphone, applicationIntervals: application)
      let mediaAt = ContinuousClock.now
      try repository.commitMediaProgress(commit)
      let sqlAt = ContinuousClock.now
      workload.captured()
      let completedAt = ContinuousClock.now
      let elapsed = elapsedSeconds(start.duration(to: completedAt))
      latency.append(elapsed)
      // One second of input plus all media/index sync and SQL service must fit two seconds.
      #expect(1 + elapsed <= 2)
      if elapsed > worstCycle.elapsed {
        worstCycle = (
          elapsed,
          "DENSE_WORST_CYCLE total_ms=\(elapsed * 1000) prepare_ms=\(milliseconds(start, preparedAt)) media_ms=\(milliseconds(preparedAt, mediaAt)) sql_ms=\(milliseconds(mediaAt, sqlAt)) post_sql_ms=\(milliseconds(sqlAt, completedAt))"
        )
      }
      try await waitForNextSourceSecond(after: start)
    }
    #expect(try repository.confirmedMediaCursor(callID: session.callID) == writer.cursor)
    return latency
  }
  let captureResult = await capture.result
  let backgroundResult = await background.result
  let latency = try captureResult.get()
  let bytes = try backgroundResult.get()
  #expect(workload.importCount == 3)
  #expect(try await repository.call(callID: repositoryCallID).revisions.count == 3)
  #expect(try await repository.lifecycle(callID: repositoryCallID)?.importState.state == .imported)
  let sorted = latency.sorted()
  print(
    "SQLITE_CONTENTION production_sink=\(production) commits=\(latency.count) intervals_per_commit=\(production ? 2 : 2000) source_cadence=wall_clock_1s minimum_commits=120 imported_revisions=3 imported_turns=12000 imported_bytes=\(bytes) oversized_turn_utf8=2880000 typed_large_reads=24 max_commit_ms=\(sorted.last! * 1000) p95_commit_ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000) max_input_plus_commit_ms=\(1000 + sorted.last! * 1000) journal=delete synchronous=extra fullfsync=on"
  )
}

@Test func repositoryLargeTextIsTypedAndEscapesItsStorageMarker() async throws {
  let root = repositoryRoot("large-text")
  defer { try? FileManager.default.removeItem(at: root) }
  let repository = try await seedRepositoryCall(root: root)
  // Mutable failure codes are also variable-size typed text, kept outside SQL cell bounds.
  let code = "failure_" + String(repeating: "x", count: 300000)
  let failure = try LifecycleFailure(code: code, retry: .retryable)
  _ = try await repository.updateLifecycle(callID: repositoryCallID) {
    $0.upload = .init(state: .failed, failure: failure)
  }
  #expect(try await repository.lifecycle(callID: repositoryCallID)?.upload.failure == failure)
  let operation = repositoryIntent(kind: .upload)
  _ = try await repository.recordIntent(operation)
  _ = try await repository.markFailed(operation.operationID, failure: failure)
  #expect(try await repository.operation(operation.operationID)?.lastFailure == failure)
  let newRoot = root.appendingPathComponent("source-fixture")
  var source = try repositorySession(newRoot)
  source = CaptureArchiveSession(
    root: source.root, archiveID: source.archiveID, callID: source.callID,
    microphoneTrackID: source.microphoneTrackID, applicationTrackID: source.applicationTrackID,
    audioManifestID: source.audioManifestID, masterID: source.masterID, startedAt: source.startedAt,
    source: .init(
      applicationName: "@trigo-text-v1:literal", bundleID: "fixture.sqlite", processID: 123,
      windowID: 456, windowTitle: String(repeating: "title", count: 100000),
      processLaunchDate: source.source.processLaunchDate),
    microphone: source.microphone)
  try await source.prepare()
  let sourceRepository = try LocalRepository(root: newRoot, archiveID: repositoryArchiveID)
  #expect(try await sourceRepository.captureSession(callID: source.callID) == source)
}

private final class RepositoryWorkload: @unchecked Sendable {
  private let lock = NSLock()
  private var completed = false
  private var count = 0
  private var captures = 0
  var isComplete: Bool { lock.withLock { completed } }
  var importCount: Int { lock.withLock { count } }
  var captureCount: Int { lock.withLock { captures } }
  func complete() { lock.withLock { completed = true } }
  func imported() { lock.withLock { count += 1 } }
  func captured() { lock.withLock { captures += 1 } }
}

private func elapsedSeconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func milliseconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double
{
  elapsedSeconds(from.duration(to: to)) * 1000
}

private func waitForNextSourceSecond(after start: ContinuousClock.Instant) async throws {
  // Imports and the finite three-hour capture now advance against the same clock.
  // Every cycle starts its own one-second period: slow service delays subsequent
  // input instead of triggering synthetic catch-up bursts. Service remains measured.
  try await ContinuousClock().sleep(until: start.advanced(by: .seconds(1)))
}

private func productionSinkCapture(session: CaptureArchiveSession, workload: RepositoryWorkload)
  async throws -> [Double]
{
  let queue = DispatchQueue(label: "trigo.test.contention-sink", qos: .userInteractive)
  let sink = try CaptureStreamSink(
    session: session, queue: queue, origin: .zero,
    microphone: session.microphone, onSnapshot: { _ in },
    onMicrophoneFailure: { _ in
      Issue.record("Unexpected microphone failure under completed background load")
    },
    onFailure: { reason in Issue.record("Unexpected production sink failure: \(reason)") })
  let (microphone, application) = await MainActor.run {
    (RecordingTransportFixture(), RecordingTransportFixture())
  }
  sink.acceptMicrophoneStream(microphone)
  sink.acceptApplicationStream(application)
  let repository = try LocalRepository(root: session.root, archiveID: session.archiveID)
  let input = try ProductionAudioBufferFactory()
  var latency: [Double] = []
  var worstCycle = (elapsed: 0.0, phases: "")
  var worstCaller = (elapsed: 0.0, phases: "")
  var maximumPostWitnessSeconds = 0.0
  defer {
    print(worstCycle.phases)
    print(worstCaller.phases)
    print(
      "PRODUCTION_OBSERVER max_input_plus_caller_ms=\(1000 + worstCaller.elapsed * 1000) max_post_witness_to_observer_ms=\(maximumPostWitnessSeconds * 1000)"
    )
  }
  while !workload.isComplete || latency.count < 120 {
    guard latency.count < 10800 else { throw RepositoryInjectedFailure() }
    let commit = try await productionCaptureCommit(
      sink: sink, repository: repository, session: session,
      microphoneID: ObjectIdentifier(microphone), applicationID: ObjectIdentifier(application),
      second: latency.count, input: input)
    // Keep the original post-delivery witness and observer work visible separately.
    #expect(try repository.confirmedMediaCursor(callID: session.callID) == commit.witness)
    workload.captured()
    let completedAt = ContinuousClock.now
    let elapsed = commit.durabilitySeconds
    latency.append(elapsed)
    // Includes construction, ingress, every pre-witness wait, media/index sync and SQL.
    #expect(1 + elapsed <= 2)
    if elapsed > worstCycle.elapsed {
      worstCycle = (elapsed, commit.phases(boundary: "durability", observedAt: completedAt))
    }
    let callerSeconds = elapsedSeconds(commit.startedAt.duration(to: completedAt))
    if callerSeconds > worstCaller.elapsed {
      worstCaller = (
        callerSeconds, commit.phases(boundary: "caller", observedAt: completedAt)
      )
    }
    maximumPostWitnessSeconds = max(
      maximumPostWitnessSeconds, elapsedSeconds(commit.witnessedAt.duration(to: completedAt)))
    try await waitForNextSourceSecond(after: commit.startedAt)
  }
  let result = try await sink.finish(
    at: CMTime(value: Int64(latency.count), timescale: 1), reason: nil)
  let complete = try await session.complete(media: result.0, interruptionReason: nil)
  #expect(complete.call.durationMs == latency.count * 1000)
  #expect(complete.call.captureState == .stopped)
  let spans = try repository.captureIntervals(callID: session.callID, through: result.0.cursor)
  #expect(
    spans.allSatisfy { $0 == [.init(startMs: 0, endMs: latency.count * 1000, state: .recorded)] })
  let statistics = sink.ingressStatistics
  #expect(!statistics.rejected && statistics.pendingBuffers == 0)
  #expect(statistics.maximumPendingSourceSeconds <= 1.000_001)
  #expect(1 + statistics.maximumServiceSeconds <= 2)
  print(
    "PRODUCTION_QUEUE commits=\(latency.count) max_pending_buffers=\(statistics.maximumPendingBuffers) max_pending_source_s=\(statistics.maximumPendingSourceSeconds) max_service_ms=\(statistics.maximumServiceSeconds * 1000) max_input_plus_service_ms=\(1000 + statistics.maximumServiceSeconds * 1000) source_coverage=complete background_imports=\(workload.importCount)"
  )
  return latency
}

/// The same production input/queue/witness boundary is used by the full background
/// workload and the delayed-observer regression below.
private struct ProductionCaptureCommit: Sendable {
  let startedAt: ContinuousClock.Instant
  let submittedAt: ContinuousClock.Instant
  let advanceQueuedAt: ContinuousClock.Instant
  let advanceStartedAt: ContinuousClock.Instant
  let witnessedAt: ContinuousClock.Instant
  let resumedAt: ContinuousClock.Instant
  let witness: MediaMasterCursor

  // A delayed observer cannot lose bytes already witnessed in committed SQL. Never
  // subtract earlier waits: the bound starts before construction of the first buffer.
  var durabilitySeconds: Double {
    elapsedSeconds(startedAt.duration(to: witnessedAt))
  }

  func phases(boundary: String, observedAt: ContinuousClock.Instant) -> String {
    "PRODUCTION_WORST_CYCLE boundary=\(boundary) durability_ms=\(milliseconds(startedAt, witnessedAt)) caller_ms=\(milliseconds(startedAt, observedAt)) submission_ms=\(milliseconds(startedAt, submittedAt)) drain_ms=\(milliseconds(submittedAt, advanceQueuedAt)) advance_queue_ms=\(milliseconds(advanceQueuedAt, advanceStartedAt)) advance_service_and_sql_witness_ms=\(milliseconds(advanceStartedAt, witnessedAt)) advance_delivery_ms=\(milliseconds(witnessedAt, resumedAt)) post_delivery_ms=\(milliseconds(resumedAt, observedAt))"
  }
}

/// SCStream supplies a ready format description with every callback. Build that
/// immutable producer metadata once; PCM/sample allocation and all first decoder
/// work still happen inside each measured capture cycle.
private struct ProductionAudioBufferFactory: @unchecked Sendable {
  let format: AVAudioFormat
  let description: CMAudioFormatDescription

  init() throws {
    let start = ContinuousClock.now
    format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
    var description: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault, asbd: format.streamDescription,
      layoutSize: 0, layout: nil, magicCookieSize: 0,
      magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
    try #require(status == noErr)
    self.description = try #require(description)
    print("PRODUCTION_INPUT_SETUP format_description_ms=\(milliseconds(start, .now))")
  }

  func sample(at time: CMTime) throws -> CMSampleBuffer {
    let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
    pcm.frameLength = 320
    for frame in 0..<320 { pcm.floatChannelData![0][frame] = 0.25 }
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 16_000),
      presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(
      CMSampleBufferCreateReady(
        allocator: kCFAllocatorDefault, dataBuffer: nil,
        formatDescription: description, sampleCount: 320, sampleTimingEntryCount: 1,
        sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
        sampleBufferOut: &sample) == noErr)
    let result = try #require(sample)
    #expect(
      CMSampleBufferSetDataBufferFromAudioBufferList(
        result, blockBufferAllocator: kCFAllocatorDefault,
        blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
        bufferList: pcm.audioBufferList) == noErr)
    return result
  }
}

private func productionCaptureCommit(
  sink: CaptureStreamSink, repository: LocalRepository, session: CaptureArchiveSession,
  microphoneID: ObjectIdentifier, applicationID: ObjectIdentifier, second: Int,
  input: ProductionAudioBufferFactory
) async throws -> ProductionCaptureCommit {
  let start = ContinuousClock.now
  for part in 0..<50 {
    let time = CMTime(value: Int64(second * 50 + part), timescale: 50)
    let sample = try input.sample(at: time)
    #expect(sink.enqueue(sample, role: .microphone, streamID: microphoneID, deliveredAt: time))
    #expect(sink.enqueue(sample, role: .application, streamID: applicationID, deliveredAt: time))
  }
  let submittedAt = ContinuousClock.now
  while sink.ingressStatistics.pendingBuffers > 0 {
    try await sink.perform { _ in }
  }
  let advanceQueuedAt = ContinuousClock.now
  let (advanceStartedAt, witness, witnessedAt) = try await sink.perform { engine in
    let began = ContinuousClock.now
    try engine.advance(at: CMTime(value: Int64((second + 1) * 4 + 1), timescale: 4))
    // Independent SQL publication witness, after synchronous media/index sync + COMMIT.
    // The timestamp follows the query and its validation, on the engine queue.
    let confirmed = try repository.confirmedMediaCursor(callID: session.callID)
    let witness = try #require(confirmed)
    try #require(witness.frames == Int64(second + 1) * 16_000)
    return (began, witness, ContinuousClock.now)
  }
  return .init(
    startedAt: start, submittedAt: submittedAt, advanceQueuedAt: advanceQueuedAt,
    advanceStartedAt: advanceStartedAt, witnessedAt: witnessedAt, resumedAt: .now,
    witness: witness)
}

@Test func productionDurabilityIsRecoverableWhileItsObserverIsDelayed() async throws {
  let root = repositoryRoot("delayed-observer")
  let recoveredRoot = root.appendingPathComponent("reopened-master")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let repository = try LocalRepository(root: root, archiveID: session.archiveID)
  let queue = DispatchQueue(label: "trigo.test.delayed-observer", qos: .userInteractive)
  let sink = try CaptureStreamSink(
    session: session, queue: queue, origin: .zero,
    microphone: session.microphone, onSnapshot: { _ in },
    onMicrophoneFailure: { _ in Issue.record("Unexpected microphone failure") },
    onFailure: { reason in Issue.record("Unexpected production sink failure: \(reason)") })
  let (microphone, application) = await MainActor.run {
    (RecordingTransportFixture(), RecordingTransportFixture())
  }
  sink.acceptMicrophoneStream(microphone)
  sink.acceptApplicationStream(application)
  let input = try ProductionAudioBufferFactory()

  // Hold publication of the first result to its observer. The capture queue stays
  // runnable; recovery and another real input/commit must finish before release.
  let producer = Task {
    let first = try await productionCaptureCommit(
      sink: sink, repository: repository, session: session,
      microphoneID: ObjectIdentifier(microphone), applicationID: ObjectIdentifier(application),
      second: 0, input: input)
    #expect(try repository.confirmedMediaCursor(callID: session.callID) == first.witness)
    try FileManager.default.copyItem(at: session.mediaDirectory, to: recoveredRoot)
    let reopened = try RecoverableMediaMaster(
      reopening: recoveredRoot, expectedIdentity: session.mediaMasterIdentity,
      confirmed: first.witness)
    #expect(reopened.cursor == first.witness)
    #expect(reopened.discardedTailBytes == 0)
    #expect(reopened.cursor.frames == 16_000)
    let stable = try reopened.readStableBytes(in: 0..<first.witness.stableBytes)
    let second = try await productionCaptureCommit(
      sink: sink, repository: repository, session: session,
      microphoneID: ObjectIdentifier(microphone), applicationID: ObjectIdentifier(application),
      second: 1, input: input)
    #expect(second.witness.frames == 32_000)
    #expect(second.witness.commitCount > first.witness.commitCount)
    let stillStable = try Data(
      contentsOf: session.mediaDirectory.appendingPathComponent("master.caf")
    )
    .prefix(stable.count)
    #expect(Data(stillStable) == stable)
    // This delay is strictly after the first SQL witness and verified queue progress.
    try await Task.sleep(for: .milliseconds(1100))
    return first
  }
  let first = try await producer.value
  let observedAt = ContinuousClock.now
  let callerSeconds = elapsedSeconds(first.startedAt.duration(to: observedAt))
  print(first.phases(boundary: "delayed-observer", observedAt: observedAt))
  #expect(1 + callerSeconds > 2)
  #expect(1 + first.durabilitySeconds <= 2)
  print(
    "PRODUCTION_DELAYED_OBSERVER durable_ms=\(milliseconds(first.startedAt, first.witnessedAt)) caller_ms=\(callerSeconds * 1000) post_witness_observer_ms=\(milliseconds(first.witnessedAt, observedAt)) recovered_frames=16000 progressed_frames=32000 stable_prefix=unchanged"
  )
  let result = try await sink.finish(at: CMTime(value: 2, timescale: 1), reason: nil)
  let complete = try await session.complete(media: result.0, interruptionReason: nil)
  #expect(complete.call.durationMs == 2000)
  let spans = try repository.captureIntervals(callID: session.callID, through: result.0.cursor)
  #expect(spans.allSatisfy { $0 == [.init(startMs: 0, endMs: 2000, state: .recorded)] })
}
