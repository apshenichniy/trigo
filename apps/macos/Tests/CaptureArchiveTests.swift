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
  let archive = try LocalArchive(root: root, archiveID: archiveID)
  let initial = try await archive.loadCall(callID: session.callID)
  #expect(initial.manifest.value.object?["captureState"]?.string == "recording")
  let writer = try CaptureMediaWriter(directory: session.mediaDirectory)
  try writer.append(interleaved: Array(repeating: Int16(123), count: 64_000))
  let recovered = try await CaptureArchiveSession.recover(root: root, callID: session.callID)
  #expect(recovered.manifest.value.object?["captureState"]?.string == "interrupted")
  #expect(recovered.manifest.value.object?["durationMs"]?.integer == 2_000)
  #expect(recovered.manifest.value.object?["interruptionReason"]?.string == "process_terminated")
  let media = try Contract.validate("AudioManifest", bytes: #require(recovered.audioManifest))
  #expect(media.value.object?["objects"]?.array?.count == 1)
  let object = try #require(media.value.object?["objects"]?.array?.first)
  let channels = try #require(object.object?["channelMap"]?.array)
  #expect(channels.first?.object?["trackId"]?.string == session.microphoneTrackID)
  let repeated = try await CaptureArchiveSession.recover(root: root, callID: session.callID)
  #expect(repeated.manifest.storedBytes == recovered.manifest.storedBytes)
  let lifecycle = try LocalLifecycleStore(root: root, archiveID: archiveID)
  #expect(try await lifecycle.load(callID: session.callID)?.capture.state == .interrupted)
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
    directory: session.mediaDirectory, origin: .zero, microphone: nil)
  _ = try engine.stop(at: CMTime(seconds: 0.1, preferredTimescale: 16_000), reason: "system_sleep")
  let recovered = try await CaptureArchiveSession.recover(root: root, callID: session.callID)
  #expect(recovered.manifest.value.object?["captureState"]?.string == "interrupted")
  #expect(recovered.manifest.value.object?["interruptionReason"]?.string == "system_sleep")
}

@Test func recoveryAfterImmutableAudioPublicationReusesTheSameFinalization() async throws {
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
  let writer = try CaptureMediaWriter(directory: session.mediaDirectory)
  try writer.append(interleaved: Array(repeating: 123, count: 3_200))
  let firstRecovery = try CaptureMediaWriter.recover(directory: session.mediaDirectory)
  await #expect(throws: Crash.self) {
    try await session.finish(media: firstRecovery.media, interruptionReason: "process_terminated") {
      point in
      if point == .afterAudioManifest { throw Crash() }
    }
  }
  let recovered = try await CaptureArchiveSession.recover(root: root, callID: session.callID)
  let audio = try jsonObject(#require(recovered.audioManifest))
  let objects = try #require(audio["objects"] as? [[String: Any]])
  #expect(objects.first?["objectId"] as? String == firstRecovery.media.objects.first?.objectID)
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
    try CaptureRecordingEngine(directory: session.mediaDirectory, origin: .zero, microphone: nil)
  }
  let recovered = try await CaptureArchiveSession.recover(root: root, callID: session.callID)
  #expect(recovered.manifest.value.object?["durationMs"]?.integer == 0)
  #expect(recovered.manifest.value.object?["captureState"]?.string == "interrupted")
}

@Test(arguments: [
  CapturePreparationPoint.afterSessionMetadata, .afterCallManifest, .afterLifecycle,
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
  // A relaunch has only the session metadata, not the caller's in-memory handle.
  let recovered = try await CaptureArchiveSession.recover(root: root, callID: session.callID)
  #expect(recovered.manifest.value.object?["callId"]?.string == session.callID)
  #expect(recovered.manifest.value.object?["durationMs"]?.integer == 0)
  #expect(recovered.manifest.value.object?["captureState"]?.string == "interrupted")
  let lifecycle = try LocalLifecycleStore(root: root, archiveID: session.archiveID)
  #expect(try await lifecycle.load(callID: session.callID)?.capture.state == .interrupted)
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
    #expect(recovered.manifest.value.object?["callId"]?.string == failure.session.callID)
    #expect(recovered.manifest.value.object?["durationMs"]?.integer == 0)
    #expect(recovered.manifest.value.object?["captureState"]?.string == "interrupted")
  }
}
