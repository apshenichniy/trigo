import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit
import TrigoContracts

public enum CaptureStreamConfiguration {
  public static func application() -> SCStreamConfiguration {
    make(microphone: nil, application: true)
  }
  public static func microphone(_ device: CaptureMicrophone) -> SCStreamConfiguration {
    make(microphone: device, application: false)
  }
  private static func make(microphone: CaptureMicrophone?, application: Bool)
    -> SCStreamConfiguration
  {
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 3
    configuration.showsCursor = false
    configuration.capturesAudio = application
    configuration.sampleRate = 48_000
    configuration.channelCount = 2
    configuration.excludesCurrentProcessAudio = true
    configuration.captureMicrophone = microphone != nil
    configuration.microphoneCaptureDeviceID = microphone?.id
    return configuration
  }
}

public enum ScreenCapturePhase: Equatable, Sendable {
  case idle, starting, recording, stopping, cancellingStart
  case needsRecovery(callID: String)
}

@MainActor private final class CaptureStartAttempt {
  var cancelled = false
}

/// Production capture facade for #16. It deliberately owns no panels, shortcuts or
/// calling-application controls. Two SCK streams isolate microphone device failure
/// from the pinned application's audio; both feed one serial host-clock timeline.
@MainActor public final class ScreenCaptureRecording {
  public private(set) var session: CaptureArchiveSession?
  public private(set) var snapshot: CaptureRecordingSnapshot?
  public private(set) var phase: ScreenCapturePhase = .idle {
    didSet { onPhaseChange?(phase) }
  }
  public var onPhaseChange: (@MainActor @Sendable (ScreenCapturePhase) -> Void)?
  public var onChange: (@MainActor @Sendable (CaptureRecordingSnapshot) -> Void)?
  public var onFailure: (@MainActor @Sendable (String) -> Void)?
  private var applicationStream: (any CaptureTransport)?
  private var microphoneStream: (any CaptureTransport)?
  private var applicationDelegate: CaptureStreamDelegate?
  private var microphoneDelegate: CaptureStreamDelegate?
  private var filter: SCContentFilter?
  private var sink: CaptureStreamSink?
  private var starting: Bool { phase == .starting }
  private var stopping: Bool { phase == .stopping }
  private var pendingStart: CaptureStartAttempt?
  private var switchingMicrophone = false
  private var retiringMicrophone = false
  private var monitor: Timer?
  private var sleepObserver: NSObjectProtocol?
  private let retirement = CaptureStreamRetirement()
  private let system: CaptureSystem

  public init() {
    system = .init(
      permissions: SystemCaptureSource.permissions, filter: SystemCaptureSource.filter,
      microphone: Self.defaultMicrophone,
      stream: { SCStream(filter: $0, configuration: $1, delegate: $2) })
  }

  init(system: CaptureSystem) { self.system = system }

  /// Permissions and source are resolved before this method acknowledges Recording.
  /// Call SystemCaptureSource.requestPermissions only from an explicit user action.
  public func start(root: URL, archiveID: String, source: CaptureSource) async throws {
    guard phase == .idle, pendingStart == nil, !retirement.hasPending else {
      throw CaptureStartFailure.alreadyRecording
    }
    let attempt = CaptureStartAttempt()
    pendingStart = attempt
    var allocated: CaptureArchiveSession?
    phase = .starting
    defer {
      if pendingStart === attempt {
        pendingStart = nil
        if phase == .starting {
          phase = allocated.map { .needsRecovery(callID: $0.callID) } ?? .idle
        } else if phase == .cancellingStart {
          if retirement.hasPending, let allocated {
            phase = .needsRecovery(callID: allocated.callID)
          } else {
            phase = .idle
          }
        }
      }
    }
    let permission = system.permissions()
    _ = try CaptureSourceResolver.resolve(
      permissions: permission, frontmostPID: source.processID,
      ownPID: ProcessInfo.processInfo.processIdentifier, windows: [source])
    let selectedFilter = try await system.filter(source)
    try checkStart(attempt)
    let microphone = system.microphone()
    let created = try CaptureArchiveSession.allocate(
      root: root, archiveID: archiveID,
      source: source, microphone: microphone)
    session = created
    allocated = created
    // Retain the identity before even the first durable preparation write.
    try await created.prepare()
    try checkStart(attempt)
    filter = selectedFilter
    let output = try CaptureStreamSink(
      directory: created.mediaDirectory,
      queue: system.audioQueue(),
      origin: CMClockGetTime(CMClockGetHostTimeClock()), microphone: microphone,
      onSnapshot: { [weak self] value in
        Task { @MainActor in
          guard self?.session?.callID == created.callID else { return }
          self?.publish(value)
        }
      },
      onMicrophoneFailure: { [weak self] id in
        Task { @MainActor in await self?.microphoneFailed(expectedID: id) }
      },
      onFailure: { [weak self] reason in
        Task { @MainActor in
          guard self?.session?.callID == created.callID else { return }
          await self?.interrupt(reason)
        }
      })
    sink = output
    phase = .starting
    let delegate = CaptureStreamDelegate { [weak self] id in
      Task { @MainActor in
        guard self?.applicationStream.map(ObjectIdentifier.init) == id else { return }
        await self?.interrupt("application_stream_failed")
      }
    }
    applicationDelegate = delegate
    let stream = system.stream(selectedFilter, CaptureStreamConfiguration.application(), delegate)
    applicationStream = stream
    output.acceptApplicationStream(stream)
    do {
      try stream.addCaptureOutput(output, type: .audio, queue: output.queue)
      // No .screen output and no SCRecordingOutput: pixels never reach persistence.
      try checkStart(attempt)
      try await stream.startCapture()
      try checkStart(attempt)
      if let microphone { await replaceMicrophone(microphone) }
      try checkStart(attempt)
      output.startClock()
      let value = try await output.perform { $0.snapshot }
      try checkStart(attempt)
      publish(value)
      phase = .recording
      beginMonitoring()
    } catch {
      if session?.callID == created.callID, sink === output {
        _ = try? await stop(reason: "capture_start_failed")
      }
      // Stop may have completed before the OS acknowledged this Start. Retire
      // that exact transport again after its late success, never another call.
      do { try await retirement.retire(stream) } catch {
        if session?.callID == created.callID { phase = .needsRecovery(callID: created.callID) }
      }
      throw error
    }
  }

  private func checkStart(_ attempt: CaptureStartAttempt) throws {
    guard pendingStart === attempt, !attempt.cancelled, !Task.isCancelled else {
      throw CancellationError()
    }
  }

  /// Returns only after microphone policy is effective on the audio/persistence queue.
  public func setMicrophoneEnabled(_ enabled: Bool) async throws {
    guard let sink, owns(sink) else { throw CaptureError.closed }
    let value = try await sink.perform { engine in
      try engine.setMicrophoneEnabled(enabled, at: CMClockGetTime(CMClockGetHostTimeClock()))
      return engine.snapshot
    }
    guard owns(sink) else { throw CaptureError.closed }
    publish(value)
  }

  @discardableResult public func stop(reason: String? = nil) async throws -> LocalCallAggregate? {
    try requireCaptureInterruptionReason(reason)
    pendingStart?.cancelled = true
    guard !stopping, let output = sink, let session else { return nil }
    phase = .stopping
    defer {
      if phase == .stopping { phase = .needsRecovery(callID: session.callID) }
      sink = nil
      filter = nil
      applicationDelegate = nil
      microphoneDelegate = nil
    }
    monitor?.invalidate()
    monitor = nil
    if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    sleepObserver = nil
    output.stopClock()
    let endedAt = CMClockGetTime(CMClockGetHostTimeClock())
    let application = applicationStream
    let microphone = microphoneStream
    applicationStream = nil
    microphoneStream = nil
    if let microphone { try? await retirement.retire(microphone) }
    if let application { try? await retirement.retire(application) }
    // Preserve a known stop cause before crossing the external media sealing boundary.
    if let reason { try await session.requestStop(reason: reason) }
    let result = try await output.perform { engine in
      let media = try engine.stop(at: endedAt, reason: reason)
      return (media, engine.snapshot)
    }
    publish(result.1)
    sink = nil
    filter = nil
    applicationDelegate = nil
    microphoneDelegate = nil
    let aggregate = try await session.finish(
      media: result.0, interruptionReason: result.1.interruptionReason)
    try await retirement.retryAll()
    phase = pendingStart == nil ? .idle : .cancellingStart
    return aggregate
  }

  /// A failed finalization retains its session and blocks new capture until explicitly recovered.
  @discardableResult public func retryRecovery() async throws -> LocalCallAggregate {
    guard pendingStart == nil, case .needsRecovery(let callID) = phase,
      let session, session.callID == callID
    else {
      throw CaptureError.closed
    }
    phase = .stopping
    defer { if phase == .stopping { phase = .needsRecovery(callID: callID) } }
    try await retirement.retryAll()
    let aggregate = try await session.recover()
    phase = .idle
    return aggregate
  }

  private func interrupt(_ reason: String) async {
    guard !stopping else { return }
    let callID = session?.callID
    do { _ = try await stop(reason: reason) } catch {
      guard session?.callID == callID else { return }
      onFailure?("capture_finalization_failed")
    }
    guard session?.callID == callID else { return }
    onFailure?(reason)
  }

  private func publish(_ value: CaptureRecordingSnapshot) {
    // A late timer task must not replace a terminal snapshot with Recording.
    if snapshot?.state != .recording && snapshot != nil && value.state == .recording && !starting {
      return
    }
    snapshot = value
    onChange?(value)
  }

  private func beginMonitoring() {
    let callID = session?.callID
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard self?.session?.callID == callID else { return }
        await self?.interrupt("system_sleep")
      }
    }
    monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard self?.session?.callID == callID else { return }
        await self?.checkSourceAndMicrophone()
      }
    }
  }

  private func owns(_ output: CaptureStreamSink) -> Bool {
    sink === output && (phase == .starting || phase == .recording)
      && pendingStart?.cancelled != true
  }

  private func checkSourceAndMicrophone() async {
    guard !stopping, let source = session?.source, applicationStream != nil else { return }
    guard system.sourceIsAvailable(source) else {
      await interrupt("source_exited")
      return
    }
    if snapshot?.elapsedMs ?? 0 >= 10_800_000 {
      await interrupt("duration_limit")
      return
    }
    let current = system.microphone()
    if current != snapshot?.microphone || (current != nil && microphoneStream == nil) {
      await replaceMicrophone(current)
    }
  }

  private func replaceMicrophone(_ device: CaptureMicrophone?) async {
    guard !switchingMicrophone, !retiringMicrophone, let output = sink, owns(output), let filter
    else {
      return
    }
    switchingMicrophone = true
    defer { switchingMicrophone = false }
    let previous = microphoneStream
    microphoneStream = nil
    output.acceptMicrophoneStream(nil)
    var replacement: (any CaptureTransport)?
    do {
      if let previous { try await retirement.retire(previous) }
      guard owns(output) else { return }
      try await retirement.retryAll()
      guard owns(output) else { return }
      let unavailable = try await output.perform { engine in
        try engine.microphoneChanged(nil, at: CMClockGetTime(CMClockGetHostTimeClock()))
        return engine.snapshot
      }
      guard owns(output) else { return }
      publish(unavailable)
      guard let device, applicationStream != nil else { return }
      let delegate = CaptureStreamDelegate { [weak self] id in
        Task { @MainActor in await self?.microphoneFailed(expectedID: id) }
      }
      microphoneDelegate = delegate
      let stream = system.stream(filter, CaptureStreamConfiguration.microphone(device), delegate)
      replacement = stream
      microphoneStream = stream
      try stream.addCaptureOutput(output, type: .microphone, queue: output.queue)
      output.acceptMicrophoneStream(stream)
      try await stream.startCapture()
      guard owns(output), microphoneStream.map(ObjectIdentifier.init) == ObjectIdentifier(stream)
      else {
        try await retirement.retire(stream)
        return
      }
      // Availability is acknowledged only by this stream's successful native Start.
      // Samples arriving before acknowledgement remain suppressed by the unavailable engine.
      let available = try await output.perform { engine in
        try engine.microphoneChanged(device, at: CMClockGetTime(CMClockGetHostTimeClock()))
        return engine.snapshot
      }
      guard owns(output), microphoneStream.map(ObjectIdentifier.init) == ObjectIdentifier(stream)
      else {
        try await retirement.retire(stream)
        return
      }
      publish(available)
    } catch {
      if let replacement { try? await retirement.retire(replacement) }
      guard owns(output) else { return }
      await microphoneFailed(expectedID: replacement.map(ObjectIdentifier.init))
    }
  }

  private func microphoneFailed(expectedID: ObjectIdentifier? = nil) async {
    guard let sink, owns(sink), !retiringMicrophone else { return }
    if let expectedID, microphoneStream.map(ObjectIdentifier.init) != expectedID { return }
    let failedStream = microphoneStream
    microphoneStream = nil
    sink.acceptMicrophoneStream(nil)
    // Keep ownership until stop completes; no replacement can overlap this retirement.
    retiringMicrophone = true
    defer { retiringMicrophone = false }
    if let failedStream { try? await retirement.retire(failedStream) }
    guard owns(sink) else { return }
    if let value = try? await sink.perform({ engine in
      try engine.microphoneChanged(nil, at: CMClockGetTime(CMClockGetHostTimeClock()))
      return engine.snapshot
    }) {
      guard owns(sink) else { return }
      publish(value)
    }
    onFailure?("microphone_unavailable")
  }

  private static func defaultMicrophone() -> CaptureMicrophone? {
    guard let device = AVCaptureDevice.default(for: .audio), device.isConnected else { return nil }
    return .init(id: device.uniqueID, name: device.localizedName)
  }
}

private final class CaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
  private let failure: @Sendable (ObjectIdentifier) -> Void
  init(failure: @escaping @Sendable (ObjectIdentifier) -> Void) { self.failure = failure }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    failure(ObjectIdentifier(stream))
  }
}

/// All mutable engine/stream-admission state is confined to queue. No Task is created per audio buffer.
private final class CaptureStreamSink: NSObject, SCStreamOutput, @unchecked Sendable {
  let queue: DispatchQueue
  private let engine: CaptureRecordingEngine
  private let routing: CaptureAudioRouting
  private var timer: DispatchSourceTimer?
  private var failed = false
  private let onSnapshot: @Sendable (CaptureRecordingSnapshot) -> Void
  private let onFailure: @Sendable (String) -> Void
  private let onMicrophoneFailure: @Sendable (ObjectIdentifier) -> Void

  init(
    directory: URL, queue: DispatchQueue, origin: CMTime, microphone: CaptureMicrophone?,
    onSnapshot: @escaping @Sendable (CaptureRecordingSnapshot) -> Void,
    onMicrophoneFailure: @escaping @Sendable (ObjectIdentifier) -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) throws {
    self.queue = queue
    engine = try CaptureRecordingEngine(
      directory: directory, origin: origin, microphone: microphone)
    routing = CaptureAudioRouting(engine: engine)
    self.onSnapshot = onSnapshot
    self.onMicrophoneFailure = onMicrophoneFailure
    self.onFailure = onFailure
  }

  func perform<T: Sendable>(_ body: @escaping @Sendable (CaptureRecordingEngine) throws -> T)
    async throws -> T
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [self] in
        do { continuation.resume(returning: try body(engine)) } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func acceptMicrophoneStream(_ stream: (any CaptureTransport)?) {
    let id = stream.map(ObjectIdentifier.init)
    queue.async { [self] in routing.select(id, for: .microphone) }
  }

  func acceptApplicationStream(_ stream: (any CaptureTransport)?) {
    let id = stream.map(ObjectIdentifier.init)
    queue.async { [self] in routing.select(id, for: .application) }
  }

  func startClock() {
    queue.async { [self] in
      let clock = DispatchSource.makeTimerSource(queue: queue)
      clock.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(25))
      clock.setEventHandler { [weak self] in
        guard let self, !failed else { return }
        do {
          try engine.advance(at: CMClockGetTime(CMClockGetHostTimeClock()))
          onSnapshot(engine.snapshot)
        } catch CaptureError.durationLimit { fail("duration_limit") } catch {
          fail(error is CaptureError ? "capture_timeline_failed" : "media_write_failed")
        }
      }
      timer = clock
      clock.resume()
    }
  }

  func stopClock() {
    queue.async { [self] in
      timer?.cancel()
      timer = nil
    }
  }

  func stream(
    _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !failed else { return }
    let role: MediaSourceRole
    switch type {
    case .audio: role = .application
    case .microphone:
      role = .microphone
    default: return  // Screen/video samples are never decoded or persisted.
    }
    switch routing.receive(
      sampleBuffer, role: role, streamID: ObjectIdentifier(stream),
      at: CMClockGetTime(CMClockGetHostTimeClock()))
    {
    case .accepted, .ignored: break
    case .microphoneUnavailable: onMicrophoneFailure(ObjectIdentifier(stream))
    case .applicationFailed: fail("invalid_application_audio")
    }
  }

  private func fail(_ reason: String) {
    guard !failed else { return }
    failed = true
    timer?.cancel()
    timer = nil
    onFailure(reason)
  }
}
