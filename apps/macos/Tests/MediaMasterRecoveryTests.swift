import AVFoundation
import Darwin
import Foundation
import Testing

@testable import TrigoNative

private final class MasterBundleMarker: NSObject {}
private struct MasterInjectedFault: Error {}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TRIGO_MASTER_KILL_ROOT"] != nil))
func mediaMasterSIGKILLChild() throws {
  let environment = ProcessInfo.processInfo.environment
  let root = URL(fileURLWithPath: try #require(environment["TRIGO_MASTER_KILL_ROOT"]))
  let point = try #require(environment["TRIGO_MASTER_KILL_POINT"])
  let identity = masterFixtureIdentity()
  var operations = 0
  let writer = try RecoverableMediaMaster(
    directory: root,
    identity: identity,
    io: .init(event: { event in
      if event.rawValue == point {
        operations += 1
        if operations
          == (event == .beforeFinalizationSync || event == .afterFinalizationSync ? 1 : 3)
        {
          _ = Darwin.kill(Darwin.getpid(), SIGKILL)
          while true { Darwin.pause() }
        }
      }
    })
  )
  for _ in 0..<3 { try appendMasterSecond(writer) }
  _ = try writer.finish()
  Issue.record("Child must terminate at the selected real process-kill boundary")
}

@Test(arguments: MediaMasterIOPoint.allCases)
func mediaMasterRealSIGKILLPreservesVerifiedPrefix(point: MediaMasterIOPoint) throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let child = Process()
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  let bundle = try #require(Bundle(for: MasterBundleMarker.self).executableURL?.path)
  let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().path
  child.arguments = [
    "--test-bundle-path", bundle, "--package-path", package,
    "--filter", "mediaMasterSIGKILLChild", bundle, "--testing-library", "swift-testing",
  ]
  child.environment = ProcessInfo.processInfo.environment.merging(
    ["TRIGO_MASTER_KILL_ROOT": root.path, "TRIGO_MASTER_KILL_POINT": point.rawValue],
    uniquingKeysWith: { _, new in new }
  )
  child.standardOutput = FileHandle.nullDevice
  child.standardError = FileHandle.nullDevice
  try child.run()
  child.waitUntilExit()
  #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
  let header = try FileHandle(forReadingFrom: root.appendingPathComponent("master.index"))
  let identity = try MediaMasterIndex.identity(try #require(try header.read(upToCount: 128)))
  try header.close()
  let writer = try RecoverableMediaMaster(reopening: root, expectedIdentity: identity)
  let expectedSeconds: Int64 = point == .beforeMediaSync || point == .afterMediaSync ? 2 : 3
  #expect(writer.cursor.frames == expectedSeconds * 16000)
  #expect(3 * 16000 - writer.cursor.frames <= 2 * 16000)
  #expect(writer.discardedTailBytes == (3 - expectedSeconds) * 64000)
  let final = try writer.finish()
  let again = try RecoverableMediaMaster(
    reopening: root,
    expectedIdentity: identity,
    confirmed: final.cursor
  )
  #expect(try again.finish() == final)
  let audio = try AVAudioFile(forReading: again.mediaURL)
  #expect(audio.length == expectedSeconds * 16000)
  print(
    "MASTER_SIGKILL point=\(point.rawValue) recovered_ms=\(expectedSeconds * 1000) discarded_bytes=\(writer.discardedTailBytes)"
  )
}

@Test func mediaMasterPartialWritesRetryAndFailClosed() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  var remaining: Int? = nil
  var writes = 0
  let writer = try RecoverableMediaMaster(
    directory: root,
    identity: identity,
    io: .init(write: { fd, bytes in
      if remaining == 0 { throw MasterInjectedFault() }
      let length = min(bytes.count, 701, remaining ?? Int.max)
      let written = Darwin.write(fd, bytes.baseAddress, length)
      writes += 1
      if let old = remaining, written > 0 { remaining = old - written }
      return written
    })
  )
  try appendMasterSecond(writer)
  #expect(writes > 90)
  let confirmed = writer.cursor
  remaining = 12345  // Real partially persisted PCM, ending in an incomplete stereo frame.
  #expect(throws: MasterInjectedFault.self) { try appendMasterSecond(writer, value: 9000) }
  #expect(writer.cursor == confirmed)
  #expect(throws: MediaMasterError.closed) { try appendMasterSecond(writer) }
  #expect(throws: MediaMasterError.invalidInput) {
    try writer.readStableBytes(in: confirmed.stableBytes..<(confirmed.stableBytes + 1))
  }
  let reopened = try RecoverableMediaMaster(
    reopening: root,
    expectedIdentity: identity,
    confirmed: confirmed
  )
  #expect(reopened.cursor == confirmed)
  #expect(reopened.discardedTailBytes == 12345)
  try appendMasterSecond(reopened)
  #expect(reopened.cursor.frames == 32000)
}

@Test(arguments: [0, 1, 31, 2119])
func mediaMasterShortIndexTailIsNeverAConfirmedCursor(tailBytes: Int) throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  var enabled = false
  var available = 64000 + tailBytes
  let writer = try RecoverableMediaMaster(
    directory: root,
    identity: identity,
    io: .init(write: { fd, bytes in
      if enabled && available == 0 { throw MasterInjectedFault() }
      let size = enabled ? min(available, bytes.count) : bytes.count
      let written = Darwin.write(fd, bytes.baseAddress, size)
      if enabled && written > 0 { available -= written }
      return written
    })
  )
  try appendMasterSecond(writer)
  let confirmed = writer.cursor
  enabled = true
  #expect(throws: MasterInjectedFault.self) { try appendMasterSecond(writer) }
  #expect(writer.cursor == confirmed)
  let recovered = try RecoverableMediaMaster(
    reopening: root,
    expectedIdentity: identity,
    confirmed: confirmed
  )
  #expect(recovered.cursor == confirmed)
  #expect(recovered.discardedTailBytes == 64000)
}

@Test(arguments: ["truncate", "corrupt"])
func mediaMasterUncommittedTailDamagePreservesCommittedAudio(damage: String) throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  var fail = false
  let writer = try RecoverableMediaMaster(
    directory: root,
    identity: identity,
    io: .init(event: { event in
      if fail && event == .afterMediaSync { throw MasterInjectedFault() }
    })
  )
  for _ in 0..<2 { try appendMasterSecond(writer) }
  let confirmed = writer.cursor
  let prefix = try writer.readStableBytes(in: 0..<confirmed.stableBytes)
  fail = true
  #expect(throws: MasterInjectedFault.self) { try appendMasterSecond(writer, value: 30000) }
  let media = try FileHandle(forWritingTo: writer.mediaURL)
  if damage == "truncate" {
    try media.truncate(atOffset: UInt64(confirmed.stableBytes + 317))
  } else {
    try media.seek(toOffset: UInt64(confirmed.stableBytes))
    try media.write(contentsOf: Data(repeating: 255, count: 64000))
  }
  try media.synchronize()
  try media.close()
  let recovered = try RecoverableMediaMaster(
    reopening: root,
    expectedIdentity: identity,
    confirmed: confirmed
  )
  #expect(recovered.cursor == confirmed)
  #expect(try recovered.readStableBytes(in: 0..<confirmed.stableBytes) == prefix)
  #expect(try AVAudioFile(forReading: recovered.mediaURL).length == 32000)
  var endMs = 0
  try recovered.forEachCommit(intersecting: 0..<32000) {
    endMs = try #require($0.microphoneIntervals.last).endMs
  }
  #expect(endMs == 2000)  // The missing third second is not metadata claiming recorded speech.
}

@Test func mediaMasterCommittedCorruptionAndMissingWitnessAreExplicitFailures() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  let writer = try RecoverableMediaMaster(directory: root, identity: identity)
  for _ in 0..<3 { try appendMasterSecond(writer) }
  let media = try FileHandle(forWritingTo: writer.mediaURL)
  try media.seek(toOffset: 80)
  try media.write(contentsOf: Data([255]))
  try media.close()
  #expect(throws: MediaMasterError.committedAudioCorruption(record: 1)) {
    try RecoverableMediaMaster(
      reopening: root,
      expectedIdentity: identity,
      confirmed: writer.cursor
    )
  }
  // Independent second resource tests an index rollback without modifying any private archive.
  let other = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: other) }
  let intact = try RecoverableMediaMaster(directory: other, identity: identity)
  try appendMasterSecond(intact)
  let index = try FileHandle(forWritingTo: other.appendingPathComponent("master.index"))
  try index.truncate(atOffset: 128)
  try index.close()
  #expect(throws: MediaMasterError.confirmedCursorMissing) {
    try RecoverableMediaMaster(
      reopening: other,
      expectedIdentity: identity,
      confirmed: intact.cursor
    )
  }
  #expect(
    try FileManager.default.attributesOfItem(atPath: intact.mediaURL.path)[.size] as? Int == 64068
  )
}

@Test func mediaMasterSyncedButUnacknowledgedCommitReconcilesWithoutChangingIdentity() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  var fail = false
  let writer = try RecoverableMediaMaster(
    directory: root,
    identity: identity,
    io: .init(event: { point in
      if fail && point == .afterIndexSync { throw MasterInjectedFault() }
    })
  )
  try appendMasterSecond(writer)
  let published = writer.cursor
  fail = true
  #expect(throws: MasterInjectedFault.self) { try appendMasterSecond(writer) }
  #expect(writer.cursor == published)  // No returned certificate followed the uncertain operation.
  let recovered = try RecoverableMediaMaster(
    reopening: root,
    expectedIdentity: identity,
    confirmed: published
  )
  #expect(recovered.cursor.frames == 32000 && recovered.cursor.commitCount == 2)
  #expect(recovered.identity == identity)
  #expect(recovered.cursor.integritySHA256 != published.integritySHA256)
}

@Test func mediaMasterPartialFinalizationIsIdempotent() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  let writer = try RecoverableMediaMaster(directory: root, identity: identity)
  try appendMasterSecond(writer)
  let final = try writer.finish()
  let index = try FileHandle(forWritingTo: root.appendingPathComponent("master.index"))
  try index.truncate(atOffset: 128 + 2120 + 87)
  try index.synchronize()
  try index.close()
  let recovered = try RecoverableMediaMaster(
    reopening: root,
    expectedIdentity: identity,
    confirmed: final.cursor
  )
  #expect(recovered.finalized == nil)
  #expect(try recovered.finish() == final)
  #expect(try recovered.finish() == final)
}

@Test(arguments: ["media-truncate", "index-corrupt", "identity"])
func mediaMasterCommittedDamageIsRejectedWithoutRepair(damage: String) throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  let writer = try RecoverableMediaMaster(directory: root, identity: identity)
  try appendMasterSecond(writer)
  let target =
    damage == "index-corrupt" ? root.appendingPathComponent("master.index") : writer.mediaURL
  let handle = try FileHandle(forWritingTo: target)
  if damage == "media-truncate" { try handle.truncate(atOffset: 64066) }
  if damage == "index-corrupt" {
    try handle.seek(toOffset: 222)
    try handle.write(contentsOf: Data([255]))
  }
  try handle.synchronize()
  try handle.close()
  let before = try masterFileHash(target)
  let error: MediaMasterError =
    damage == "media-truncate"
    ? .committedAudioCorruption(record: 1)
    : damage == "index-corrupt" ? .corruptIndex(record: 1) : .identityMismatch
  #expect(throws: error) {
    try RecoverableMediaMaster(
      reopening: root,
      expectedIdentity: damage == "identity" ? masterFixtureIdentity() : identity,
      confirmed: writer.cursor
    )
  }
  #expect(try masterFileHash(target) == before)
}

@Test func mediaMasterFullSizedCorruptUncommittedIndexTailUsesConfirmedWitness() throws {
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  var fail = false
  let writer = try RecoverableMediaMaster(
    directory: root,
    identity: identity,
    io: .init(event: { point in
      if fail && point == .beforeIndexSync { throw MasterInjectedFault() }
    })
  )
  for _ in 0..<2 { try appendMasterSecond(writer) }
  let witness = writer.cursor
  let prefix = try writer.readStableBytes(in: 0..<witness.stableBytes)
  fail = true
  #expect(throws: MasterInjectedFault.self) { try appendMasterSecond(writer, value: 29000) }
  let index = try FileHandle(forWritingTo: root.appendingPathComponent("master.index"))
  try index.seek(toOffset: UInt64(128 + 2 * 2120 + 99))
  try index.write(contentsOf: Data([255]))
  try index.synchronize()
  try index.close()
  #expect(throws: MediaMasterError.corruptIndex(record: 3)) {
    try RecoverableMediaMaster(reopening: root, expectedIdentity: identity)
  }
  let recovered = try RecoverableMediaMaster(
    reopening: root,
    expectedIdentity: identity,
    confirmed: witness
  )
  #expect(recovered.cursor == witness)
  #expect(recovered.discardedTailBytes == 64000)
  #expect(try recovered.readStableBytes(in: 0..<witness.stableBytes) == prefix)
  #expect(try recovered.finish().cursor.frames == 32000)
}

@Test(arguments: [true, false])
func mediaMasterCorruptIndexCannotDiscardConfirmedOrNonterminalRecords(confirmedDamage: Bool) throws
{
  let root = masterFixtureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let identity = masterFixtureIdentity()
  let writer = try RecoverableMediaMaster(directory: root, identity: identity)
  try appendMasterSecond(writer)
  let earlier = writer.cursor
  try appendMasterSecond(writer)
  let witness = confirmedDamage ? writer.cursor : earlier
  if !confirmedDamage { try appendMasterSecond(writer) }
  let indexURL = root.appendingPathComponent("master.index")
  let index = try FileHandle(forWritingTo: indexURL)
  try index.seek(toOffset: UInt64(128 + 2120 + 99))
  try index.write(contentsOf: Data([255]))
  try index.synchronize()
  try index.close()
  let before = try masterFileHash(indexURL)
  #expect(throws: MediaMasterError.corruptIndex(record: 2)) {
    try RecoverableMediaMaster(reopening: root, expectedIdentity: identity, confirmed: witness)
  }
  #expect(try masterFileHash(indexURL) == before)
}
