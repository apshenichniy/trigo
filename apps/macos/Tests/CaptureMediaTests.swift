import AVFoundation
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

@Test func captureWriterProducesOneIndependentlyDecodableProfileMaster() async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let stereo = (0..<16_000).flatMap { _ in [Int16(8_192), Int16(-16_384)] }
  try writer.append(interleaved: stereo)
  let result = try finishCapture(writer)
  #expect(result.durationMs == 1_000)
  #expect(result.cursor.stableBytes == 64_068)
  #expect(result.cursor.identity == writer.session.mediaMasterIdentity)
  #expect(try finishCapture(writer) == result)
  let file = try AVAudioFile(forReading: writer.master.mediaURL)
  #expect(file.fileFormat.sampleRate == 16_000)
  #expect(file.fileFormat.channelCount == 2)
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)
  )
  try file.read(into: buffer)
  #expect(buffer.frameLength == 16_000)
  #expect(buffer.floatChannelData?[0][0] == 0.25)
  #expect(buffer.floatChannelData?[1][15_999] == -0.5)
  let aggregate = try await writer.session.finish(media: result, interruptionReason: nil)
  let manifest = try Contract.decode(AudioManifest.self, bytes: #require(aggregate.audioManifest))
    .value
  #expect(manifest.objects.count == 1)
  #expect(manifest.objects[0].objectId == writer.session.masterID)
  #expect(manifest.objects[0].sha256 == result.sha256)
  let repository = try LocalRepository(root: root, archiveID: writer.session.archiveID)
  #expect(try repository.finalizedMaster(callID: writer.session.callID) == result)
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: writer.session.mediaDirectory.path).sorted()
      == ["master.caf", "master.index"]
  )
}

@Test func captureRecoveryDiscardsOnlyUncommittedTailAndNeverResumesRecording() async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let fault = CaptureDiskFault()
  let writer = try await captureWriter(root: root, io: .init(event: fault.check))
  let samples = Array(repeating: Int16(120), count: 32_000)
  try writer.append(interleaved: samples)
  try writer.append(interleaved: samples)
  fault.fail = true
  #expect(throws: CaptureDiskFault.Failure.self) { try writer.append(interleaved: samples) }
  let recovery = try CaptureMediaWriter.recover(session: writer.session)
  #expect(recovery.master.discardedTailBytes == 64_000)
  #expect(recovery.durationMs == 2_000)
  let file = try AVAudioFile(forReading: recovery.master.mediaURL)
  #expect(file.length == 32_000)
  #expect(throws: CaptureError.closed) { try writer.append(interleaved: samples) }
  #expect(throws: CaptureError.closed) { try recovery.append(interleaved: samples) }
  #expect(throws: MediaMasterError.self) { try CaptureMediaWriter(session: writer.session) }
  let aggregate = try await writer.session.recover()
  #expect(aggregate.manifest.value.durationMs == 2_000)
  #expect(aggregate.manifest.value.captureState == "interrupted")
}

@Test(arguments: ["corrupt-complete-index", "missing-confirmed-index"])
func productionRecoveryRejectsIndexDamageWithoutDiscardingWitnessedMedia(
  damage: String
)
  async throws
{
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let timeline = CaptureTimeline(writer: writer)
  try timeline.append(
    role: .application,
    startFrame: 0,
    samples: Array(repeating: Int16(500), count: 16_000)
  )
  try timeline.flush(throughMs: 1000)
  let confirmed = try writer.confirmedCursor()
  let original = try Data(contentsOf: writer.master.mediaURL)
  let index = try FileHandle(
    forWritingTo: writer.session.mediaDirectory.appendingPathComponent("master.index")
  )
  if damage == "corrupt-complete-index" {
    try index.seek(toOffset: 128 + 100)
    try index.write(contentsOf: Data([0xff]))
  } else {
    try index.truncate(atOffset: 128)
  }
  try index.synchronize()
  try index.close()
  await #expect(throws: MediaMasterError.self) { try await writer.session.recoverCompletion() }
  #expect(try Data(contentsOf: writer.master.mediaURL) == original)
  let repository = try LocalRepository(root: root, archiveID: writer.session.archiveID)
  #expect(try repository.confirmedMediaCursor(callID: writer.session.callID) == confirmed)
  #expect(try repository.captureCompletion(callID: writer.session.callID) == nil)
}

@Test func productionZeroFrameCompletionRequiresTheActualHeaderWitness() async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let repository = try LocalRepository(root: root, archiveID: writer.session.archiveID)
  await #expect(throws: LocalPersistenceError.invalidMediaProgress) {
    try await repository.completeCapture(writer.session, master: nil, reason: nil)
  }
  let final = try finishCapture(writer)
  #expect(final.cursor.frames == 0 && final.cursor.stableBytes == 68)
  #expect(final.sha256 == MediaMasterProfile.header.masterSHA256.masterHex)
  let forged = FinalizedMediaMaster(cursor: final.cursor, sha256: String(repeating: "0", count: 64))
  await #expect(throws: LocalPersistenceError.invalidMediaProgress) {
    try await repository.completeCapture(writer.session, master: forged, reason: nil)
  }
  let audioBytes = try writer.session.audioBytes(final)
  let callBytes = try writer.session.callBytes(
    media: final,
    reason: nil,
    version: 2,
    finalized: true,
    reference: .init(manifestId: writer.session.audioManifestID, sha256: Contract.hash(audioBytes))
  )
  for witness in [nil, forged] {
    await #expect(throws: LocalPersistenceError.invalidMediaProgress) {
      try await repository.finalizeCapture(
        callSnapshot: callBytes,
        audioManifest: audioBytes,
        verifiedMaster: witness
      )
    }
  }
  let complete = try await writer.session.complete(media: final, interruptionReason: nil)
  #expect(complete.master == final)
  let loaded = try await repository.loadCall(callID: writer.session.callID)
  let audio = try Contract.decode(AudioManifest.self, bytes: #require(loaded.audioManifest)).value
  #expect(audio.durationMs == 0 && audio.objects.isEmpty)
  #expect(try await writer.session.recoverCompletion() == complete)
}

private final class CaptureDiskFault {
  struct Failure: Error {}
  var fail = false
  var point: MediaMasterIOPoint = .afterMediaSync
  func check(_ point: MediaMasterIOPoint) throws {
    if fail && point == self.point { throw Failure() }
  }
}

@Test(arguments: [true, false])
func productionRecoveryDiscardsATornCompleteRecordOnlyAboveItsSQLWitness(
  terminal: Bool
)
  async throws
{
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let fault = CaptureDiskFault()
  fault.point = .beforeIndexSync
  let writer = try await captureWriter(root: root, io: .init(event: fault.check))
  let timeline = CaptureTimeline(writer: writer)
  try timeline.append(
    role: .application,
    startFrame: 0,
    samples: Array(repeating: Int16(100), count: 16_000)
  )
  try timeline.flush(throughMs: 1000)
  let witness = try writer.confirmedCursor()
  let prefix = try writer.readStableBytes(in: 0..<witness.stableBytes)
  try timeline.append(
    role: .application,
    startFrame: 16_000,
    samples: Array(repeating: Int16(200), count: 16_000)
  )
  fault.fail = true
  #expect(throws: CaptureDiskFault.Failure.self) { try timeline.flush(throughMs: 2000) }
  #expect(try writer.confirmedCursor() == witness)
  let index = try FileHandle(
    forWritingTo: writer.session.mediaDirectory.appendingPathComponent("master.index")
  )
  try index.seek(toOffset: 128 + 2120 + 100)
  try index.write(contentsOf: Data([0xff]))
  if !terminal {
    try index.seekToEnd()
    try index.write(contentsOf: Data([1]))
  }
  try index.synchronize()
  try index.close()
  if terminal {
    let recovered = try CaptureMediaWriter.recover(session: writer.session)
    #expect(recovered.master.discardedTailBytes == 64_000)
    #expect(try recovered.confirmedCursor() == witness)
    #expect(try recovered.readStableBytes(in: 0..<witness.stableBytes) == prefix)
    let completed = try await writer.session.recoverCompletion()
    #expect(completed.call.durationMs == 1000)
    #expect(completed.master?.cursor.identity == witness.identity)
  } else {
    let original = try Data(contentsOf: writer.master.mediaURL)
    #expect(throws: MediaMasterError.corruptIndex(record: 2)) {
      try CaptureMediaWriter.recover(session: writer.session)
    }
    #expect(try Data(contentsOf: writer.master.mediaURL) == original)
  }
}

@Test func captureBeyondSixtySecondsKeepsOneIdentityAndRejectsCommittedCorruption() async throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try await captureWriter(root: root)
  let second = Array(repeating: Int16(1_234), count: 32_000)
  for _ in 0..<62 { try writer.append(interleaved: second) }
  #expect(writer.master.cursor.identity == writer.session.mediaMasterIdentity)
  #expect(try AVAudioFile(forReading: writer.master.mediaURL).length == 62 * 16_000)
  let handle = try FileHandle(forWritingTo: writer.master.mediaURL)
  try handle.seek(toOffset: 68 + 61 * 64_000)
  try handle.write(contentsOf: Data([0xff]))
  try handle.close()
  #expect(throws: MediaMasterError.committedAudioCorruption(record: 62)) {
    try CaptureMediaWriter.recover(session: writer.session)
  }
  await #expect(throws: MediaMasterError.committedAudioCorruption(record: 62)) {
    try await writer.session.recover()
  }
  let repository = try LocalRepository(root: root, archiveID: writer.session.archiveID)
  #expect(try repository.confirmedMediaCursor(callID: writer.session.callID)?.frames == 62 * 16_000)
  #expect(try await repository.call(callID: writer.session.callID).audioManifest == nil)
}
