import AVFoundation
import Foundation
import Testing
import TrigoContracts

@testable import TrigoNative

private func captureRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("trigo-capture-test-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

@Test func captureWriterProducesIndependentlyDecodableProfileWave() throws {
  let root = try captureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try CaptureMediaWriter(directory: root)
  let stereo = (0..<16_000).flatMap { _ in [Int16(8_192), Int16(-16_384)] }
  try writer.append(interleaved: stereo)
  let result = try writer.finish()
  #expect(result.durationMs == 1_000)
  #expect(result.objects.count == 1)
  let object = try #require(result.objects.first)
  #expect(object.byteLength == 64_044)
  #expect(object.startMs == 0 && object.endMs == 1_000)
  let file = try AVAudioFile(forReading: root.appendingPathComponent(object.filename))
  #expect(file.fileFormat.sampleRate == 16_000)
  #expect(file.fileFormat.channelCount == 2)
  let buffer = try #require(
    AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000))
  try file.read(into: buffer)
  #expect(buffer.frameLength == 16_000)
  #expect(buffer.floatChannelData?[0][0] == 0.25)
  #expect(buffer.floatChannelData?[1][15_999] == -0.5)
}

@Test func captureRecoveryIgnoresUnsyncedTailAndNeverResumesRecording() throws {
  let root = try captureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let fault = CaptureDiskFault()
  let writer = try CaptureMediaWriter(directory: root, interruption: fault.check)
  try writer.append(interleaved: Array(repeating: Int16(120), count: 64_000))
  fault.fail = true
  #expect(throws: CaptureDiskFault.Failure.self) {
    try writer.append(interleaved: Array(repeating: Int16(999), count: 32_000))
  }
  let recovery = try CaptureMediaWriter.recover(directory: root)
  #expect(recovery.wasInterrupted)
  #expect(recovery.media.durationMs == 2_000)
  let file = try AVAudioFile(
    forReading: root.appendingPathComponent(
      #require(recovery.media.objects.first).filename))
  #expect(file.length == 32_000)
  #expect(throws: CaptureError.self) { try writer.append(interleaved: [1, 2]) }
  #expect(throws: CaptureError.self) { try CaptureMediaWriter(directory: root) }
}

private final class CaptureDiskFault {
  struct Failure: Error {}
  var fail = false
  func check(_ point: CaptureWritePoint) throws {
    if fail && point == .afterPCMSync { throw Failure() }
  }
}

@Test func captureWriterRollsAtSixtySecondsAndRejectsCorruptTail() throws {
  let root = try captureRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  let writer = try CaptureMediaWriter(directory: root)
  let second = Array(repeating: Int16(1_234), count: 32_000)
  for _ in 0..<62 { try writer.append(interleaved: second) }
  // Corruption is injected at the filesystem boundary, not into writer internals.
  let spool = try #require(
    FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil
    ).first { $0.pathExtension == "pcm" })
  let handle = try FileHandle(forWritingTo: spool)
  try handle.seek(toOffset: 64_000)
  try handle.write(contentsOf: Data([0xff]))
  try handle.close()
  let recovered = try CaptureMediaWriter.recover(directory: root)
  #expect(recovered.rejectedTail)
  #expect(recovered.media.durationMs == 61_000)
  #expect(recovered.media.objects.map(\.byteLength) == [3_840_044, 64_044])
  #expect(recovered.media.objects.map(\.index) == [0, 1])
  #expect(
    try AVAudioFile(
      forReading: root.appendingPathComponent(
        recovered.media.objects[0].filename)
    ).length == 960_000)
}
