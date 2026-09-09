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
  private static func make(
    microphone: CaptureMicrophone?,
    application: Bool
  )
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
  public private(set) var finalization = CaptureFinalizationState() {
    didSet { onFinalizationChange?(finalization) }
  }
  public private(set) var phase: ScreenCapturePhase = .idle {
    didSet { onPhaseChange?(phase) }
  }
  public var onPhaseChange: (@MainActor @Sendable (ScreenCapturePhase) -> Void)?
  public var onChange: (@MainActor @Sendable (CaptureRecordingSnapshot) -> Void)?
  public var onFailure: (@MainActor @Sendable (String) -> Void)?
  public var onFinalizationChange: (@MainActor @Sendable (CaptureFinalizationState) -> Void)?
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
  private var nativeWorkWaiters: [CheckedContinuation<Void, Never>] = []
  private var hasPendingNativeWork: Bool {
    pendingStart != nil || switchingMicrophone || retiringMicrophone
  }
  private var monitor: Timer?
  private var sleepObserver: NSObjectProtocol?
  private let retirement = CaptureStreamRetirement()
  private let system: CaptureSystem
  private let persistence: CapturePersistence

  public init() {
    persistence = .live
    system = .init(
      permissions: SystemCaptureSource.permissions,
      filter: SystemCaptureSource.filter,
      microphone: Self.defaultMicrophone,
      stream: { SCStream(filter: $0, configuration: $1, delegate: $2) }
    )
  }

  init(system: CaptureSystem, persistence: CapturePersistence = .live) {
    self.system = system
    self.persistence = persistence
  }

  /// Permissions and source are resolved before this method acknowledges Recording.
  /// Call SystemCaptureSource.requestPermission only from an explicit user action.
  public func start(root: URL, archiveID: String, source: CaptureSource) async throws {
    guard phase == .idle, !hasPendingNativeWork, !retirement.hasPending else {
      throw CaptureStartFailure.alreadyRecording
    }
    let attempt = CaptureStartAttempt()
    pendingStart = attempt
    session = nil
    snapshot = nil
    finalization = .init()
    refreshFinalizationFacts()
    var allocated: CaptureArchiveSession?
    phase = .starting
    defer {
      if pendingStart === attempt {
        pendingStart = nil
        if phase == .starting {
          if allocated != nil { finalization.localSave = .needsRecovery }
          phase = allocated.map { .needsRecovery(callID: $0.callID) } ?? .idle
        }
        settlePendingNativeWork()
      }
    }
    let permission = system.permissions()
    _ = try CaptureSourceResolver.resolve(
      permissions: permission,
      frontmostPID: source.processID,
      ownPID: ProcessInfo.processInfo.processIdentifier,
      windows: [source]
    )
    let selectedFilter = try await system.filter(source)
    try checkStart(attempt)
    let microphone = system.microphone()
    let created = try CaptureArchiveSession.allocate(
      root: root,
      archiveID: archiveID,
      source: source,
      microphone: microphone
    )
    session = created
    allocated = created
    finalization.callID = created.callID
    finalization.localSave = .pending
    // Retain the identity before even the first durable preparation write.
    try await created.prepare()
    try checkStart(attempt)
    filter = selectedFilter
    let output = try CaptureStreamSink(
      session: created,
      queue: system.audioQueue(),
      origin: CMClockGetTime(CMClockGetHostTimeClock()),
      microphone: microphone,
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
      }
    )
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
    refreshFinalizationFacts()
    output.acceptApplicationStream(stream)
    do {
      try stream.addCaptureOutput(output, type: .audio, queue: output.callbackQueue)
      // No .screen output and no SCRecordingOutput: pixels never reach persistence.
      try checkStart(attempt)
      // Native Start can deliver application audio before either stream acknowledges.
      // Keep the bounded timeline durable while those acknowledgements remain pending.
      output.startClock()
      try await stream.startCapture()
      try checkStart(attempt)
      if let microphone { await replaceMicrophone(microphone) }
      try checkStart(attempt)
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

  @discardableResult public func stop(reason: String? = nil) async throws -> CaptureCompletion? {
    try requireCaptureInterruptionReason(reason)
    pendingStart?.cancelled = true
    guard !stopping, let output = sink, let session else { return nil }
    phase = .stopping
    defer {
      if phase == .stopping {
        if finalization.localSave != .confirmed { finalization.localSave = .needsRecovery }
        phase = .needsRecovery(callID: session.callID)
      }
      sink = nil
      filter = nil
      applicationDelegate = nil
      microphoneDelegate = nil
      refreshFinalizationFacts()
    }
    monitor?.invalidate()
    monitor = nil
    if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
    sleepObserver = nil
    let endedAt = output.stopClock()
    let application = applicationStream
    let microphone = microphoneStream
    applicationStream = nil
    microphoneStream = nil
    if let microphone { try? await retirement.retire(microphone) }
    if let application { try? await retirement.retire(application) }
    refreshFinalizationFacts()
    // Preserve a known stop cause before crossing the external media sealing boundary.
    try await session.requestStop(reason: reason)
    let result = try await output.finish(at: endedAt, reason: reason)
    publish(result.1)
    sink = nil
    filter = nil
    applicationDelegate = nil
    microphoneDelegate = nil
    let aggregate = try await persistence.complete(session, result.0, result.1.interruptionReason)
    finalization.localSave = .confirmed
    publishCompletion(aggregate)
    try await retirement.retryAll()
    refreshFinalizationFacts()
    phase = hasPendingNativeWork ? .cancellingStart : .idle
    return aggregate
  }

  /// A replacement microphone can acknowledge native Start after Finish already
  /// saved the call. Quit waits until that continuation retires its exact stream.
  func waitForPendingNativeWork() async {
    guard hasPendingNativeWork else { return }
    await withCheckedContinuation { nativeWorkWaiters.append($0) }
  }

  private func settlePendingNativeWork() {
    refreshFinalizationFacts()
    guard !hasPendingNativeWork else { return }
    if phase == .cancellingStart {
      if retirement.hasPending, let session {
        phase = .needsRecovery(callID: session.callID)
      } else {
        phase = .idle
      }
    }
    let waiters = nativeWorkWaiters
    nativeWorkWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  private func refreshFinalizationFacts() {
    finalization.captureStopped =
      applicationStream == nil && microphoneStream == nil && !retirement.hasPending
    finalization.pendingNativeStart = pendingStart != nil || switchingMicrophone
  }

  private func publishCompletion(_ result: CaptureCompletion) {
    publish(
      .init(
        state: result.call.captureState == .interrupted ? .interrupted : .stopped,
        elapsedMs: result.call.durationMs ?? 0,
        microphoneEnabled: snapshot?.microphoneEnabled ?? true,
        microphone: snapshot?.microphone,
        interruptionReason: result.call.interruptionReason
      )
    )
  }

  /// A failed finalization retains its session and blocks new capture until explicitly recovered.
  @discardableResult public func retryRecovery() async throws -> CaptureCompletion {
    guard !hasPendingNativeWork, case .needsRecovery(let callID) = phase,
      let session, session.callID == callID
    else {
      throw CaptureError.closed
    }
    phase = .stopping
    defer {
      refreshFinalizationFacts()
      if phase == .stopping { phase = .needsRecovery(callID: callID) }
    }
    var stopFailure: (any Error)?
    do { try await retirement.retryAll() } catch { stopFailure = error }
    refreshFinalizationFacts()
    let aggregate: CaptureCompletion
    do {
      aggregate = try await persistence.recover(session)
      finalization.localSave = .confirmed
      publishCompletion(aggregate)
    } catch {
      finalization.localSave = .needsRecovery
      throw error
    }
    if let stopFailure { throw stopFailure }
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
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main
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

  func checkSourceAndMicrophone() async {
    guard !stopping, let source = session?.source, applicationStream != nil else { return }
    guard system.sourceIsAvailable(source) else {
      await interrupt("source_exited")
      return
    }
    if snapshot?.elapsedMs ?? 0 >= 10_800_000 {
      await interrupt("duration_limit")
      return
    }
    let permissions = system.permissions()
    guard permissions.screenAudio else {
      await interrupt("screen_audio_permission")
      return
    }
    let current = permissions.microphone ? system.microphone() : nil
    if current != snapshot?.microphone || (current != nil && microphoneStream == nil) {
      await replaceMicrophone(current)
      if !permissions.microphone, phase == .recording { onFailure?("microphone_permission") }
    }
  }

  private func replaceMicrophone(_ device: CaptureMicrophone?) async {
    guard !switchingMicrophone, !retiringMicrophone, let output = sink, owns(output), let filter
    else {
      return
    }
    switchingMicrophone = true
    refreshFinalizationFacts()
    defer {
      switchingMicrophone = false
      settlePendingNativeWork()
    }
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
      guard system.permissions().microphone else {
        onFailure?("microphone_permission")
        return
      }
      let delegate = CaptureStreamDelegate { [weak self] id in
        Task { @MainActor in await self?.microphoneFailed(expectedID: id) }
      }
      microphoneDelegate = delegate
      let stream = system.stream(filter, CaptureStreamConfiguration.microphone(device), delegate)
      replacement = stream
      microphoneStream = stream
      try stream.addCaptureOutput(output, type: .microphone, queue: output.callbackQueue)
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
    defer {
      retiringMicrophone = false
      settlePendingNativeWork()
    }
    if let failedStream { try? await retirement.retire(failedStream) }
    guard owns(sink) else { return }
    if let value = try? await sink.perform({ engine in
      try engine.microphoneChanged(nil, at: CMClockGetTime(CMClockGetHostTimeClock()))
      return engine.snapshot
    }) {
      guard owns(sink) else { return }
      publish(value)
    }
    onFailure?(system.permissions().microphone ? "microphone_unavailable" : "microphone_permission")
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
final class CaptureStreamSink: NSObject, SCStreamOutput, @unchecked Sendable {
  let queue: DispatchQueue
  let callbackQueue = DispatchQueue(label: "trigo.capture.ingress", qos: .userInteractive)
  private var ingress: CaptureAudioIngress!
  private let engine: CaptureRecordingEngine
  private let routing: CaptureAudioRouting
  private let selection = CaptureStreamSelection()
  private var timer: DispatchSourceTimer?
  // Finish freezes the clock before queued timer work can resume. Engine and
  // media mutation still belong exclusively to the serial audio queue.
  private let clockLock = NSLock()
  private var stoppedClockTime: CMTime?
  private var failed = false
  private let onSnapshot: @Sendable (CaptureRecordingSnapshot) -> Void
  private let onFailure: @Sendable (String) -> Void
  private let onMicrophoneFailure: @Sendable (ObjectIdentifier) -> Void

  init(
    session: CaptureArchiveSession,
    queue: DispatchQueue,
    origin: CMTime,
    microphone: CaptureMicrophone?,
    onSnapshot: @escaping @Sendable (CaptureRecordingSnapshot) -> Void,
    onMicrophoneFailure: @escaping @Sendable (ObjectIdentifier) -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) throws {
    self.queue = queue
    engine = try CaptureRecordingEngine(
      writer: CaptureMediaWriter(session: session),
      origin: origin,
      microphone: microphone
    )
    routing = CaptureAudioRouting(engine: engine, selection: selection)
    self.onSnapshot = onSnapshot
    self.onMicrophoneFailure = onMicrophoneFailure
    self.onFailure = onFailure
    super.init()
    ingress = CaptureAudioIngress(
      queue: queue,
      selection: selection,
      consume: { [weak self] in self?.receive($0) },
      overflow: { [weak self] in self?.fail("capture_queue_overflow") }
    )
  }

  func perform<T: Sendable>(
    _ body: @escaping @Sendable (CaptureRecordingEngine) throws -> T
  )
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
    ingress.select(id, for: .microphone)
  }

  func acceptApplicationStream(_ stream: (any CaptureTransport)?) {
    let id = stream.map(ObjectIdentifier.init)
    ingress.select(id, for: .application)
  }

  func startClock() {
    queue.async { [self] in
      let clock = DispatchSource.makeTimerSource(queue: queue)
      clock.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(25))
      clock.setEventHandler { [weak self] in
        guard let self, !failed else { return }
        do {
          let time = clockLock.withLock {
            stoppedClockTime ?? CMClockGetTime(CMClockGetHostTimeClock())
          }
          try advanceClock(at: time)
        } catch CaptureError.durationLimit { fail("duration_limit") } catch {
          fail(error is CaptureError ? "capture_timeline_failed" : "media_write_failed")
        }
      }
      timer = clock
      clock.resume()
    }
  }

  func advanceClock(at time: CMTime) throws {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !failed else { return }
    try engine.advance(at: time, pendingAudioAt: ingress.earliestPendingTime)
    onSnapshot(engine.snapshot)
  }

  func stopClock() -> CMTime {
    let time = clockLock.withLock {
      let time = stoppedClockTime ?? CMClockGetTime(CMClockGetHostTimeClock())
      stoppedClockTime = time
      return time
    }
    queue.async { [self] in
      timer?.cancel()
      timer = nil
    }
    return time
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    dispatchPrecondition(condition: .onQueue(callbackQueue))
    let role: MediaSourceRole
    switch type {
    case .audio: role = .application
    case .microphone:
      role = .microphone
    default: return  // Screen/video samples are never decoded or persisted.
    }
    enqueue(
      sampleBuffer,
      role: role,
      streamID: ObjectIdentifier(stream),
      deliveredAt: CMClockGetTime(CMClockGetHostTimeClock())
    )
  }

  @discardableResult
  func enqueue(
    _ sample: CMSampleBuffer,
    role: MediaSourceRole,
    streamID: ObjectIdentifier,
    deliveredAt: CMTime
  ) -> Bool {
    ingress.submit(sample, role: role, streamID: streamID, deliveredAt: deliveredAt)
  }

  var ingressStatistics: CaptureIngressStatistics { ingress.statistics }

  func finish(
    at time: CMTime,
    reason: String?
  ) async throws -> (
    FinalizedMediaMaster, CaptureRecordingSnapshot
  ) {
    try await perform { [self] _ in try finishOnQueue(at: time, reason: reason) }
  }

  func finishOnQueue(
    at time: CMTime,
    reason: String?
  ) throws -> (
    FinalizedMediaMaster, CaptureRecordingSnapshot
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    ingress.finishPending()
    let master = try engine.stop(at: time, reason: reason)
    return (master, engine.snapshot)
  }

  private func receive(_ audio: CaptureQueuedAudio) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !failed else { return }
    switch routing.receive(
      audio.sample,
      role: audio.role,
      streamID: audio.streamID,
      at: audio.deliveredAt
    )
    {
    case .accepted, .ignored: break
    case .microphoneUnavailable: onMicrophoneFailure(audio.streamID)
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
