import Combine
import Foundation

/// Owns network tasks, two bounded decoded buffers, grant renewal and the call-time cursor.
/// Clearing a call cancels its work and releases all managed playback state.
@MainActor public final class CallAudioPlayer: ObservableObject {
  @Published public private(set) var state = CallPlaybackState()
  private let transport: any CallPlaybackTransport
  private let output: any PlaybackAudioOutput
  private var access: PlaybackAccess?
  private var work: Task<Void, Never>?
  private var ticker: Task<Void, Never>?
  private var generation = 0
  private var wantsPlay = false
  private var queued = 0
  private var nextIndex = 0
  private var originFrame = 0
  private var queuedEndFrame = 0

  public init(transport: any CallPlaybackTransport, output: any PlaybackAudioOutput) {
    self.transport = transport
    self.output = output
  }

  deinit { work?.cancel(); ticker?.cancel() }

  public static func live(connection: ServerConnection, archiveID: String) -> CallAudioPlayer {
    .init(
      transport: HTTPPlaybackTransport(connection: connection, archiveID: archiveID),
      output: AVPlaybackAudioOutput()
    )
  }

  public func load(callID: String, positionMs: Int = 0, autoplay: Bool = false) async {
    invalidate()
    access = nil
    state = .init()
    state.callID = callID
    state.positionMs = max(0, min(10_800_000, positionMs))
    state.phase = .loading
    wantsPlay = autoplay
    await startWork(needsGrant: true).value
  }

  public func play() async {
    guard state.callID != nil else { return }
    wantsPlay = true
    if state.phase == .finished {
      await seek(positionMs: 0)
    } else if queued > 0 {
      resumeOutput()
    } else if work == nil {
      await seek(positionMs: state.positionMs)
    }
  }

  public func pause() {
    wantsPlay = false
    updatePosition()
    output.pause()
    stopTicker()
    if queued > 0 { state.phase = .paused }
  }

  public func seek(positionMs: Int) async {
    guard state.callID != nil else { return }
    let resume = wantsPlay
    invalidate()
    wantsPlay = resume
    state.positionMs = max(0, min(access == nil ? 10_800_000 : state.durationMs, positionMs))
    state.failure = nil
    state.phase = .loading
    if access != nil { setOrigin() }
    await startWork(needsGrant: access == nil).value
  }

  public func clear(callID: String? = nil) {
    guard callID == nil || callID == state.callID else { return }
    invalidate()
    access = nil
    wantsPlay = false
    state = .init()
  }

  private func invalidate() {
    generation += 1
    work?.cancel()
    work = nil
    stopTicker()
    output.stop()
    queued = 0
  }

  private func setOrigin() {
    guard let access else { return }
    state.durationMs = access.grant.media.frameCount / 16
    state.positionMs = min(state.positionMs, state.durationMs)
    originFrame = state.positionMs * 16
    queuedEndFrame = originFrame
    nextIndex = originFrame / access.grant.media.segmentFrames
  }

  @discardableResult private func startWork(needsGrant: Bool = false) -> Task<Void, Never> {
    if let work { return work }
    let epoch = generation
    let task = Task<Void, Never> { @MainActor [weak self] in
      guard let self else { return }
      await self.fillBuffers(epoch: epoch, needsGrant: needsGrant)
    }
    work = task
    return task
  }

  private func fillBuffers(epoch: Int, needsGrant: Bool) async {
    defer { if epoch == generation { work = nil } }
    do {
      if needsGrant {
        guard let callID = state.callID else { return }
        let granted = try await transport.grant(
          callID: callID,
          operationID: UUID().uuidString.lowercased()
        )
        try Task.checkCancellation()
        guard epoch == generation else { return }
        try PlaybackValidation.access(granted, callID: callID)
        access = granted
        setOrigin()
      }
      guard let current = access else { throw CallPlaybackError.invalidGrant }
      if originFrame >= current.grant.media.frameCount {
        state.phase = .finished
        wantsPlay = false
        return
      }
      while queued < 2 && nextIndex < current.grant.media.segmentCount {
        let index = nextIndex
        let pcm = try await fetchSegment(index: index, epoch: epoch)
        try Task.checkCancellation()
        guard epoch == generation else { return }
        let expectedStart = index * current.grant.media.segmentFrames
        let expectedCount = min(
          current.grant.media.segmentFrames,
          current.grant.media.frameCount - expectedStart
        )
        guard pcm.startFrame == expectedStart, pcm.frameCount == expectedCount else {
          throw CallPlaybackError.invalidMedia
        }
        let selected = try pcm.trimming(before: originFrame)
        let endFrame = selected.startFrame + selected.frameCount
        try output.enqueue(selected) { [weak self] in
          self?.playedSegment(epoch: epoch, endFrame: endFrame)
        }
        queued += 1
        nextIndex += 1
        queuedEndFrame = endFrame
        if wantsPlay { resumeOutput() } else { state.phase = .paused }
        guard epoch == generation else { return }
      }
    } catch {
      guard epoch == generation, !Task.isCancelled, !(error is CancellationError) else { return }
      fail(error as? CallPlaybackError ?? .invalidMedia)
    }
  }

  private func fetchSegment(index: Int, epoch: Int) async throws -> PlaybackPCM {
    guard let original = access else { throw CallPlaybackError.invalidGrant }
    do { return try await transport.segment(access: original, index: index) } catch let issue
      as CallPlaybackError where issue.renewsGrant
    {
      let renewed = try await transport.grant(
        callID: original.grant.callId,
        operationID: UUID().uuidString.lowercased()
      )
      try Task.checkCancellation()
      guard epoch == generation else { throw CancellationError() }
      try PlaybackValidation.access(renewed, callID: original.grant.callId)
      guard renewed.binding == original.binding, renewed.grant.media == original.grant.media else {
        throw CallPlaybackError.invalidMedia
      }
      access = renewed
      return try await transport.segment(access: renewed, index: index)
    }
  }

  private func playedSegment(epoch: Int, endFrame: Int) {
    guard epoch == generation, queued > 0, let access else { return }
    queued -= 1
    updatePosition()
    if queued == 0 {
      // Freeze call time through an underrun. AVAudioPlayerNode's empty render time
      // must not move the next source passage forward while the network is loading.
      output.stop()
      stopTicker()
      originFrame = endFrame
      queuedEndFrame = endFrame
      state.positionMs = endFrame / 16
      if endFrame == access.grant.media.frameCount {
        state.phase = .finished
        wantsPlay = false
        return
      }
      state.phase = .loading
    }
    if work == nil { startWork() }
  }

  private func resumeOutput() {
    do {
      try output.play()
      state.phase = .playing
      state.failure = nil
      startTicker()
    } catch { fail(.audioOutput) }
  }

  private func fail(_ issue: CallPlaybackError) {
    updatePosition()
    invalidate()
    wantsPlay = false
    state.failure = issue
    state.phase = issue == .noAudio || issue == .deleted ? .unavailable : .error
  }

  func updatePosition() {
    guard queued > 0 else { return }
    state.positionMs = min(queuedEndFrame, originFrame + output.renderedFrames) / 16
  }

  private func startTicker() {
    guard ticker == nil else { return }
    ticker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        self?.updatePosition()
      }
    }
  }

  private func stopTicker() { ticker?.cancel(); ticker = nil }
}
