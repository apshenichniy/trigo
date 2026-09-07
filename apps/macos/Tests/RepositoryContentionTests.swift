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
      let commit = try writer.append(
        interleaved: Array(repeating: 123, count: 32000),
        microphoneIntervals: microphone, applicationIntervals: application)
      try repository.commitMediaProgress(commit)
      workload.captured()
      let elapsed = elapsedSeconds(start.duration(to: .now))
      latency.append(elapsed)
      // One second of input plus all media/index sync and SQL service must fit two seconds.
      #expect(1 + elapsed <= 2)
      // Advance one second of generated input every 20 ms (50x real time), leaving
      // an idle input gap in which background work can make progress. A continuous
      // unpaced foreground loop would model an overloaded producer, not capture.
      try await Task.sleep(for: .milliseconds(20))
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
    "SQLITE_CONTENTION production_sink=\(production) commits=\(latency.count) intervals_per_commit=\(production ? 2 : 2000) imported_revisions=3 imported_turns=12000 imported_bytes=\(bytes) oversized_turn_utf8=2880000 typed_large_reads=24 max_commit_ms=\(sorted.last! * 1000) p95_commit_ms=\(sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000) max_input_plus_commit_ms=\(1000 + sorted.last! * 1000) journal=delete synchronous=extra fullfsync=on"
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
  var latency: [Double] = []
  while !workload.isComplete || latency.count < 120 {
    guard latency.count < 10800 else { throw RepositoryInjectedFailure() }
    let start = ContinuousClock.now
    let second = latency.count
    for part in 0..<50 {
      let time = CMTime(value: Int64(second * 50 + part), timescale: 50)
      let sample = try controlledAudioBuffer(
        sampleRate: 16_000, frames: 320, time: time, value: 0.25)
      #expect(
        sink.enqueue(
          sample, role: .microphone, streamID: ObjectIdentifier(microphone), deliveredAt: time))
      #expect(
        sink.enqueue(
          sample, role: .application, streamID: ObjectIdentifier(application), deliveredAt: time))
    }
    while sink.ingressStatistics.pendingBuffers > 0 {
      try await sink.perform { _ in }
    }
    try await sink.perform { engine in
      try engine.advance(at: CMTime(value: Int64((second + 1) * 4 + 1), timescale: 4))
    }
    #expect(
      try repository.confirmedMediaCursor(callID: session.callID)?.frames == Int64(second + 1)
        * 16_000)
    workload.captured()
    let elapsed = elapsedSeconds(start.duration(to: .now))
    latency.append(elapsed)
    #expect(1 + elapsed <= 2)
    try await Task.sleep(for: .milliseconds(20))
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
