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
    archiveID: fixture.status.archiveID,
    source: fixture.os.source,
    microphone: nil
  )
  await #expect(throws: Crash.self) {
    try await session.finish(
      media: nil,
      interruptionReason: "system_sleep"
    ) { point in
      if point == .beforeCommit { throw Crash() }
    }
  }
  await fixture.bind()
  let recovered = try #require(fixture.coordinator.recoveryReport.recoveredCalls.first)
  #expect(recovered.interruptionReason == "system_sleep")
  #expect(recovered.explanation.contains("System sleep"))
  let archive = try LocalRepository(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID
  )
  let before = try await archive.loadCall(callID: session.callID)
  let fresh = RecordingCoordinator(
    connection: fixture.connection,
    namespace: fixture.namespace,
    capture: fixture.capture,
    sources: .init(
      permissions: { fixture.os.permissions },
      frontmost: fixture.os.frontmost,
      requestPermission: { _ in fixture.os.permissions }
    )
  )
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
    archiveID: fixture.status.archiveID,
    source: fixture.os.source,
    microphone: nil
  )
  await fixture.bind()
  #expect(fixture.coordinator.recoveryReport.recoveredCalls.isEmpty)
  #expect(fixture.coordinator.recoveryReport.failures.map(\.callID) == ["archive"])
  let archive = try LocalRepository(root: root, archiveID: fixture.status.archiveID)
  let call = try await archive.loadCall(callID: session.callID)
  #expect(try jsonObject(call.manifest.storedBytes)["captureState"] as? String == "recording")
}

@Test @MainActor func launchRecoveryRejectsCommittedCorruptionWithoutChangingEvidence()
  async throws
{
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let session = try await CaptureArchiveSession.begin(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID,
    source: fixture.os.source,
    microphone: nil
  )
  let writer = try CaptureMediaWriter(session: session)
  try writer.append(interleaved: Array(repeating: Int16(123), count: 32_000))
  let file = try FileHandle(forWritingTo: writer.master.mediaURL)
  try file.seek(toOffset: 68)
  try file.write(contentsOf: Data([0xff]))
  try file.close()
  let damagedBytes = try Data(contentsOf: writer.master.mediaURL)
  await fixture.bind()
  #expect(fixture.coordinator.recoveryReport.failures.map(\.callID) == [session.callID])
  #expect(fixture.coordinator.recoveryReport.recoveredCalls.isEmpty)
  #expect(fixture.coordinator.phase == .recoveryRequired)
  #expect(fixture.coordinator.canRetryLocalRecovery)
  #expect(try Data(contentsOf: writer.master.mediaURL) == damagedBytes)
  await fixture.coordinator.retryRecovery()
  #expect(fixture.coordinator.recoveryReport.failures.map(\.callID) == [session.callID])
  #expect(try Data(contentsOf: writer.master.mediaURL) == damagedBytes)
}

@Test @MainActor func launchRecoveryFinalizesOnlyBoundDirectCallsAndIsIdempotent() async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let session = try await CaptureArchiveSession.begin(
    root: fixture.namespace.archive,
    archiveID: fixture.status.archiveID,
    source: fixture.os.source,
    microphone: nil
  )
  await fixture.bind()
  #expect(fixture.coordinator.recoveryReport.recoveredCallIDs == [session.callID])
  #expect(fixture.coordinator.phase == .interrupted)
  #expect(!fixture.os.application.running)
  let archive = try LocalRepository(root: fixture.namespace.archive, archiveID: session.archiveID)
  let first = try await archive.loadCall(callID: session.callID)
  await fixture.coordinator.retryRecovery()
  let second = try await archive.loadCall(callID: session.callID)
  #expect(first.manifest.storedBytes == second.manifest.storedBytes)
  #expect(fixture.coordinator.recoveryReport.recoveredCallIDs.isEmpty)
  #expect(fixture.coordinator.recoveryReport.warnings.isEmpty)
  #expect(fixture.coordinator.phase == .idle)
}

@Test(arguments: ["legacy", "corrupt", "symlink"])
@MainActor func launchRecoveryRejectsUnsupportedStoresWithoutMutation(kind: String) async throws {
  let fixture = try RecordingControlFixture()
  defer { fixture.cleanup() }
  let root = fixture.namespace.archive
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let artifact = root.appendingPathComponent(
    kind == "legacy" ? "capture-session.json" : SQLiteDatabase.filename
  )
  let bytes = Data("unfamiliar retained evidence".utf8)
  if kind == "symlink" {
    let foreign = fixture.support.appendingPathComponent("foreign.sqlite3")
    try bytes.write(to: foreign)
    try FileManager.default.createSymbolicLink(at: artifact, withDestinationURL: foreign)
  } else {
    try bytes.write(to: artifact)
  }
  await fixture.bind()
  #expect(fixture.coordinator.phase == .recoveryRequired)
  #expect(fixture.coordinator.canRetryLocalRecovery)
  #expect(fixture.coordinator.recoveryReport.failures.map(\.callID) == ["archive"])
  #expect(try Data(contentsOf: artifact) == bytes)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: root.path) == [artifact.lastPathComponent]
  )
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.os.frontmostReads == 0)
  #expect(!fixture.os.application.running)
}
