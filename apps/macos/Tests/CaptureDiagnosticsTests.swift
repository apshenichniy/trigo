// DEBUG-57-CAPTURE: temporary verification for the admitted metadata trace only.
#if DEBUG
  import Foundation
  import ScreenCaptureKit
  import Testing

  @testable import TrigoNative

  private func diagnosticPath() throws -> URL {
    let parent = URL(fileURLWithPath: "/tmp/trigo-epic-48", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return parent.appendingPathComponent("57-capture-diagnosis-test-\(UUID()).jsonl")
  }

  private func diagnosticRows(_ path: URL) throws -> [[String: Any]] {
    try Data(contentsOf: path).split(separator: 10).map {
      try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
  }

  @Test func captureDiagnosticsRequireOptInAndExclusiveScopedDestination() async throws {
    let path = try diagnosticPath()
    let link = try diagnosticPath()
    defer {
      try? FileManager.default.removeItem(at: path)
      try? FileManager.default.removeItem(at: link)
    }
    #expect(CaptureDiagnostics.fromEnvironment([:]) == nil)
    #expect(!FileManager.default.fileExists(atPath: path.path))
    #expect(throws: CaptureDiagnostics.Failure.invalidDestination) {
      try CaptureDiagnostics(path: "/tmp/57-capture-diagnosis-outside.jsonl")
    }
    let collector = try CaptureDiagnostics(path: path.path)
    #expect(throws: CaptureDiagnostics.Failure.cannotCreate) {
      try CaptureDiagnostics(path: path.path)
    }
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
    #expect(throws: CaptureDiagnostics.Failure.cannotCreate) {
      try CaptureDiagnostics(path: link.path)
    }
    collector.finish()
    await collector.waitUntilFlushed()
    let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(try diagnosticRows(path).map { $0["kind"] as? String } == ["traceStart", "traceEnd"])
  }

  @Test func captureDiagnosticsRetainMalformedMetadataAndBoundSerializedOutput() async throws {
    let path = try diagnosticPath()
    defer { try? FileManager.default.removeItem(at: path) }
    let collector = try CaptureDiagnostics(path: path.path)
    collector.trigger()
    collector.record(
      .init(
        kind: .callback, rate: .nan, validity: 0,
        durationSeconds: .infinity))
    for index in 0..<9000 {
      collector.record(
        .init(
          kind: .callback, role: .application, buffer: index, frames: 480,
          rate: 48_000, channels: 2, formatFlags: 41, bits: 32, validity: 255,
          ptsNs: 123_456_789, deliveryNs: 133_456_789, durationSeconds: 0.01,
          pendingBuffers: 100, sourceSeconds: 0.5, otherSourceSeconds: 0.6,
          flags: 4095, code: 123, frontmostPID: 123, candidateCount: 2, outcome: .accepted))
    }
    collector.finish()
    await collector.waitUntilFlushed()
    let bytes = try Data(contentsOf: path)
    let rows = try diagnosticRows(path)
    #expect(bytes.count <= CaptureDiagnostics.maximumBytes)
    #expect(rows.count <= CaptureDiagnostics.maximumRecords)
    let malformed = try #require(rows.first { $0["kind"] as? String == "callback" })
    #expect(malformed["rate"] is NSNull)
    #expect(malformed["durationSeconds"] is NSNull)
    #expect(malformed["ptsNs"] is NSNull)
    #expect(malformed["deliveryNs"] is NSNull)
    #expect(malformed["validity"] as? Int == 0)
    #expect(rows.last?["kind"] as? String == "traceEnd")
    #expect(rows.last?["outcome"] as? String == "byteLimit")
    #expect((rows.last?["dropped"] as? Int ?? 0) > 0)
    let allowed: Set<String> = [
      "kind", "atNs", "role", "stream", "buffer", "frames", "rate", "channels", "formatFlags",
      "bits", "validity", "ptsNs", "deliveryNs", "durationSeconds", "pendingBuffers",
      "sourceSeconds",
      "otherSourceSeconds", "flags", "code", "frontmostPID", "candidateCount", "outcome", "dropped",
    ]
    #expect(rows.allSatisfy { Set($0.keys).isSubset(of: allowed) })
  }

  @Test(arguments: [false, true]) @MainActor
  func captureDiagnosticsFinishWhenPendingStartFailsOrIsCancelled(nativeFailure: Bool) async throws
  {
    let path = try diagnosticPath()
    let root = masterFixtureRoot()
    defer {
      try? FileManager.default.removeItem(at: path)
      try? FileManager.default.removeItem(at: root)
    }
    let collector = try CaptureDiagnostics(path: path.path)
    let application = RecordingTransportFixture()
    application.suspendStart = true
    application.failsAfterStart = nativeFailure
    let recorder = ScreenCaptureRecording(
      system: .init(
        permissions: { .init(screenAudio: true, microphone: true) },
        filter: { _ in SCContentFilter() },
        microphone: { nil }, stream: { _, _, _ in application }), diagnostics: collector)
    let source = CaptureSource(
      applicationName: "Do not log this", bundleID: "do.not.log", processID: 123,
      windowID: 456, windowTitle: "Private title sentinel", processLaunchDate: Date())
    let attempt = Task {
      try await recorder.start(
        root: root, archiveID: UUID().uuidString.lowercased(), source: source)
    }
    await application.waitForStart()
    if !nativeFailure {
      do { _ = try await recorder.stop() } catch {
        application.finishStart()
        _ = await attempt.result
        throw error
      }
    }
    application.finishStart()
    _ = await attempt.result
    await collector.waitUntilFlushed()
    let rows = try diagnosticRows(path)
    let events = rows.compactMap { $0["kind"] as? String }
    #expect(events.contains("captureStart"))
    #expect(events.contains("nativeStart"))
    #expect(events.contains("clockArmed"))
    #expect(events.contains("clockCancel"))
    #expect(events.contains("stop"))
    #expect(events.contains("nativeFailed") == nativeFailure)
    #expect(events.last == "traceEnd")
    #expect(recorder.phase == .idle)
    #expect(!application.running)
    let text = try String(contentsOf: path, encoding: .utf8)
    #expect(!text.contains("Private title sentinel") && !text.contains("do.not.log"))
  }

  @Test func captureDiagnosticsStopAcceptingRowsAtTheTenSecondLimit() async throws {
    let path = try diagnosticPath()
    defer { try? FileManager.default.removeItem(at: path) }
    let collector = try CaptureDiagnostics(path: path.path)
    collector.trigger()
    try await Task.sleep(for: .milliseconds(10_020))
    // The record-side deadline also enforces the cap if the utility timer is delayed.
    collector.record(.init(kind: .clockArm))
    await collector.waitUntilFlushed()
    let rows = try diagnosticRows(path)
    #expect(rows.last?["outcome"] as? String == "captureLimit")
    #expect(!rows.contains { $0["kind"] as? String == "clockArm" })
  }
#endif
