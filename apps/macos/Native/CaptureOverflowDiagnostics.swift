// TEMP-57-OVERFLOW: remove this file and tagged sites after the bounded diagnosis.
#if DEBUG
  import CoreMedia
  import Darwin
  import Foundation
  import Synchronization
  import TrigoContracts

  enum CaptureOverflowEvent: String, Encodable, Sendable {
    case traceStart, traceEnd, admission, consumeStart, decodeFinish, consumeFinish, discard
    case clockStart, clockFinish, writerStart, masterAppendFinish, sqliteCommitFinish, writerFailed
    case nativeStart, nativeAcknowledged, streamSelection, microphonePolicy, stop, failure
  }

  enum CaptureOverflowOutcome: String, Encodable, Sendable {
    case accepted, stale, closed, rejected, bufferLimit, invalidDuration, sourceLimit
    case complete, captureLimit, recordLimit, byteLimit
    case captureQueueOverflow, invalidApplicationAudio, captureTimelineFailed, mediaWriteFailed,
      other
    init(failure: String) {
      switch failure {
      case "capture_queue_overflow": self = .captureQueueOverflow
      case "invalid_application_audio": self = .invalidApplicationAudio
      case "capture_timeline_failed": self = .captureTimelineFailed
      case "media_write_failed": self = .mediaWriteFailed
      default: self = .other
      }
    }
  }

  /// Fixed enum/numeric schema. No payload, identity, free-form text, or arbitrary error.
  struct CaptureOverflowRecord: Encodable, Sendable {
    var kind: CaptureOverflowEvent
    var atNs: UInt64 = 0
    var role: MediaSourceRole?
    var stream: Int?
    var buffer: Int?
    var frames: Int?
    var rate: Double?
    var channels: Int?
    var formatFlags: UInt32?
    var bits: Int?
    var validity: UInt16?
    var ptsNs: Int64?
    var deliveryNs: Int64?
    var durationSeconds: Double?
    var pendingBuffers: Int?
    var sourceSeconds: Double?
    var otherSourceSeconds: Double?
    var code: Int?
    var attempt: Int?
    var skippedAttempts: Int?
    var outcome: CaptureOverflowOutcome?
    var dropped: Int?

    private enum CodingKeys: String, CodingKey {
      case kind, atNs, role, stream, buffer, frames, rate, channels, formatFlags, bits, validity,
        ptsNs, deliveryNs, durationSeconds, pendingBuffers, sourceSeconds, otherSourceSeconds, code,
        attempt, skippedAttempts, outcome, dropped
    }
    func encode(to encoder: any Encoder) throws {
      var value = encoder.container(keyedBy: CodingKeys.self)
      try value.encode(kind, forKey: .kind)
      try value.encode(atNs, forKey: .atNs)
      try value.encodeIfPresent(role, forKey: .role)
      try value.encodeIfPresent(stream, forKey: .stream)
      try value.encodeIfPresent(buffer, forKey: .buffer)
      try value.encodeIfPresent(frames, forKey: .frames)
      if kind == .admission {
        try value.encode(rate, forKey: .rate)
      } else {
        try value.encodeIfPresent(rate, forKey: .rate)
      }
      try value.encodeIfPresent(channels, forKey: .channels)
      try value.encodeIfPresent(formatFlags, forKey: .formatFlags)
      try value.encodeIfPresent(bits, forKey: .bits)
      try value.encodeIfPresent(validity, forKey: .validity)
      if kind == .admission {
        try value.encode(ptsNs, forKey: .ptsNs)
      } else {
        try value.encodeIfPresent(ptsNs, forKey: .ptsNs)
      }
      if kind == .admission {
        try value.encode(deliveryNs, forKey: .deliveryNs)
      } else {
        try value.encodeIfPresent(deliveryNs, forKey: .deliveryNs)
      }
      if kind == .admission {
        try value.encode(durationSeconds, forKey: .durationSeconds)
      } else {
        try value.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
      }
      try value.encodeIfPresent(pendingBuffers, forKey: .pendingBuffers)
      try value.encodeIfPresent(sourceSeconds, forKey: .sourceSeconds)
      try value.encodeIfPresent(otherSourceSeconds, forKey: .otherSourceSeconds)
      try value.encodeIfPresent(code, forKey: .code)
      try value.encodeIfPresent(attempt, forKey: .attempt)
      try value.encodeIfPresent(skippedAttempts, forKey: .skippedAttempts)
      try value.encodeIfPresent(outcome, forKey: .outcome)
      try value.encodeIfPresent(dropped, forKey: .dropped)
    }
  }

  final class CaptureOverflowDiagnostics: @unchecked Sendable {
    static let environmentKey = "TRIGO_CAPTURE_DIAGNOSTICS_PATH"
    static let attemptKey = "TRIGO_CAPTURE_DIAGNOSTICS_ATTEMPT"
    static let maximumRecords = 8192
    static let maximumBytes = 2 * 1024 * 1024
    private static let attempts = Atomic<Int>(0)
    enum Failure: Error { case invalidDestination, cannotCreate }
    private let origin = DispatchTime.now().uptimeNanoseconds
    private let hostOrigin = CMClockGetTime(CMClockGetHostTimeClock())
    private let lock = NSLock()
    private let closed = Atomic<Bool>(false)
    private let dropped = Atomic<Int>(0)
    private let buffers = Atomic<Int>(0)
    private let queue = DispatchQueue(label: "trigo.capture.overflow-trace", qos: .utility)
    private let file: FileHandle
    private var timer: DispatchSourceTimer?
    private var records: [CaptureOverflowRecord] = []
    private var streams: [ObjectIdentifier] = []

    /// Only eligible facade starts count. The trace explicitly excludes all earlier attempts.
    static func nextAttempt() -> CaptureOverflowDiagnostics? {
      let environment = ProcessInfo.processInfo.environment
      guard environment[environmentKey] != nil else { return nil }
      return fromEnvironment(
        environment, attempt: attempts.wrappingAdd(1, ordering: .relaxed).newValue)
    }

    static func fromEnvironment(_ environment: [String: String], attempt: Int)
      -> CaptureOverflowDiagnostics?
    {
      let targetText = environment[attemptKey] ?? "1"
      guard !targetText.isEmpty, targetText.utf8.allSatisfy({ (48...57).contains($0) }),
        let target = Int(targetText), (1...8).contains(target), attempt == target,
        let path = environment[environmentKey], !path.isEmpty
      else { return nil }
      return try? CaptureOverflowDiagnostics(path: path, attempt: attempt)
    }

    init(path: String, attempt: Int = 1) throws {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      let parent = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath()
        .appendingPathComponent("trigo-epic-48", isDirectory: true)
      let name = url.lastPathComponent
      guard path.hasPrefix("/"),
        url.deletingLastPathComponent().resolvingSymlinksInPath() == parent,
        name.hasPrefix("57-capture-diagnosis-"), name.hasSuffix(".jsonl"),
        name.utf8.allSatisfy({
          (45...57).contains($0) || (65...90).contains($0)
            || (97...122).contains($0) || $0 == 95
        })
      else { throw Failure.invalidDestination }
      let directory = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard directory >= 0 else { throw Failure.cannotCreate }
      defer { Darwin.close(directory) }
      let descriptor = Darwin.openat(
        directory, name,
        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      guard descriptor >= 0 else { throw Failure.cannotCreate }
      file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
      records.reserveCapacity(Self.maximumRecords - 1)
      streams.reserveCapacity(16)
      records.append(
        .init(
          kind: .traceStart, code: 2, attempt: attempt,
          skippedAttempts: attempt - 1))
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: DispatchTime(uptimeNanoseconds: origin + 10_000_000_000))
      timer.setEventHandler { [self] in finish(.captureLimit) }
      self.timer = timer
      timer.resume()
    }

    /// Callback work is bounded and never waits, encodes JSON, or touches the filesystem.
    func record(_ value: CaptureOverflowRecord, stream object: ObjectIdentifier? = nil) {
      guard !closed.load(ordering: .relaxed) else { return }
      let now = DispatchTime.now().uptimeNanoseconds
      guard now - origin < 10_000_000_000 else {
        finish(.captureLimit)
        return
      }
      guard lock.try() else {
        _ = dropped.wrappingAdd(1, ordering: .relaxed)
        return
      }
      defer { lock.unlock() }
      guard !closed.load(ordering: .relaxed) else { return }
      guard records.count < Self.maximumRecords - 1 else {
        _ = dropped.wrappingAdd(1, ordering: .relaxed)
        finish(.recordLimit)
        return
      }
      var value = value
      value.atNs = now - origin
      value.rate = value.rate.flatMap { $0.isFinite ? $0 : nil }
      value.durationSeconds = value.durationSeconds.flatMap { $0.isFinite ? $0 : nil }
      value.sourceSeconds = value.sourceSeconds.flatMap { $0.isFinite ? $0 : nil }
      value.otherSourceSeconds = value.otherSourceSeconds.flatMap { $0.isFinite ? $0 : nil }
      if let object {
        if let index = streams.firstIndex(of: object) {
          value.stream = index + 1
        } else if streams.count < 16 {
          streams.append(object)
          value.stream = streams.count
        }
      }
      records.append(value)
    }

    func nextBuffer() -> Int? {
      closed.load(ordering: .relaxed) ? nil : buffers.wrappingAdd(1, ordering: .relaxed).newValue
    }

    func admission(
      _ audio: CaptureQueuedAudio, outcome: CaptureOverflowOutcome,
      pending: Int, source: Double, other: Double
    ) {
      guard let identifier = audio.diagnosticBuffer else { return }
      let sample = audio.sample
      let format = sample.formatDescription.flatMap {
        CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
      }
      let rate = format?.mSampleRate ?? .nan
      let duration = Double(sample.numSamples) / rate
      // sample=1, ready=2, format=4, finite rate=8, positive rate=16,
      // numeric PTS=32, numeric delivery=64, finite duration=128.
      let validity: UInt16 =
        (sample.isValid ? 1 : 0)
        | (CMSampleBufferDataIsReady(sample) ? 2 : 0) | (format != nil ? 4 : 0)
        | (rate.isFinite ? 8 : 0) | (rate > 0 ? 16 : 0)
        | (sample.presentationTimeStamp.isNumeric ? 32 : 0)
        | (audio.deliveredAt.isNumeric ? 64 : 0) | (duration.isFinite ? 128 : 0)
      record(
        .init(
          kind: .admission, role: audio.role, buffer: identifier,
          frames: sample.numSamples, rate: rate, channels: format.map { Int($0.mChannelsPerFrame) },
          formatFlags: format?.mFormatFlags, bits: format.map { Int($0.mBitsPerChannel) },
          validity: validity, ptsNs: relative(sample.presentationTimeStamp),
          deliveryNs: relative(audio.deliveredAt), durationSeconds: duration,
          pendingBuffers: pending, sourceSeconds: source, otherSourceSeconds: other,
          outcome: outcome), stream: audio.streamID)
    }

    func relative(_ time: CMTime) -> Int64? {
      guard time.isNumeric else { return nil }
      let seconds = CMTimeGetSeconds(CMTimeSubtract(time, hostOrigin))
      guard seconds.isFinite, abs(seconds) <= 86_400 else { return nil }
      return Int64((seconds * 1_000_000_000).rounded())
    }

    func finish(_ outcome: CaptureOverflowOutcome = .complete) {
      guard !closed.exchange(true, ordering: .relaxed) else { return }
      let endedAt = DispatchTime.now().uptimeNanoseconds - origin
      queue.async { [self] in
        timer?.cancel()
        timer = nil
        let captured = lock.withLock {
          let result = records
          records = []
          return result
        }
        let encoder = JSONEncoder()
        var bytes = Data()
        var omitted = 0
        var result = outcome
        for record in captured {
          guard let encoded = try? encoder.encode(record) else {
            omitted += 1
            continue
          }
          guard bytes.count + encoded.count + 1 <= Self.maximumBytes - 512 else {
            omitted += 1
            result = .byteLimit
            continue
          }
          bytes.append(encoded)
          bytes.append(10)
        }
        if let end = try? encoder.encode(
          CaptureOverflowRecord(
            kind: .traceEnd,
            atNs: endedAt, outcome: result, dropped: dropped.load(ordering: .relaxed) + omitted))
        {
          bytes.append(end)
          bytes.append(10)
        }
        try? file.write(contentsOf: bytes)
        try? file.close()
      }
    }

    func waitUntilFlushed() async {
      await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
  }
#endif
