import CoreMedia
import Darwin
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

private final class ProductionFinalizationBundle: NSObject {}
private let finalizationArchive = "00000000-0000-4000-8000-000000000353"
private let finalizationOperation = "00000000-0000-4000-8000-000000000354"

@Test(.enabled(if: ProcessInfo.processInfo.environment["TRIGO_FINAL_MASTER_ROOT"] != nil))
func productionFinalMasterKillChild() async throws {
  let environment = ProcessInfo.processInfo.environment
  let root = URL(fileURLWithPath: try #require(environment["TRIGO_FINAL_MASTER_ROOT"]))
  let pointName = try #require(environment["TRIGO_FINAL_MASTER_POINT"])
  let point = try #require(MediaMasterIOPoint(rawValue: pointName))
  let reason = environment["TRIGO_FINAL_MASTER_REASON"] == "clean" ? nil : "system_sleep"
  let session = try repositorySession(root, archiveID: finalizationArchive)
  try await session.prepare()
  let writer = try CaptureMediaWriter(
    session: session,
    io: .init(event: { observed in
      if observed == point {
        _ = Darwin.kill(Darwin.getpid(), SIGKILL)
        while true { Darwin.pause() }
      }
    }))
  let engine = try CaptureRecordingEngine(
    writer: writer, origin: .zero, microphone: session.microphone)
  for part in 0..<30 {
    let time = CMTime(value: Int64(part), timescale: 10)
    for role: MediaSourceRole in [.microphone, .application] {
      try engine.receive(
        controlledAudioBuffer(sampleRate: 16_000, frames: 1600, time: time, value: 0.25), role: role
      )
    }
    if part % 5 == 4 { try engine.advance(at: CMTime(value: Int64(part + 1), timescale: 10)) }
  }
  let repository = try LocalRepository(root: root, archiveID: finalizationArchive)
  let work = OperationIntent(
    operationID: finalizationOperation, archiveID: finalizationArchive,
    callID: session.callID, kind: .upload, payload: Data("complete master required".utf8))
  try await repository.prepareCaptureFinalization(
    callID: session.callID, reason: reason, associatedWork: work)
  #expect(try await repository.operation(finalizationOperation) == nil)
  _ = try engine.stop(at: CMTime(value: 3, timescale: 1), reason: reason)
  Issue.record("Must terminate at the actual external final-index synchronization boundary")
}

@Test(arguments: ["beforeFinalizationSync", "afterFinalizationSync"], ["clean", "system_sleep"])
func productionFinalIndexSIGKILLRetainsMasterStopCauseAndPreparedWork(point: String, reason: String)
  async throws
{
  let root = repositoryRoot("final-master")
  defer { try? FileManager.default.removeItem(at: root) }
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  let bundle = try #require(Bundle(for: ProductionFinalizationBundle.self).executableURL?.path)
  let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().path
  child.arguments = [
    "--test-bundle-path", bundle, "--package-path", package,
    "--filter", "productionFinalMasterKillChild", bundle, "--testing-library", "swift-testing",
  ]
  child.environment = ProcessInfo.processInfo.environment.merging(
    [
      "TRIGO_FINAL_MASTER_ROOT": root.path, "TRIGO_FINAL_MASTER_POINT": point,
      "TRIGO_FINAL_MASTER_REASON": reason,
    ], uniquingKeysWith: { _, value in value })
  child.standardOutput = FileHandle.nullDevice
  child.standardError = FileHandle.nullDevice
  try child.run()
  child.waitUntilExit()
  #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
  let repository = try LocalRepository(root: root, archiveID: finalizationArchive)
  let call = try #require(try await repository.calls().first)
  let session = try #require(try await repository.captureSession(callID: call.callID))
  #expect(call.captureState == .recording)
  #expect(try await repository.operation(finalizationOperation) == nil)
  let hash = try masterFileHash(session.mediaDirectory.appendingPathComponent("master.caf"))
  let completed = try await session.recoverCompletion()
  #expect(completed.call.durationMs == 3000)
  #expect(completed.call.interruptionReason == (reason == "clean" ? nil : reason))
  #expect(completed.master?.cursor.identity == session.mediaMasterIdentity)
  #expect(completed.master?.sha256 == hash)
  #expect(
    try await repository.operation(finalizationOperation)?.payload
      == Data("complete master required".utf8))
  #expect(try await session.recoverCompletion() == completed)
  print(
    "PRODUCTION_FINAL_SIGKILL point=\(point) reason=\(reason) duration_ms=3000 master_sha256=\(hash) stable_identity=true prepared_work_recovered=true"
  )
}

@Test(arguments: [
  PersistenceInterruptionPoint.afterRepositoryStaging, .beforeRepositoryCommit,
  .afterRepositoryCommit,
])
func productionStreamingPublicationRecoversExactBytesAndWork(point: PersistenceInterruptionPoint)
  async throws
{
  let root = repositoryRoot("stream-publication")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let repository = try LocalRepository(root: root, archiveID: session.archiveID)
  let original = try await repository.snapshotBytes(callID: session.callID, version: 1)
  let writer = try CaptureMediaWriter(session: session)
  let timeline = CaptureTimeline(writer: writer)
  try timeline.append(
    role: .application, startFrame: 0, samples: Array(repeating: Int16(500), count: 16_000))
  try timeline.flush(throughMs: 1000)
  let work = repositoryIntent(callID: session.callID, kind: .upload)
  try await repository.prepareCaptureFinalization(
    callID: session.callID, reason: "system_sleep", associatedWork: work)
  let master = try finishCapture(writer, reason: "system_sleep")
  let fault = RepositoryFault(point)
  let failing = try LocalRepository(
    root: root, archiveID: session.archiveID, interruption: fault.callAsFunction)
  await #expect(throws: RepositoryInjectedFailure.self) {
    try await failing.completeCapture(session, master: master, reason: "system_sleep")
  }
  let published = point == .afterRepositoryCommit
  #expect((try repository.captureCompletion(callID: session.callID) != nil) == published)
  #expect((try await repository.operation(work.operationID) != nil) == published)
  let completed = try await session.recoverCompletion()
  #expect(completed.master == master)
  #expect(try await repository.snapshotBytes(callID: session.callID, version: 1) == original)
  #expect(try await repository.operation(work.operationID) != nil)
  #expect(
    try await repository.completeCapture(
      session, master: master, reason: "system_sleep", associatedWork: work) == completed)
  let conflicted = repositoryIntent(callID: session.callID, kind: .upload)
  await #expect(throws: LocalPersistenceError.self) {
    try await repository.completeCapture(
      session, master: master, reason: "system_sleep", associatedWork: conflicted)
  }
}

@Test func rawAndStreamingFinalizationShareRetainedWorkReasonAndSourceEvidence() async throws {
  let root = repositoryRoot("raw-final-intent")
  defer { try? FileManager.default.removeItem(at: root) }
  let session = try repositorySession(root)
  try await session.prepare()
  let repository = try LocalRepository(root: root, archiveID: session.archiveID)
  let writer = try CaptureMediaWriter(session: session)
  let timeline = CaptureTimeline(writer: writer)
  try timeline.setMicrophoneEnabled(false, atMs: 0)
  try timeline.append(
    role: .application, startFrame: 0, samples: Array(repeating: Int16(100), count: 16_000))
  try timeline.flush(throughMs: 1000)
  let retained = repositoryIntent(
    callID: session.callID, kind: .upload, payload: Data("retained master work".utf8))
  let conflict = repositoryIntent(callID: session.callID, kind: .replica)
  try await repository.prepareCaptureFinalization(
    callID: session.callID, reason: "system_sleep", associatedWork: retained)
  let master = try finishCapture(writer, reason: "system_sleep")
  let audio = try session.audioBytes(master)
  var call = try Contract.decode(
    CallDocument.self,
    bytes: session.callBytes(
      media: master,
      reason: "system_sleep", version: 2, finalized: true,
      microphoneIntervals: captureIntervals(writer, role: .microphone),
      applicationIntervals: captureIntervals(writer, role: .application),
      reference: .init(manifestId: session.audioManifestID, sha256: Contract.hash(audio)))
  ).value
  // Semantically equivalent source intervals and wire whitespace remain exact input bytes.
  call.tracks[0].intervals = [
    .init(startMs: 0, endMs: 500, state: "muted", reason: "muted"),
    .init(startMs: 500, endMs: 1000, state: "muted", reason: "muted"),
  ]
  let bytes = Data(" \n".utf8) + (try Contract.encode(call))
  await #expect(throws: LocalPersistenceError.operationConflict(conflict.operationID)) {
    try await repository.finalizeCapture(
      callSnapshot: bytes, audioManifest: audio, verifiedMaster: master,
      associatedWork: conflict)
  }
  await #expect(throws: LocalPersistenceError.operationConflict(conflict.operationID)) {
    try await repository.completeCapture(
      session, master: master, reason: "system_sleep", associatedWork: conflict)
  }
  var wrongReason = call
  wrongReason.captureState = "stopped"
  wrongReason.interruptionReason = nil
  await #expect(throws: LocalPersistenceError.self) {
    try await repository.finalizeCapture(
      callSnapshot: Contract.encode(wrongReason), audioManifest: audio, verifiedMaster: master)
  }
  var wrongSource = call
  wrongSource.tracks[0].intervals = [.init(startMs: 0, endMs: 1000, state: "recorded", reason: nil)]
  await #expect(throws: LocalPersistenceError.invalidMediaProgress) {
    try await repository.finalizeCapture(
      callSnapshot: Contract.encode(wrongSource), audioManifest: audio, verifiedMaster: master)
  }
  #expect(try repository.captureCompletion(callID: session.callID) == nil)
  #expect(try await repository.operation(retained.operationID) == nil)
  let raw = try await repository.finalizeCapture(
    callSnapshot: bytes, audioManifest: audio, verifiedMaster: master)
  #expect(raw.manifest.storedBytes == bytes)
  #expect(try await repository.operation(retained.operationID)?.payload == retained.payload)
  let compact = try await repository.completeCapture(
    session, master: master, reason: "system_sleep")
  #expect(compact.snapshotSHA256 == Contract.hash(bytes))
  #expect(try await session.recoverCompletion() == compact)
  #expect(
    try await repository.finalizeCapture(
      callSnapshot: bytes, audioManifest: audio, verifiedMaster: master
    ).manifest.storedBytes == bytes)
  let immutableSnapshot = LocalPersistenceError.immutableConflict("\(session.callID):2")
  await #expect(throws: immutableSnapshot) {
    try await repository.finalizeCapture(
      callSnapshot: Contract.encode(call), audioManifest: audio, verifiedMaster: master)
  }
  var changedMetadata = call
  changedMetadata.source.windowTitle = "Different source metadata"
  await #expect(throws: immutableSnapshot) {
    try await repository.finalizeCapture(
      callSnapshot: Contract.encode(changedMetadata), audioManifest: audio, verifiedMaster: master)
  }
  var later = call
  later.documentVersion = 3
  let laterBytes = try Contract.encode(later)
  // Finalization cannot invent a new revision after it has published its retained snapshot.
  await #expect(throws: LocalPersistenceError.immutableConflict("\(session.callID):3")) {
    try await repository.finalizeCapture(
      callSnapshot: laterBytes, audioManifest: audio, verifiedMaster: master)
  }
  #expect(try await repository.publishManifest(laterBytes) == .committed)
  #expect(
    try await repository.finalizeCapture(
      callSnapshot: bytes, audioManifest: audio, verifiedMaster: master
    ).manifest.storedBytes == laterBytes)
  #expect(try await repository.snapshotBytes(callID: session.callID, version: 2) == bytes)
  let latest = try await repository.completeCapture(
    session, master: master, reason: "system_sleep")
  #expect(latest.call.documentVersion == 3 && latest.snapshotSHA256 == Contract.hash(laterBytes))
  #expect(try await session.recoverCompletion() == latest)
  await #expect(throws: LocalPersistenceError.operationConflict(conflict.operationID)) {
    try await repository.finalizeCapture(
      callSnapshot: bytes, audioManifest: audio, verifiedMaster: master, associatedWork: conflict)
  }
}
