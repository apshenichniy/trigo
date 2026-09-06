import Darwin
import Foundation
import Testing

@testable import TrigoNative

private final class CaptureTestBundleMarker: NSObject {}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TRIGO_CAPTURE_CRASH_DIRECTORY"] != nil))
func captureTerminationChild() throws {
  let root = URL(
    fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["TRIGO_CAPTURE_CRASH_DIRECTORY"]))
  var synced = 0
  let writer = try CaptureMediaWriter(directory: root) { point in
    if point == .afterPCMSync {
      synced += 1
      if synced == 3 {
        guard Darwin.kill(Darwin.getpid(), SIGKILL) == 0 else { throw CaptureError.closed }
        // kill(2) can return before this multithreaded host terminates. Never
        // let the writer commit its third checkpoint while termination is pending.
        while true { Darwin.pause() }
      }
    }
  }
  try writer.append(interleaved: Array(repeating: 123, count: 96_000))
  Issue.record("Fixture must be killed at the third one-second sync")
}

@Test(arguments: 0..<25)
func forcedProcessTerminationLosesOnlyOneSecondOfUncommittedTail(iteration: Int) throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-kill-fixture-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let child = Process()
  // SwiftPM's macOS test product is a loadable bundle, not a standalone executable.
  // Reuse the pinned toolchain's current test host, selecting only this fixture.
  child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  let bundlePath = Bundle(for: CaptureTestBundleMarker.self).executableURL!.path
  let packagePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().path
  child.arguments = [
    "--test-bundle-path", bundlePath, "--package-path", packagePath,
    "--filter", "captureTerminationChild", bundlePath, "--testing-library", "swift-testing",
  ]
  child.environment = ProcessInfo.processInfo.environment.merging(
    ["TRIGO_CAPTURE_CRASH_DIRECTORY": root.path], uniquingKeysWith: { _, new in new })
  child.standardOutput = FileHandle.nullDevice
  child.standardError = FileHandle.nullDevice
  try child.run()
  child.waitUntilExit()
  #expect(child.terminationReason == .uncaughtSignal)
  #expect(child.terminationStatus == SIGKILL)
  let checkpoint = try jsonObject(
    Data(contentsOf: root.appendingPathComponent("media-checkpoint.json")))
  let fragments = try #require(checkpoint["fragments"] as? [Any])
  let activeID = try #require(checkpoint["activeID"] as? String)
  let spoolBytes = try Data(contentsOf: root.appendingPathComponent(activeID + ".pcm")).count
  // Independent durable-boundary proof: 3 seconds synced, only 2 committed.
  #expect(fragments.count == 2)
  #expect(spoolBytes == 192_000)
  let recovered = try CaptureMediaWriter.recover(directory: root)
  #expect(recovered.media.durationMs == 2_000)
  #expect(recovered.wasInterrupted)
  #expect(3_000 - recovered.media.durationMs <= 2_000)
  if iteration == 0 {
    print(
      "SIGKILL fixture: \(fragments.count) durable fragments, \(spoolBytes) spool bytes, \(recovered.media.durationMs) ms recovered"
    )
  }
}
