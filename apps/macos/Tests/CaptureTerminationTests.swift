import Darwin
import Foundation
import Testing

@testable import TrigoNative

private final class CaptureTestBundleMarker: NSObject {}
private let captureCrashArchiveID = "00000000-0000-4000-8000-000000000253"

@Test(.enabled(if: ProcessInfo.processInfo.environment["TRIGO_CAPTURE_CRASH_DIRECTORY"] != nil))
func captureTerminationChild() async throws {
  let root = URL(
    fileURLWithPath: try #require(
      ProcessInfo.processInfo.environment["TRIGO_CAPTURE_CRASH_DIRECTORY"]
    )
  )
  var synced = 0
  let session = try await CaptureArchiveSession.begin(
    root: root,
    archiveID: captureCrashArchiveID,
    source: .init(
      applicationName: "Fixture",
      bundleID: "test.kill",
      processID: 123,
      windowID: 456,
      windowTitle: nil,
      processLaunchDate: Date()
    ),
    microphone: nil
  )
  let writer = try CaptureMediaWriter(
    session: session,
    io: .init(event: { point in
      if point == .afterMediaSync {
        synced += 1
        if synced == 3 {
          guard Darwin.kill(Darwin.getpid(), SIGKILL) == 0 else { throw CaptureError.closed }
          while true { Darwin.pause() }
        }
      }
    })
  )
  for _ in 0..<3 { try writer.append(interleaved: Array(repeating: 123, count: 32_000)) }
  Issue.record("Fixture must be killed at the third one-second sync")
}

@Test(arguments: 0..<25)
func forcedProcessTerminationLosesOnlyOneSecondOfUncommittedTail(iteration: Int) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-kill-fixture-\(UUID())"
  )
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
    ["TRIGO_CAPTURE_CRASH_DIRECTORY": root.path],
    uniquingKeysWith: { _, new in new }
  )
  child.standardOutput = FileHandle.nullDevice
  child.standardError = FileHandle.nullDevice
  try child.run()
  child.waitUntilExit()
  #expect(child.terminationReason == .uncaughtSignal)
  #expect(child.terminationStatus == SIGKILL)
  // Discover only the synthetic namespace identity written by the test parent/child.
  let database = try SQLiteDatabase.open(root: root, archiveID: captureCrashArchiveID)
  let repository = try LocalRepository(root: root, archiveID: captureCrashArchiveID)
  let call = try #require(try await repository.calls().first)
  let session = try #require(try await repository.captureSession(callID: call.callID))
  let bytes =
    try
    FileManager.default
    .attributesOfItem(
      atPath: session.mediaDirectory.appendingPathComponent("master.caf").path
    )[.size] as? Int
  #expect(bytes == 192_068)
  #expect(try repository.confirmedMediaCursor(callID: session.callID)?.frames == 32_000)
  let recovered = try await session.recover()
  #expect(recovered.manifest.value.durationMs == 2_000)
  #expect(recovered.manifest.value.captureState == "interrupted")
  #expect(3_000 - (recovered.manifest.value.durationMs ?? 0) <= 2_000)
  _ = database
  if iteration == 0 {
    print(
      "PRODUCTION_SIGKILL durable_frames=32000 media_bytes=192068 recovered_ms=2000 lost_ms=1000"
    )
  }
}
