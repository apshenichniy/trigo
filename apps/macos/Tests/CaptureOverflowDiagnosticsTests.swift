// TEMP-57-OVERFLOW: diagnostic isolation, capacity, and phase-attribution checks.
#if DEBUG
  import CoreMedia
  import Darwin
  import Foundation
  import Testing

  @testable import TrigoNative

  private func overflowTracePath() -> String {
    "/tmp/trigo-epic-48/57-capture-diagnosis-unit-\(UUID()).jsonl"
  }

  private func overflowTraceRows(_ path: String) throws -> [[String: Any]] {
    try Data(contentsOf: URL(fileURLWithPath: path)).split(separator: 10).map {
      try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
  }

  @Test func overflowTraceRequiresExplicitOptInAndTargetsOneAttempt() async throws {
    let path = overflowTracePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(CaptureOverflowDiagnostics.fromEnvironment([:], attempt: 1) == nil)
    for target in ["", "0", "9", "-1", "1.5", "secret"] {
      #expect(
        CaptureOverflowDiagnostics.fromEnvironment(
          [
            CaptureOverflowDiagnostics.environmentKey: path,
            CaptureOverflowDiagnostics.attemptKey: target,
          ], attempt: 1) == nil)
    }
    let environment = [
      CaptureOverflowDiagnostics.environmentKey: path,
      CaptureOverflowDiagnostics.attemptKey: "2",
    ]
    #expect(CaptureOverflowDiagnostics.fromEnvironment(environment, attempt: 1) == nil)
    #expect(!FileManager.default.fileExists(atPath: path))
    let trace = try #require(CaptureOverflowDiagnostics.fromEnvironment(environment, attempt: 2))
    #expect(CaptureOverflowDiagnostics.fromEnvironment(environment, attempt: 3) == nil)
    trace.record(
      .init(
        kind: .admission, rate: .nan, validity: 0,
        durationSeconds: .infinity, sourceSeconds: .nan))
    trace.finish()
    await trace.waitUntilFlushed()
    let rows = try overflowTraceRows(path)
    #expect(rows.count == 3)
    #expect(rows[0]["kind"] as? String == "traceStart")
    #expect(rows[0]["attempt"] as? Int == 2)
    #expect(rows[0]["skippedAttempts"] as? Int == 1)
    for key in ["rate", "ptsNs", "deliveryNs", "durationSeconds"] {
      #expect(rows[1][key] is NSNull)
    }
    #expect(rows[1]["validity"] as? Int == 0)
    #expect(rows[2]["dropped"] as? Int == 0)
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    // Exclusive creation must never truncate an existing diagnostic file.
    #expect(CaptureOverflowDiagnostics.fromEnvironment(environment, attempt: 2) == nil)
    #expect(try overflowTraceRows(path).count == 3)
    for invalid in [
      "relative.jsonl", "/tmp/57-capture-diagnosis-outside.jsonl",
      "/tmp/trigo-epic-48/private.jsonl",
    ] {
      #expect(throws: CaptureOverflowDiagnostics.Failure.self) {
        _ = try CaptureOverflowDiagnostics(path: invalid)
      }
    }
    let symlink = overflowTracePath()
    defer { try? FileManager.default.removeItem(atPath: symlink) }
    try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: path)
    #expect(throws: CaptureOverflowDiagnostics.Failure.self) {
      _ = try CaptureOverflowDiagnostics(path: symlink)
    }
    #expect(try overflowTraceRows(path).count == 3)
  }

  @Test func overflowTraceRecordsTheCapacityBoundaryAndOneTerminalMarker() async throws {
    let path = overflowTracePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let trace = try CaptureOverflowDiagnostics(path: path)
    for _ in 0..<9000 { trace.record(.init(kind: .clockStart)) }
    trace.finish()
    await trace.waitUntilFlushed()
    let rows = try overflowTraceRows(path)
    #expect(rows.count == CaptureOverflowDiagnostics.maximumRecords)
    #expect(rows.filter { $0["kind"] as? String == "traceEnd" }.count == 1)
    #expect(rows.last?["outcome"] as? String == "recordLimit")
    #expect((rows.last?["dropped"] as? Int ?? 0) > 0)
    #expect(
      try Data(contentsOf: URL(fileURLWithPath: path)).count
        <= CaptureOverflowDiagnostics.maximumBytes)
  }

  @Test func overflowTraceByteCapPreservesAnExplicitTruncationMarker() async throws {
    let path = overflowTracePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let trace = try CaptureOverflowDiagnostics(path: path)
    for _ in 0..<9000 {
      trace.record(
        .init(
          kind: .admission, role: .microphone, stream: Int.max,
          buffer: Int.max, frames: Int.max, rate: Double.greatestFiniteMagnitude,
          channels: Int.max, formatFlags: UInt32.max, bits: Int.max, validity: UInt16.max,
          ptsNs: Int64.max, deliveryNs: Int64.max, durationSeconds: Double.greatestFiniteMagnitude,
          pendingBuffers: Int.max, sourceSeconds: Double.greatestFiniteMagnitude,
          otherSourceSeconds: Double.greatestFiniteMagnitude, code: Int.max,
          attempt: Int.max, skippedAttempts: Int.max, outcome: .accepted))
    }
    trace.finish()
    await trace.waitUntilFlushed()
    let rows = try overflowTraceRows(path)
    #expect(rows.count < CaptureOverflowDiagnostics.maximumRecords)
    #expect(rows.first?["kind"] as? String == "traceStart")
    #expect(rows.last?["outcome"] as? String == "byteLimit")
    #expect((rows.last?["dropped"] as? Int ?? 0) > 0)
    #expect(
      try Data(contentsOf: URL(fileURLWithPath: path)).count
        <= CaptureOverflowDiagnostics.maximumBytes)
  }

  @Test func overflowTraceEnforcesTheTenSecondDeadlineWithoutAnotherEvent() async throws {
    let path = overflowTracePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let trace = try CaptureOverflowDiagnostics(path: path)
    trace.record(.init(kind: .clockStart))
    try await Task.sleep(for: .milliseconds(10_100))
    await trace.waitUntilFlushed()
    trace.record(.init(kind: .clockFinish))
    trace.finish()
    await trace.waitUntilFlushed()
    let rows = try overflowTraceRows(path)
    #expect(rows.count == 3)
    #expect(rows.last?["outcome"] as? String == "captureLimit")
    #expect((rows.last?["atNs"] as? UInt64 ?? 0) >= 10_000_000_000)
    #expect(
      rows.dropFirst().dropLast().allSatisfy {
        ($0["atNs"] as? UInt64 ?? .max) < 10_000_000_000
      })
  }

  @Test @MainActor func overflowTraceSeparatesMasterSyncDelayFromSQLitePublication() async throws {
    let root = masterFixtureRoot()
    let path = overflowTracePath()
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(atPath: path)
    }
    let session = try repositorySession(root)
    try await session.prepare()
    let trace = try CaptureOverflowDiagnostics(path: path)
    let writer = try CaptureMediaWriter(
      session: session,
      io: MediaMasterIO(event: { point in
        if point == .beforeMediaSync { Thread.sleep(forTimeInterval: 0.15) }
      }))
    writer.diagnostics = trace
    try writer.append(interleaved: Array(repeating: 1024, count: 3200))
    trace.finish()
    await trace.waitUntilFlushed()
    let rows = try overflowTraceRows(path)
    let start = try #require(
      rows.first { $0["kind"] as? String == "writerStart" }?["atNs"] as? UInt64)
    let master = try #require(
      rows.first { $0["kind"] as? String == "masterAppendFinish" }?["atNs"] as? UInt64)
    let sqlite = try #require(
      rows.first { $0["kind"] as? String == "sqliteCommitFinish" }?["atNs"] as? UInt64)
    #expect(master - start >= 150_000_000)
    #expect(sqlite >= master)
    #expect(rows.last?["dropped"] as? Int == 0)
  }

  @Test func overflowTraceAccountsForSelectionDiscardAndAnInFlightBatch() async throws {
    let path = overflowTracePath()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let trace = try CaptureOverflowDiagnostics(path: path)
    let queue = DispatchQueue(label: "trigo.test.overflow-trace-accounting")
    let release = DispatchSemaphore(value: 0)
    let signal = AsyncStream<Void>.makeStream()
    let old = NSObject()
    let current = NSObject()
    let oldID = ObjectIdentifier(old)
    let newID = ObjectIdentifier(current)
    let ingress = CaptureAudioIngress(
      queue: queue,
      consume: { audio in
        if audio.diagnosticBuffer == 1 {
          signal.continuation.yield()
          release.wait()
        }
      }, overflow: { Issue.record("Unexpected overload") })
    ingress.diagnostics = trace
    ingress.select(oldID, for: .microphone)
    let sample = try controlledAudioBuffer(
      sampleRate: 48_000, frames: 960, time: .zero, value: 0.25)
    queue.suspend()
    for _ in 0..<16 {
      #expect(ingress.submit(sample, role: .microphone, streamID: oldID, deliveredAt: .zero))
    }
    queue.resume()
    for await _ in signal.stream { break }
    ingress.select(newID, for: .microphone)
    for _ in 0..<16 {
      #expect(ingress.submit(sample, role: .microphone, streamID: newID, deliveredAt: .zero))
    }
    release.signal()
    await withCheckedContinuation { continuation in
      queue.async {
        ingress.finishPending()
        continuation.resume()
      }
    }
    trace.finish()
    await trace.waitUntilFlushed()
    let rows = try overflowTraceRows(path)
    #expect(rows.last?["dropped"] as? Int == 0)
    var live = Set<Int>()
    var seconds = 0.0
    for row in rows {
      let kind = row["kind"] as? String
      if kind == "admission", row["outcome"] as? String == "accepted" {
        #expect(live.insert(try #require(row["buffer"] as? Int)).inserted)
        seconds += try #require(row["durationSeconds"] as? Double)
      } else if kind == "discard" || kind == "consumeFinish" {
        #expect(live.remove(try #require(row["buffer"] as? Int)) != nil)
        seconds -= try #require(row["durationSeconds"] as? Double)
      } else {
        continue
      }
      #expect(row["pendingBuffers"] as? Int == live.count)
      #expect(abs(try #require(row["sourceSeconds"] as? Double) - seconds) < 0.000_001)
    }
    #expect(rows.filter { $0["kind"] as? String == "discard" }.count == 8)
    #expect(live.isEmpty)
    #expect(ingress.statistics.pendingBuffers == 0)
  }
#endif
