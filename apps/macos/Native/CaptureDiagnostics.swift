// DEBUG-57-CAPTURE: temporary, explicitly opted-in metadata trace. Remove after diagnosis.
import CoreMedia
import Darwin
import Foundation
import Synchronization
import TrigoContracts

enum CaptureDiagnosticEvent: String, Encodable, Sendable {
  case traceStart, traceEnd, shortcutRegistration, hotkeyCallback, eligibility
  case sourceLookup, sourceResult, captureStart, nativeStart, nativeAcknowledged, nativeFailed
  case nativeStop, nativeStopped, streamSelection, microphonePolicy
  case clockArm, clockArmed, clockStart, clockFinish, clockCancel
  case callback, admission, consumeStart, consumeFinish, failure, stop
}

enum CaptureDiagnosticOutcome: String, Encodable, Sendable {
  case accepted, ignored, stale, closed, rejected, bufferLimit, invalidDuration, sourceLimit,
    durationLimit
  case selected, unavailable, failed, complete, preparationLimit, captureLimit, recordLimit,
    byteLimit
  case microphoneUnavailable, applicationFailed
  case captureQueueOverflow, invalidApplicationAudio, captureTimelineFailed, mediaWriteFailed, other

  init(failure: String) {
    switch failure {
    case "capture_queue_overflow": self = .captureQueueOverflow
    case "invalid_application_audio": self = .invalidApplicationAudio
    case "capture_timeline_failed": self = .captureTimelineFailed
    case "media_write_failed": self = .mediaWriteFailed
    case "duration_limit": self = .durationLimit
    default: self = .other
    }
  }
}

/// Only this fixed numeric/enum schema can reach the trace; it has no arbitrary string field.
struct CaptureDiagnosticRecord: Encodable, Sendable {
  var kind: CaptureDiagnosticEvent
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
  var flags: UInt64?
  var code: Int?
  var frontmostPID: Int32?
  var candidateCount: Int?
  var outcome: CaptureDiagnosticOutcome?
  var dropped: Int?

  private enum CodingKeys: String, CodingKey {
    case kind, atNs, role, stream, buffer, frames, rate, channels, formatFlags, bits, validity
    case ptsNs, deliveryNs, durationSeconds, pendingBuffers, sourceSeconds, otherSourceSeconds
    case flags, code, frontmostPID, candidateCount, outcome, dropped
  }
  func encode(to encoder: any Encoder) throws {
    var value = encoder.container(keyedBy: CodingKeys.self)
    try value.encode(kind, forKey: .kind)
    try value.encode(atNs, forKey: .atNs)
    try value.encodeIfPresent(role, forKey: .role)
    try value.encodeIfPresent(stream, forKey: .stream)
    try value.encodeIfPresent(buffer, forKey: .buffer)
    try value.encodeIfPresent(frames, forKey: .frames)
    try value.encodeIfPresent(channels, forKey: .channels)
    try value.encodeIfPresent(formatFlags, forKey: .formatFlags)
    try value.encodeIfPresent(bits, forKey: .bits)
    try value.encodeIfPresent(validity, forKey: .validity)
    if kind == .callback {
      // Null plus validity bits preserves malformed input instead of losing the whole trace.
      try value.encode(rate, forKey: .rate)
      try value.encode(ptsNs, forKey: .ptsNs)
      try value.encode(deliveryNs, forKey: .deliveryNs)
      try value.encode(durationSeconds, forKey: .durationSeconds)
    } else {
      try value.encodeIfPresent(ptsNs, forKey: .ptsNs)
      try value.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    }
    try value.encodeIfPresent(pendingBuffers, forKey: .pendingBuffers)
    try value.encodeIfPresent(sourceSeconds, forKey: .sourceSeconds)
    try value.encodeIfPresent(otherSourceSeconds, forKey: .otherSourceSeconds)
    try value.encodeIfPresent(flags, forKey: .flags)
    try value.encodeIfPresent(code, forKey: .code)
    try value.encodeIfPresent(frontmostPID, forKey: .frontmostPID)
    try value.encodeIfPresent(candidateCount, forKey: .candidateCount)
    try value.encodeIfPresent(outcome, forKey: .outcome)
    try value.encodeIfPresent(dropped, forKey: .dropped)
  }
}

final class CaptureDiagnostics: @unchecked Sendable {
  static let environmentKey = "TRIGO_CAPTURE_DIAGNOSTICS_PATH"
  static let maximumRecords = 8192
  static let maximumBytes = 2 * 1024 * 1024
  static let shared: CaptureDiagnostics? = {
    #if DEBUG
      return fromEnvironment(ProcessInfo.processInfo.environment)
    #else
      return nil
    #endif
  }()

  enum Failure: Error { case invalidDestination, cannotCreate }
  private let origin = DispatchTime.now().uptimeNanoseconds
  private let hostOrigin = CMClockGetTime(CMClockGetHostTimeClock())
  private let lock = NSLock()
  private let closed = Atomic<Bool>(false)
  private let triggered = Atomic<Bool>(false)
  private let dropped = Atomic<Int>(0)
  private let buffers = Atomic<Int>(0)
  private let deadline: Atomic<UInt64>
  private let queue = DispatchQueue(label: "trigo.capture.diagnostic-flush", qos: .utility)
  private let file: FileHandle
  private var timer: DispatchSourceTimer?
  private var records: [CaptureDiagnosticRecord] = []
  private var streams: [ObjectIdentifier] = []

  static func fromEnvironment(_ environment: [String: String]) -> CaptureDiagnostics? {
    guard let path = environment[environmentKey], !path.isEmpty else { return nil }
    do { return try CaptureDiagnostics(path: path) } catch {
      fputs("DEBUG-57-CAPTURE setup_failed\n", stderr)
      return nil
    }
  }

  init(path: String) throws {
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
    deadline = Atomic(origin + 120_000_000_000)
    records.reserveCapacity(Self.maximumRecords - 2)
    streams.reserveCapacity(16)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .seconds(120))
    timer.setEventHandler { [weak self] in self?.finish(.preparationLimit) }
    self.timer = timer
    timer.resume()
    queue.async { [self] in
      // The small start marker distinguishes active preparation from a missing collector.
      if let bytes = try? JSONEncoder().encode(CaptureDiagnosticRecord(kind: .traceStart, code: 1))
      {
        try? file.write(contentsOf: bytes + Data([10]))
      }
    }
  }

  /// First registered hotkey/native Start gets ten seconds, within the total preparation cap.
  func trigger() {
    guard !closed.load(ordering: .relaxed),
      !triggered.exchange(true, ordering: .relaxed)
    else { return }
    let end = min(
      deadline.load(ordering: .relaxed), DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
    deadline.store(end, ordering: .relaxed)
    queue.async { [self] in
      timer?.setEventHandler { [weak self] in self?.finish(.captureLimit) }
      timer?.schedule(deadline: DispatchTime(uptimeNanoseconds: end))
    }
  }

  /// Callbacks only try this reserved-capacity buffer. They never wait or encode/write JSON.
  func record(_ value: CaptureDiagnosticRecord, stream object: ObjectIdentifier? = nil) {
    guard !closed.load(ordering: .relaxed) else { return }
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline.load(ordering: .relaxed) else {
      finish(triggered.load(ordering: .relaxed) ? .captureLimit : .preparationLimit)
      return
    }
    guard lock.try() else {
      _ = dropped.wrappingAdd(1, ordering: .relaxed)
      return
    }
    defer { lock.unlock() }
    guard !closed.load(ordering: .relaxed) else { return }
    guard records.count < Self.maximumRecords - 2 else {
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

  func callback(
    _ sample: CMSampleBuffer, role: MediaSourceRole, stream: ObjectIdentifier,
    deliveredAt: CMTime
  ) -> Int? {
    guard !closed.load(ordering: .relaxed) else { return nil }
    let identifier = buffers.wrappingAdd(1, ordering: .relaxed).newValue
    let format = sample.formatDescription.flatMap {
      CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
    }
    let rate = format?.mSampleRate ?? .nan
    let duration = Double(sample.numSamples) / rate
    // validity: sample=1, ready=2, format=4, finite rate=8, positive rate=16,
    // numeric PTS=32, numeric delivery=64, finite duration=128.
    let validity: UInt16 =
      (sample.isValid ? 1 : 0) | (CMSampleBufferDataIsReady(sample) ? 2 : 0)
      | (format != nil ? 4 : 0) | (rate.isFinite ? 8 : 0) | (rate > 0 ? 16 : 0)
      | (sample.presentationTimeStamp.isNumeric ? 32 : 0) | (deliveredAt.isNumeric ? 64 : 0)
      | (duration.isFinite ? 128 : 0)
    record(
      .init(
        kind: .callback, role: role, buffer: identifier, frames: sample.numSamples,
        rate: rate, channels: format.map { Int($0.mChannelsPerFrame) },
        formatFlags: format?.mFormatFlags, bits: format.map { Int($0.mBitsPerChannel) },
        validity: validity, ptsNs: relative(sample.presentationTimeStamp),
        deliveryNs: relative(deliveredAt), durationSeconds: duration), stream: stream)
    return identifier
  }

  func relative(_ time: CMTime) -> Int64? {
    guard time.isNumeric else { return nil }
    let seconds = CMTimeGetSeconds(CMTimeSubtract(time, hostOrigin))
    guard seconds.isFinite, abs(seconds) <= 86_400 else { return nil }
    return Int64((seconds * 1_000_000_000).rounded())
  }

  func finish(_ outcome: CaptureDiagnosticOutcome = .complete) {
    guard !closed.exchange(true, ordering: .relaxed) else { return }
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
        // Reserve ample space for the initial marker and terminal summary.
        guard bytes.count + encoded.count + 1 <= Self.maximumBytes - 1024 else {
          omitted += 1
          result = .byteLimit
          continue
        }
        bytes.append(encoded)
        bytes.append(10)
      }
      let end = CaptureDiagnosticRecord(
        kind: .traceEnd,
        atNs: DispatchTime.now().uptimeNanoseconds - origin, outcome: result,
        dropped: dropped.load(ordering: .relaxed) + omitted)
      if let encoded = try? encoder.encode(end) {
        bytes.append(encoded)
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
