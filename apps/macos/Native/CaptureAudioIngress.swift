import CoreMedia
import Foundation
import TrigoContracts

struct CaptureQueuedAudio: @unchecked Sendable {
  let sample: CMSampleBuffer
  let role: MediaSourceRole
  let streamID: ObjectIdentifier
  let deliveredAt: CMTime
  let admittedAt: ContinuousClock.Instant
  let duration: Double
  #if DEBUG
    var diagnosticBuffer: Int?
  #endif
}

struct CaptureIngressStatistics: Sendable {
  let pendingBuffers: Int
  let maximumPendingBuffers: Int
  let maximumPendingSourceSeconds: Double
  let maximumServiceSeconds: Double
  let rejected: Bool
}

/// SCK callbacks enter on a separate lightweight queue. At most one drain is scheduled on
/// the engine queue; queued plus in-flight audio is capped at one second per source and
/// 256 buffers. An overloaded producer fails explicitly instead of growing retained audio.
final class CaptureAudioIngress: @unchecked Sendable {
  private let lock = NSLock()
  private let queue: DispatchQueue
  private let selection: CaptureStreamSelection
  private let consume: @Sendable (CaptureQueuedAudio) -> Void
  private let overflow: @Sendable () -> Void
  private var pending: [CaptureQueuedAudio] = []
  private var sourceSeconds: [Double] = [0, 0]
  private var outstanding = 0
  private var scheduled = false
  private var rejected = false
  private var closed = false
  private var maxBuffers = 0
  private var maxSeconds = 0.0
  private var maxService = 0.0
  #if DEBUG
    // TEMP-57-OVERFLOW: installed only before the first callback is registered.
    var diagnostics: CaptureOverflowDiagnostics?
  #endif

  init(
    queue: DispatchQueue, selection: CaptureStreamSelection = CaptureStreamSelection(),
    consume: @escaping @Sendable (CaptureQueuedAudio) -> Void,
    overflow: @escaping @Sendable () -> Void
  ) {
    self.queue = queue
    self.selection = selection
    self.consume = consume
    self.overflow = overflow
  }

  @discardableResult
  func submit(
    _ sample: CMSampleBuffer, role: MediaSourceRole, streamID: ObjectIdentifier,
    deliveredAt: CMTime
  ) -> Bool {
    let rate =
      sample.formatDescription.flatMap {
        CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate
      } ?? 0
    let duration = rate.isFinite && rate > 0 ? Double(sample.numSamples) / rate : 0
    var value = CaptureQueuedAudio(
      sample: sample, role: role, streamID: streamID,
      deliveredAt: deliveredAt, admittedAt: .now, duration: max(0, duration))
    #if DEBUG
      value.diagnosticBuffer = diagnostics?.nextBuffer()
    #endif
    let channel = role == .microphone ? 0 : 1
    let action = selection.withSelection { ids -> Int in
      guard ids[channel] == streamID else {
        #if DEBUG
          lock.withLock {
            diagnostics?.admission(
              value, outcome: .stale,
              pending: outstanding, source: sourceSeconds[channel],
              other: sourceSeconds[1 - channel])
          }
        #endif
        return 0
      }
      return lock.withLock { () -> Int in
        #if DEBUG
          var outcome: CaptureOverflowOutcome = .accepted
          defer {
            diagnostics?.admission(
              value, outcome: outcome,
              pending: outstanding, source: sourceSeconds[channel],
              other: sourceSeconds[1 - channel])
          }
        #endif
        guard !rejected, !closed else {
          #if DEBUG
            outcome = closed ? .closed : .rejected
          #endif
          return 0
        }
        guard outstanding < 256, duration.isFinite, duration >= 0,
          sourceSeconds[channel] + duration <= 1.000_001
        else {
          #if DEBUG
            outcome =
              outstanding >= 256
              ? .bufferLimit
              : (!duration.isFinite || duration < 0 ? .invalidDuration : .sourceLimit)
          #endif
          rejected = true
          return -1
        }
        pending.append(value)
        outstanding += 1
        sourceSeconds[channel] += duration
        maxBuffers = max(maxBuffers, outstanding)
        maxSeconds = max(maxSeconds, sourceSeconds[channel])
        if scheduled { return 1 }
        scheduled = true
        return 2
      }
    }
    if action == -1 { queue.async { [self] in overflow() } }
    if action == 2 { queue.async { [self] in drain() } }
    return action > 0
  }

  var statistics: CaptureIngressStatistics {
    lock.withLock {
      .init(
        pendingBuffers: outstanding, maximumPendingBuffers: maxBuffers,
        maximumPendingSourceSeconds: maxSeconds, maximumServiceSeconds: maxService,
        rejected: rejected)
    }
  }

  func select(_ id: ObjectIdentifier?, for role: MediaSourceRole) {
    selection.select(id, for: role) { ids in
      lock.withLock {
        pending.removeAll { audio in
          let channel = audio.role == .microphone ? 0 : 1
          guard ids[channel] != audio.streamID else { return false }
          sourceSeconds[channel] -= audio.duration
          outstanding -= 1
          #if DEBUG
            diagnostics?.record(
              .init(
                kind: .discard, role: audio.role,
                buffer: audio.diagnosticBuffer, durationSeconds: audio.duration,
                pendingBuffers: outstanding, sourceSeconds: sourceSeconds[channel],
                otherSourceSeconds: sourceSeconds[1 - channel]), stream: audio.streamID)
          #endif
          return true
        }
      }
    }
  }

  /// A timer must not declare already-admitted pending input unavailable before it drains.
  var earliestPendingTime: CMTime? {
    lock.withLock {
      pending.map { $0.sample.presentationTimeStamp }.filter(\.isNumeric).min {
        CMTimeCompare($0, $1) < 0
      }
    }
  }

  private func drain() {
    dispatchPrecondition(condition: .onQueue(queue))
    // Snapshot one bounded batch. A replenishing producer cannot starve controls/timers.
    let batch = lock.withLock { () -> [CaptureQueuedAudio] in
      let count = min(8, pending.count)
      let result = Array(pending.prefix(count))
      pending.removeFirst(count)
      return result
    }
    consumeBatch(batch)
    let more = lock.withLock {
      if pending.isEmpty {
        scheduled = false
        return false
      }
      return true
    }
    if more { queue.async { [self] in drain() } }
  }

  /// Stop freezes admission before draining its bounded remainder. An admitted callback
  /// cannot be stranded behind finalization merely because drains yield to controls.
  func finishPending() {
    dispatchPrecondition(condition: .onQueue(queue))
    let remainder = lock.withLock {
      closed = true
      let result = pending
      pending = []
      return result
    }
    consumeBatch(remainder)
  }

  private func consumeBatch(_ batch: [CaptureQueuedAudio]) {
    for next in batch {
      let accepted = selection.accepts(next.streamID, for: next.role)
      #if DEBUG
        diagnostics?.record(
          .init(
            kind: .consumeStart, role: next.role,
            buffer: next.diagnosticBuffer, outcome: accepted ? .accepted : .stale))
      #endif
      if accepted { autoreleasepool { consume(next) } }
      let elapsed = next.admittedAt.duration(to: .now).components
      lock.withLock {
        sourceSeconds[next.role == .microphone ? 0 : 1] -= next.duration
        outstanding -= 1
        maxService = max(maxService, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        #if DEBUG
          let channel = next.role == .microphone ? 0 : 1
          diagnostics?.record(
            .init(
              kind: .consumeFinish, role: next.role,
              buffer: next.diagnosticBuffer, durationSeconds: next.duration,
              pendingBuffers: outstanding, sourceSeconds: sourceSeconds[channel],
              otherSourceSeconds: sourceSeconds[1 - channel]))
        #endif
      }
    }
  }
}
