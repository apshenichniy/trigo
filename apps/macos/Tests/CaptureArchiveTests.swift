import CoreMedia
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func interruptedCapturePublishesActualDurationAndCanonicalChannelReferences() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-capture-archive-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let archiveID = UUID().uuidString.lowercased()
  let source = CaptureSource(
    applicationName: "Fixture", bundleID: "test.fixture", processID: 123,
    windowID: 456, windowTitle: nil, processLaunchDate: Date())
  let session = try await CaptureArchiveSession.begin(
    root: root, archiveID: archiveID, source: source,
    microphone: .init(id: "fixture-mic", name: "Fixture microphone"))
  let archive = try LocalRepository(root: root, archiveID: archiveID)
  let initial = try await archive.loadCall(callID: session.callID)
  #expect(initial.manifest.value.captureState == "recording")
  let writer = try CaptureMediaWriter(session: session)
  try writer.append(interleaved: Array(repeating: Int16(123), count: 32_000))
  try writer.append(interleaved: Array(repeating: Int16(123), count: 32_000))
  let recovered = try await CaptureArchiveSession.recover(
    root: root, archiveID: session.archiveID, callID: session.callID)
  #expect(recovered.manifest.value.captureState == "interrupted")
  #expect(recovered.manifest.value.durationMs == 2_000)
  #expect(recovered.manifest.value.interruptionReason == "process_terminated")
  let media = try Contract.validate("AudioManifest", bytes: #require(recovered.audioManifest))
  #expect(media.value.object?["objects"]?.array?.count == 1)
  let object = try #require(media.value.object?["objects"]?.array?.first)
  let channels = try #require(object.object?["channelMap"]?.array)
  #expect(channels.first?.object?["trackId"]?.string == session.microphoneTrackID)
  let repeated = try await CaptureArchiveSession.recover(
    root: root, archiveID: session.archiveID, callID: session.callID)
  #expect(repeated.manifest.storedBytes == recovered.manifest.storedBytes)
  let lifecycle = try LocalRepository(root: root, archiveID: archiveID)
  #expect(try await lifecycle.lifecycle(callID: session.callID)?.capture.state == .interrupted)
}

@Test func crashBetweenMediaSealAndCanonicalPublicationKeepsInterruptionReason() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("trigo-seal-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let source = CaptureSource(
    applicationName: "Fixture", bundleID: "test.fixture", processID: 123,
    windowID: 456, windowTitle: nil, processLaunchDate: Date())
  let session = try await CaptureArchiveSession.begin(
    root: root, archiveID: UUID().uuidString.lowercased(),
    source: source, microphone: nil)
  let engine = try CaptureRecordingEngine(
    writer: CaptureMediaWriter(session: session), origin: .zero, microphone: nil)
  _ = try engine.stop(at: CMTime(seconds: 0.1, preferredTimescale: 16_000), reason: "system_sleep")
  let recovered = try await CaptureArchiveSession.recover(
    root: root, archiveID: session.archiveID, callID: session.callID)
  #expect(recovered.manifest.value.captureState == "interrupted")
  #expect(recovered.manifest.value.interruptionReason == "system_sleep")
}

@Test func recoveryBeforeJointPublicationReusesTheSameFinalization() async throws {
  struct Crash: Error {}
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-finalize-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let source = CaptureSource(
    applicationName: "Fixture", bundleID: "test.fixture", processID: 123,
    windowID: 456, windowTitle: nil, processLaunchDate: Date())
  let session = try await CaptureArchiveSession.begin(
    root: root, archiveID: UUID().uuidString.lowercased(),
    source: source, microphone: nil)
  let writer = try CaptureMediaWriter(session: session)
  try writer.append(interleaved: Array(repeating: 123, count: 3_200))
  let firstRecovery = try CaptureMediaWriter.recover(session: session)
  let firstMaster = try finishCapture(firstRecovery, reason: "process_terminated")
  await #expect(throws: Crash.self) {
    try await session.finish(media: firstMaster, interruptionReason: "process_terminated") {
      point in
      if point == .beforeCommit { throw Crash() }
    }
  }
  let recovered = try await CaptureArchiveSession.recover(
    root: root, archiveID: session.archiveID, callID: session.callID)
  let audio = try jsonObject(#require(recovered.audioManifest))
  let objects = try #require(audio["objects"] as? [[String: Any]])
  #expect(objects.first?["objectId"] as? String == session.masterID)
}

@Test func durableSessionWithoutAnOpenedWriterRecoversAsZeroDurationInterrupted() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-partial-start-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let source = CaptureSource(
    applicationName: "Fixture", bundleID: "test.fixture", processID: 123,
    windowID: 456, windowTitle: nil, processLaunchDate: Date())
  let session = try await CaptureArchiveSession.begin(
    root: root, archiveID: UUID().uuidString.lowercased(),
    source: source, microphone: nil)
  // A filesystem failure between durable session creation and stream/writer setup.
  try Data().write(to: session.mediaDirectory)
  #expect(throws: (any Error).self) {
    try CaptureRecordingEngine(
      writer: CaptureMediaWriter(session: session), origin: .zero, microphone: nil)
  }
  let recovered = try await CaptureArchiveSession.recover(
    root: root, archiveID: session.archiveID, callID: session.callID)
  #expect(recovered.manifest.value.durationMs == 0)
  #expect(recovered.manifest.value.captureState == "interrupted")
}

@Test(arguments: [
  CapturePreparationPoint.beforeCommit, .afterCommit,
])
func partiallyPreparedCaptureRecoversWithItsAllocatedIdentity(_ boundary: CapturePreparationPoint)
  async throws
{
  struct Crash: Error {}
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-preparation-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try CaptureArchiveSession.allocate(
    root: root, archiveID: UUID().uuidString.lowercased(),
    source: CaptureSource(
      applicationName: "Fixture", bundleID: "test.fixture", processID: 123,
      windowID: 456, windowTitle: nil, processLaunchDate: Date()), microphone: nil)
  await #expect(throws: Crash.self) {
    try await session.prepare { if $0 == boundary { throw Crash() } }
  }
  // Before commit no identity is published; the caller retries its retained allocation.
  // After commit a fresh process can discover the same durable session.
  let recovered =
    boundary == .beforeCommit
    ? try await session.recover()
    : try await CaptureArchiveSession.recover(
      root: root, archiveID: session.archiveID, callID: session.callID)
  #expect(recovered.manifest.value.callId == session.callID)
  #expect(recovered.manifest.value.durationMs == 0)
  #expect(recovered.manifest.value.captureState == "interrupted")
  let lifecycle = try LocalRepository(root: root, archiveID: session.archiveID)
  #expect(try await lifecycle.lifecycle(callID: session.callID)?.capture.state == .interrupted)
  let repeated = try await session.recover()
  #expect(repeated.manifest.storedBytes == recovered.manifest.storedBytes)
}

@Test func failedFirstPreparationWriteReturnsItsRecoverableIdentity() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-first-write-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  try Data().write(to: root)
  do {
    _ = try await CaptureArchiveSession.begin(
      root: root, archiveID: UUID().uuidString.lowercased(),
      source: CaptureSource(
        applicationName: "Fixture", bundleID: "test.fixture", processID: 123,
        windowID: 456, windowTitle: nil, processLaunchDate: Date()), microphone: nil)
    Issue.record("Expected a filesystem preparation failure")
  } catch let failure as CapturePreparationFailure {
    try FileManager.default.removeItem(at: root)
    let recovered = try await failure.session.recover()
    #expect(recovered.manifest.value.callId == failure.session.callID)
    #expect(recovered.manifest.value.durationMs == 0)
    #expect(recovered.manifest.value.captureState == "interrupted")
  }
}
