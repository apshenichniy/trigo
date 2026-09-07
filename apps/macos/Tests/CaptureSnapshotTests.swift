import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func captureStreamingSnapshotMatchesGeneratedEncodingAndPublicValidation() async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try await CaptureArchiveSession.begin(
    root: root,
    archiveID: UUID().uuidString.lowercased(),
    source: .init(
      applicationName: "Réunion / \"会議\"",
      bundleID: "test.snapshot",
      processID: 123,
      windowID: 456,
      windowTitle: "A\nB\\C",
      processLaunchDate: Date()
    ),
    microphone: .init(id: "mic/é", name: "\"Microphone\"")
  )
  let writer = try CaptureMediaWriter(session: session)
  let timeline = CaptureTimeline(writer: writer)
  try timeline.append(
    role: .microphone,
    startFrame: 0,
    samples: Array(repeating: Int16(5000), count: 32_000)
  )
  try timeline.setMicrophoneEnabled(false, atMs: 500)
  try timeline.setMicrophoneEnabled(true, atMs: 1500)
  try timeline.append(
    role: .application,
    startFrame: 8000,
    samples: Array(repeating: Int16(-2500), count: 24_000)
  )
  try timeline.flush(throughMs: 2000)
  let master = try finishCapture(writer, reason: "system_sleep")
  let completion = try await session.complete(media: master, interruptionReason: "system_sleep")
  let repository = try LocalRepository(root: root, archiveID: session.archiveID)
  var bytes = Data()
  try repository.forEachSnapshotChunk(callID: session.callID, version: 2) { bytes.append($0) }
  let value = try Contract.decode(CallDocument.self, bytes: bytes)
  let audio = try Contract.decode(AudioManifest.self, bytes: session.audioBytes(master))
  let expected = try session.callBytes(
    media: master,
    reason: "system_sleep",
    version: 2,
    finalized: true,
    microphoneIntervals: captureIntervals(writer, role: .microphone),
    applicationIntervals: captureIntervals(writer, role: .application),
    reference: .init(manifestId: session.audioManifestID, sha256: audio.sha256)
  )
  #expect(bytes == expected)
  #expect(value.sha256 == completion.snapshotSHA256)
  #expect(bytes.count == completion.snapshotByteLength)
  _ = try Contract.validateArchive(bytes, references: [session.audioManifestID: audio.storedBytes])
  #expect(try await session.recoverCompletion() == completion)
  #expect(try await repository.loadCall(callID: session.callID).manifest.storedBytes == bytes)
}

@Test func streamingSnapshotIncludesEveryGeneratedFieldAndNullableValue() throws {
  var call = try Contract.decode(CallDocument.self, bytes: repositoryFixture("call.json")).value
  call.source.windowTitle = "é / \"quoted\"\nline"
  call.speakerNames = [
    "00000000-0000-4000-8000-000000000006": ["00000000-0000-4000-8000-000000000007": "Éva / 周"]
  ]
  let snapshot = try CaptureSnapshotStream()
  try snapshot.encode(call) { index, consume in
    for span in call.tracks[index].intervals { try consume(span) }
  }
  #expect(try snapshot.finish() == Contract.hash(Contract.encode(call)))
  #expect(try Data(contentsOf: snapshot.url) == Contract.encode(call))
}
