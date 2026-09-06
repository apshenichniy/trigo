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

/// Production capture facade for #16. It deliberately owns no panels, shortcuts or
/// calling-application controls. Two SCK streams isolate microphone device failure
/// from the pinned application's audio; both feed one serial host-clock timeline.
@MainActor public final class ScreenCaptureRecording {
  public private(set) var session: CaptureArchiveSession?
  public private(set) var snapshot: CaptureRecordingSnapshot?
  public var onChange: (@MainActor @Sendable (CaptureRecordingSnapshot) -> Void)?
  public var onFailure: (@MainActor @Sendable (String) -> Void)?
  private var applicationStream: SCStream?
  private var microphoneStream: SCStream?
  private var applicationDelegate: CaptureStreamDelegate?
  private var microphoneDelegate: CaptureStreamDelegate?
  private var filter: SCContentFilter?
  private var sink: CaptureStreamSink?
  private var starting = false
  private var stopping = false
  private var cancelStart = false
  private var switchingMicrophone = false
  private var monitor: Timer?
  private var sleepObserver: NSObjectProtocol?

  public init() {}

  /// Permissions and source are resolved before this method acknowledges Recording.
  /// Call SystemCaptureSource.requestPermissions only from an explicit user action.
  public func start(root: URL, archiveID: String, source: CaptureSource) async throws {
    guard !starting, applicationStream == nil, !stopping else {
      throw CaptureStartFailure.alreadyRecording
    }
    starting = true
    cancelStart = false
    defer { starting = false }
    let permission = SystemCaptureSource.permissions()
    _ = try CaptureSourceResolver.resolve(
      permissions: permission, frontmostPID: source.processID,
      ownPID: ProcessInfo.processInfo.processIdentifier, windows: [source])
    let selectedFilter = try await SystemCaptureSource.filter(for: source)
    guard !cancelStart else { throw CancellationError() }
    let microphone = Self.defaultMicrophone()
    let created = try await CaptureArchiveSession.begin(
      root: root, archiveID: archiveID,
      source: source, microphone: microphone)
    session = created
    filter = selectedFilter
    let output = try CaptureStreamSink(
      directory: created.mediaDirectory,
      origin: CMClockGetTime(CMClockGetHostTimeClock()), microphone: microphone,
      onSnapshot: { [weak self] value in Task { @MainActor in self?.publish(value) } },
      onMicrophoneFailure: { [weak self] in Task { @MainActor in await self?.microphoneFailed() } },
      onFailure: { [weak self] reason in Task { @MainActor in await self?.interrupt(reason) } })
    sink = output
    let delegate = CaptureStreamDelegate { [weak self] in
      Task { @MainActor in await self?.interrupt("application_stream_failed") }
    }
    applicationDelegate = delegate
    let stream = SCStream(
      filter: selectedFilter, configuration: CaptureStreamConfiguration.application(),
      delegate: delegate)
    applicationStream = stream
    output.acceptApplicationStream(stream)
    do {
      try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
      // No .screen output and no SCRecordingOutput: pixels never reach persistence.
      guard !cancelStart else { throw CancellationError() }
      try await stream.startCapture()
      guard !cancelStart else { throw CancellationError() }
      if let microphone { await replaceMicrophone(microphone) }
      guard !cancelStart else { throw CancellationError() }
      output.startClock()
      publish(try await output.perform { $0.snapshot })
      beginMonitoring()
    } catch {
      _ = try? await stop(reason: "capture_start_failed")
      throw error
    }
  }

  /// Returns only after microphone policy is effective on the audio/persistence queue.
  public func setMicrophoneEnabled(_ enabled: Bool) async throws {
    guard let sink, !stopping else { throw CaptureError.closed }
    let value = try await sink.perform { engine in
      try engine.setMicrophoneEnabled(enabled, at: CMClockGetTime(CMClockGetHostTimeClock()))
      return engine.snapshot
    }
    publish(value)
  }

  @discardableResult public func stop(reason: String? = nil) async throws -> LocalCallAggregate? {
    if starting { cancelStart = true }
    guard !stopping, let output = sink, let session else { return nil }
    stopping = true
    defer { stopping = false }
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
    try? await microphone?.stopCapture()
    try? await application?.stopCapture()
    let result = try await output.perform { engine in
      let media = try engine.stop(at: endedAt, reason: reason)
      return (media, engine.snapshot)
    }
    publish(result.1)
    sink = nil
    filter = nil
    applicationDelegate = nil
    microphoneDelegate = nil
    return try await session.finish(
      media: result.0, interruptionReason: result.1.interruptionReason)
  }

  private func interrupt(_ reason: String) async {
    guard !stopping else { return }
    do { _ = try await stop(reason: reason) } catch { onFailure?("capture_finalization_failed") }
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
    sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in Task { @MainActor in await self?.interrupt("system_sleep") } }
    monitor = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.checkSourceAndMicrophone() }
    }
  }

  private func checkSourceAndMicrophone() async {
    guard !stopping, let source = session?.source, applicationStream != nil else { return }
    guard let application = NSRunningApplication(processIdentifier: source.processID),
      !application.isTerminated,
      source.matches(
        processID: application.processIdentifier, bundleID: application.bundleIdentifier,
        launchDate: application.launchDate)
    else {
      await interrupt("source_exited")
      return
    }
    if snapshot?.elapsedMs ?? 0 >= 10_800_000 {
      await interrupt("duration_limit")
      return
    }
    let current = Self.defaultMicrophone()
    if current != snapshot?.microphone || (current != nil && microphoneStream == nil) {
      await replaceMicrophone(current)
    }
  }

  private func replaceMicrophone(_ device: CaptureMicrophone?) async {
    guard !switchingMicrophone, !stopping, let output = sink, let filter else { return }
    switchingMicrophone = true
    defer { switchingMicrophone = false }
    let previous = microphoneStream
    microphoneStream = nil
    output.acceptMicrophoneStream(nil)
    try? await previous?.stopCapture()
    do {
      publish(
        try await output.perform { engine in
          try engine.microphoneChanged(nil, at: CMClockGetTime(CMClockGetHostTimeClock()))
          return engine.snapshot
        })
      guard let device, !stopping, applicationStream != nil else { return }
      let delegate = CaptureStreamDelegate { [weak self] in
        Task { @MainActor in await self?.microphoneFailed() }
      }
      microphoneDelegate = delegate
      let stream = SCStream(
        filter: filter, configuration: CaptureStreamConfiguration.microphone(device),
        delegate: delegate)
      microphoneStream = stream
      try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
      output.acceptMicrophoneStream(stream)
      publish(
        try await output.perform { engine in
          try engine.microphoneChanged(device, at: CMClockGetTime(CMClockGetHostTimeClock()))
          return engine.snapshot
        })
      try await stream.startCapture()
      if stopping || applicationStream == nil { try? await stream.stopCapture() }
    } catch { await microphoneFailed() }
  }

  private func microphoneFailed() async {
    guard let sink, !stopping else { return }
    microphoneStream = nil
    sink.acceptMicrophoneStream(nil)
    if let value = try? await sink.perform({ engine in
      try engine.microphoneChanged(nil, at: CMClockGetTime(CMClockGetHostTimeClock()))
      return engine.snapshot
    }) {
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
  private let failure: @Sendable () -> Void
  init(failure: @escaping @Sendable () -> Void) { self.failure = failure }
  func stream(_ stream: SCStream, didStopWithError error: Error) { failure() }
}

/// All mutable engine/stream-admission state is confined to queue. No Task is created per audio buffer.
private final class CaptureStreamSink: NSObject, SCStreamOutput, @unchecked Sendable {
  let queue = DispatchQueue(label: "trigo.capture.audio", qos: .userInitiated)
  private let engine: CaptureRecordingEngine
  private let routing: CaptureAudioRouting
  private var timer: DispatchSourceTimer?
  private var failed = false
  private let onSnapshot: @Sendable (CaptureRecordingSnapshot) -> Void
  private let onFailure: @Sendable (String) -> Void
  private let onMicrophoneFailure: @Sendable () -> Void

  init(
    directory: URL, origin: CMTime, microphone: CaptureMicrophone?,
    onSnapshot: @escaping @Sendable (CaptureRecordingSnapshot) -> Void,
    onMicrophoneFailure: @escaping @Sendable () -> Void,
    onFailure: @escaping @Sendable (String) -> Void
  ) throws {
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

  func acceptMicrophoneStream(_ stream: SCStream?) {
    let id = stream.map(ObjectIdentifier.init)
    queue.async { [self] in routing.select(id, for: .microphone) }
  }

  func acceptApplicationStream(_ stream: SCStream?) {
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
        } catch { fail(error is CaptureError ? "capture_timeline_failed" : "media_write_failed") }
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
    case .microphoneUnavailable: onMicrophoneFailure()
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
