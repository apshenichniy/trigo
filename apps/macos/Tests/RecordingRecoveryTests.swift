import Foundation
import Testing

@testable import TrigoNative

@Test @MainActor func connectionMetadataRecoveryDoesNotOfferAnEnabledNoOpLocalRecovery()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  await fixture.metadata.setLoadFailure(true)
  await fixture.coordinator.restore()
  #expect(fixture.coordinator.phase == .recoveryRequired)
  #expect(fixture.coordinator.connectionRecoveryIssue == .persistence)
  #expect(!fixture.coordinator.canRetryLocalRecovery)
  #expect(!fixture.coordinator.canStart)
}

@Test @MainActor func launchRecoveryPreservesKnownCauseAndNextLaunchStaysIdle() async throws {
  struct Crash: Error {}
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let session = try await CaptureArchiveSession.begin(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID, source: fixture.os.source, microphone: nil)
  await #expect(throws: Crash.self) {
    try await session.finish(
      media: .init(objects: [], durationMs: 0), interruptionReason: "system_sleep"
    ) { point in
      if point == .afterAudioManifest { throw Crash() }
    }
  }
  await fixture.bind()
  let recovered = try #require(fixture.coordinator.recoveryReport.recoveredCalls.first)
  #expect(recovered.interruptionReason == "system_sleep")
  #expect(recovered.explanation.contains("System sleep"))
  let archive = try LocalArchive(
    root: fixture.namespace.archive, archiveID: fixture.status.archiveID)
  let before = try await archive.loadCall(callID: session.callID)
  let fresh = RecordingCoordinator(
    connection: fixture.connection, namespace: fixture.namespace,
    capture: fixture.capture,
    sources: .init(
      permissions: { fixture.os.permissions },
      frontmost: fixture.os.frontmost, requestPermissions: { fixture.os.permissions }))
  await fresh.restore()
  #expect(fresh.recoveryReport.recoveredCallIDs.isEmpty)
  #expect(fresh.recoveryReport.warnings.isEmpty)
  #expect(fresh.phase == .idle)
  #expect(!fresh.canRetryLocalRecovery)
  let after = try await archive.loadCall(callID: session.callID)
  #expect(before.manifest.storedBytes == after.manifest.storedBytes)
}

@Test @MainActor func launchRecoveryDoesNotDiscoverNestedCallDirectories() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let root = fixture.namespace.archive.appendingPathComponent("unrelated")
  let session = try await CaptureArchiveSession.begin(
    root: root,
    archiveID: fixture.status.archiveID, source: fixture.os.source, microphone: nil)
  await fixture.bind()
  #expect(fixture.coordinator.recoveryReport.recoveredCalls.isEmpty)
  #expect(fixture.coordinator.recoveryReport.failures.isEmpty)
  let archive = try LocalArchive(root: root, archiveID: fixture.status.archiveID)
  let call = try await archive.loadCall(callID: session.callID)
  #expect(try jsonObject(call.manifest.storedBytes)["captureState"] as? String == "recording")
}

@Test @MainActor func launchRecoveryReportsCorruptMediaTailInsteadOfClaimingCompleteRecovery()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let session = try await CaptureArchiveSession.begin(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID, source: fixture.os.source, microphone: nil)
  let writer = try CaptureMediaWriter(directory: session.mediaDirectory)
  try writer.append(interleaved: Array(repeating: Int16(123), count: 64_000))
  let media = try FileManager.default.contentsOfDirectory(
    at: session.mediaDirectory, includingPropertiesForKeys: nil)
  let pcm = try #require(media.first { $0.pathExtension == "pcm" })
  let file = try FileHandle(forWritingTo: pcm)
  try file.seek(toOffset: 64_000)
  try file.write(contentsOf: Data([0xff]))
  try file.close()
  await fixture.bind()
  #expect(fixture.coordinator.recoveryReport.warnings.map(\.callID) == [session.callID])
  #expect(fixture.coordinator.phase == .interrupted)
  #expect(!fixture.coordinator.canRetryLocalRecovery)
  #expect(FileManager.default.fileExists(atPath: pcm.path))
  await fixture.coordinator.retryRecovery()
  #expect(fixture.coordinator.recoveryReport.warnings.isEmpty)
  #expect(fixture.coordinator.recoveryReport.recoveredCallIDs.isEmpty)
  #expect(fixture.coordinator.phase == .idle)
}

@Test @MainActor func launchRecoveryFinalizesOnlyBoundDirectCallsAndIsIdempotent() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let session = try await CaptureArchiveSession.begin(
    root: fixture.namespace.archive, archiveID: fixture.status.archiveID,
    source: fixture.os.source, microphone: nil)
  await fixture.bind()
  #expect(fixture.coordinator.recoveryReport.recoveredCallIDs == [session.callID])
  #expect(fixture.coordinator.phase == .interrupted)
  #expect(!fixture.os.application.running)
  let archive = try LocalArchive(root: fixture.namespace.archive, archiveID: session.archiveID)
  let first = try await archive.loadCall(callID: session.callID)
  await fixture.coordinator.retryRecovery()
  let second = try await archive.loadCall(callID: session.callID)
  #expect(first.manifest.storedBytes == second.manifest.storedBytes)
  #expect(fixture.coordinator.recoveryReport.recoveredCallIDs.isEmpty)
  #expect(fixture.coordinator.recoveryReport.warnings.isEmpty)
  #expect(fixture.coordinator.phase == .idle)
}

@Test(arguments: ["archive", "root", "call", "corrupt", "symlink"])
@MainActor func launchRecoveryRejectsForeignOrCorruptMetadataWithoutMutation(kind: String)
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let session = try CaptureArchiveSession.allocate(
    root: fixture.namespace.archive, archiveID: fixture.status.archiveID,
    source: fixture.os.source, microphone: nil)
  let directory = fixture.namespace.archive.appendingPathComponent(session.callID)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let metadataURL = directory.appendingPathComponent("capture-session.json")
  var object = try jsonObject(JSONEncoder().encode(session))
  if kind == "archive" { object["archiveID"] = "00000000-0000-4000-8000-000000000099" }
  if kind == "root" {
    object["root"] = fixture.support.appendingPathComponent("foreign").absoluteString
  }
  if kind == "call" { object["callID"] = "00000000-0000-4000-8000-000000000098" }
  let bytes =
    kind == "corrupt" ? Data("broken".utf8) : try JSONSerialization.data(withJSONObject: object)
  if kind == "symlink" {
    let foreign = fixture.support.appendingPathComponent("foreign-session.json")
    try bytes.write(to: foreign)
    try FileManager.default.createSymbolicLink(at: metadataURL, withDestinationURL: foreign)
  } else {
    try bytes.write(to: metadataURL)
  }
  await fixture.bind()
  #expect(fixture.coordinator.phase == .recoveryRequired)
  #expect(fixture.coordinator.canRetryLocalRecovery)
  #expect(fixture.coordinator.recoveryReport.failures.map(\.callID) == [session.callID])
  #expect(try Data(contentsOf: metadataURL) == bytes)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["capture-session.json"])
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.os.frontmostReads == 0)
  #expect(!fixture.os.application.running)
}
