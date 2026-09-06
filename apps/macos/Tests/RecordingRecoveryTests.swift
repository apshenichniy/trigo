import Foundation
import Testing

@testable import TrigoNative

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
  #expect(FileManager.default.fileExists(atPath: pcm.path))
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
  #expect(fixture.coordinator.recoveryReport.failures.map(\.callID) == [session.callID])
  #expect(try Data(contentsOf: metadataURL) == bytes)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["capture-session.json"])
  await fixture.coordinator.shortcutPressed()
  #expect(fixture.os.frontmostReads == 0)
  #expect(!fixture.os.application.running)
}
