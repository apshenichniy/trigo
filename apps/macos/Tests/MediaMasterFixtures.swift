import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Testing

@testable import TrigoNative

func masterResources(_ phase: String) {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  var memory = task_vm_info_data_t()
  var count = mach_msg_type_number_t(
    MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
  )
  let result = withUnsafeMutablePointer(to: &memory) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  if result == KERN_SUCCESS {
    print(
      "MASTER_VM phase=\(phase) resident=\(memory.resident_size) footprint=\(memory.phys_footprint) internal=\(memory.internal) external=\(memory.external)"
    )
  }
  print(
    "MASTER_RESOURCES phase=\(phase) peak_rss_bytes=\(usage.ru_maxrss) host=\(CommandLine.arguments[0])"
  )
}

func masterFixtureRoot() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent("trigo-master-proof-\(UUID())")
}

func masterFixtureIdentity() -> MediaMasterIdentity {
  .init(masterID: UUID(), callID: UUID(), microphoneTrackID: UUID(), applicationTrackID: UUID())
}

func masterState(second: Int, millisecond: Int, channel: Int) -> CaptureIntervalState {
  if second == 0 && millisecond < 100 { return .unavailable }
  let phase = (millisecond / 10 + second) % 4
  if channel == 0 {
    return phase == 1 ? .muted : phase == 2 ? .unavailable : .recorded
  }
  return phase == 3 ? .unavailable : .recorded
}

func masterSignal(second: Int, frame: Int, channel: Int) -> Int16 {
  let marker = 1024 + (second % 97) * 16 + frame % 13
  return Int16(channel == 0 ? marker : -marker * 2)
}

func masterFixtureSecond(_ second: Int, into writer: RecoverableMediaMaster) throws {
  var pcm = [Int16]()
  pcm.reserveCapacity(32_000)
  var spans: [[CaptureInterval]] = [[], []]
  for ms in 0..<1000 {
    for channel in 0...1 {
      mergeCaptureInterval(
        .init(
          startMs: second * 1000 + ms,
          endMs: second * 1000 + ms + 1,
          state: masterState(second: second, millisecond: ms, channel: channel)
        ),
        into: &spans[channel]
      )
    }
    for frame in (ms * 16)..<((ms + 1) * 16) {
      // Deliberately supply nonzero input in suppressed intervals. The first persisted form must
      // already be silent, including the media checksum and upload/extraction representations.
      pcm.append(masterSignal(second: second, frame: frame, channel: 0))
      pcm.append(masterSignal(second: second, frame: frame, channel: 1))
    }
  }
  try writer.append(interleaved: pcm, microphoneIntervals: spans[0], applicationIntervals: spans[1])
}

func appendMasterSecond(_ writer: RecoverableMediaMaster, value: Int16 = 1234) throws {
  let ms = Int(writer.cursor.frames / 16)
  try writer.append(
    interleaved: Array(repeating: value, count: 32000),
    microphoneIntervals: [.init(startMs: ms, endMs: ms + 1000, state: .recorded)],
    applicationIntervals: [.init(startMs: ms, endMs: ms + 1000, state: .recorded)]
  )
}

func masterFileHash(_ url: URL) throws -> String {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  var hash = SHA256()
  while let bytes = try handle.readMasterBytes(upToCount: 64_000), !bytes.isEmpty {
    hash.update(data: bytes)
  }
  return Data(hash.finalize()).masterHex
}

func checkMasterSamples(_ buffer: AVAudioPCMBuffer, startFrame: Int64) throws {
  let channels = try #require(buffer.floatChannelData)
  for offset in 0..<Int(buffer.frameLength) {
    let absolute = Int(startFrame) + offset
    let second = absolute / 16000
    let frame = absolute % 16000
    for channel in 0...1 {
      let expected =
        masterState(second: second, millisecond: frame / 16, channel: channel) == .recorded
        ? Float(masterSignal(second: second, frame: frame, channel: channel)) / 32768 : 0
      guard channels[channel][offset] == expected else {
        Issue.record("Source mismatch at call frame \(absolute), channel \(channel)")
        throw MediaMasterError.invalidInput
      }
    }
  }
}
