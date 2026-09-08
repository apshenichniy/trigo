import Foundation
import ScreenCaptureKit
import Testing

@testable import TrigoNative

@MainActor private final class ControlledCaptureTransport: CaptureTransport {
  var pending: CheckedContinuation<Void, any Error>?
  var suspend = false
  var isRunning = false
  private var startObservers: [CheckedContinuation<Void, Never>] = []
  func addCaptureOutput(
    _ output: any SCStreamOutput,
    type: SCStreamOutputType,
    queue: DispatchQueue
  ) throws {}
  func startCapture() async throws {
    if suspend {
      try await withCheckedThrowingContinuation {
        pending = $0
        for observer in startObservers { observer.resume() }
        startObservers = []
      }
    }
    isRunning = true
  }
  func stopForRetirement() async throws { isRunning = false }
  func waitForPendingStart() async {
    guard pending == nil else { return }
    await withCheckedContinuation { startObservers.append($0) }
  }
}

@Test(arguments: [false, true], [false, true]) @MainActor
func stoppedPendingStartCannotAffectTheNextRecording(
  lateFailure: Bool,
  microphoneStart: Bool
)
  async throws
{
  struct Failure: Error {}
  let root = FileManager.default.temporaryDirectory.appendingPathComponent("trigo-start-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  let first = ControlledCaptureTransport()
  first.suspend = true
  let second = ControlledCaptureTransport()
  var transport: ControlledCaptureTransport = first
  let recorder = ScreenCaptureRecording(
    system: .init(
      permissions: { .init(screenAudio: true, microphone: true) },
      filter: { _ in SCContentFilter() },
      microphone: { microphoneStart ? .init(id: "fixture", name: "Fixture") : nil },
      stream: { _, configuration, _ in
        if microphoneStart && !configuration.captureMicrophone {
          return ControlledCaptureTransport()
        }
        return transport
      }
    )
  )
  let source = CaptureSource(
    applicationName: "Fixture",
    bundleID: "test.fixture",
    processID: 123,
    windowID: 456,
    windowTitle: nil,
    processLaunchDate: Date()
  )
  let archiveID = UUID().uuidString.lowercased()
  let attempt = Task { try await recorder.start(root: root, archiveID: archiveID, source: source) }
  await first.waitForPendingStart()
  let pending = try #require(first.pending)
  let firstID = try #require(recorder.session?.callID)
  _ = try await recorder.stop()
  #expect(recorder.phase == .cancellingStart)
  transport = second
  // Stop does not allow a new generation while the old OS start is still pending.
  await #expect(throws: CaptureStartFailure.alreadyRecording) {
    try await recorder.start(root: root, archiveID: archiveID, source: source)
  }
  if lateFailure { pending.resume(throwing: Failure()) } else { pending.resume() }
  _ = await attempt.result
  #expect(!first.isRunning)
  #expect(recorder.phase == .idle)
  transport = second
  try await recorder.start(root: root, archiveID: archiveID, source: source)
  #expect(recorder.phase == .recording)
  #expect(recorder.session?.callID != firstID)
  #expect(second.isRunning)
  _ = try await recorder.stop()
}

@Test @MainActor func facadeRetainsRecoveryBeforeItsFirstDurablePreparationWrite() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-prepare-\(UUID())"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  try Data().write(to: root)
  let recorder = ScreenCaptureRecording(
    system: .init(
      permissions: { .init(screenAudio: true, microphone: true) },
      filter: { _ in SCContentFilter() },
      microphone: { nil },
      stream: { _, _, _ in
        Issue.record("Preparation failure must not open a capture stream")
        return ControlledCaptureTransport()
      }
    )
  )
  let source = CaptureSource(
    applicationName: "Fixture",
    bundleID: "test.fixture",
    processID: 123,
    windowID: 456,
    windowTitle: nil,
    processLaunchDate: Date()
  )
  let archiveID = UUID().uuidString.lowercased()
  await #expect(throws: (any Error).self) {
    try await recorder.start(root: root, archiveID: archiveID, source: source)
  }
  let callID = try #require(recorder.session?.callID)
  #expect(recorder.phase == .needsRecovery(callID: callID))
  await #expect(throws: CaptureStartFailure.alreadyRecording) {
    try await recorder.start(root: root, archiveID: archiveID, source: source)
  }
  try FileManager.default.removeItem(at: root)
  let recovered = try await recorder.retryRecovery()
  #expect(recovered.call.callID == callID)
  #expect(recovered.call.captureState == .interrupted)
  #expect(recovered.call.durationMs == 0)
  #expect(recorder.phase == .idle)
}
