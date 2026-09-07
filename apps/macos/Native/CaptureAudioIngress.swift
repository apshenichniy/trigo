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
  // DEBUG-57-CAPTURE
  let diagnosticBuffer: Int?
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
  // DEBUG-57-CAPTURE
  private let diagnostics: CaptureDiagnostics?
  private var pending: [CaptureQueuedAudio] = []
  private var sourceSeconds: [Double] = [0, 0]
  private var outstanding = 0
  private var scheduled = false
  private var rejected = false
  private var closed = false
  private var maxBuffers = 0
  private var maxSeconds = 0.0
  private var maxService = 0.0

  init(
    queue: DispatchQueue, selection: CaptureStreamSelection = CaptureStreamSelection(),
    consume: @escaping @Sendable (CaptureQueuedAudio) -> Void,
    overflow: @escaping @Sendable () -> Void,
    // DEBUG-57-CAPTURE
    diagnostics: CaptureDiagnostics? = nil
  ) {
    self.queue = queue
    self.selection = selection
    self.consume = consume
    self.overflow = overflow
    // DEBUG-57-CAPTURE
    self.diagnostics = diagnostics
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
    // DEBUG-57-CAPTURE: optional dispatch avoids diagnostic extraction when disabled.
    let diagnosticBuffer = diagnostics?.callback(
      sample, role: role, stream: streamID,
      deliveredAt: deliveredAt)
    let value = CaptureQueuedAudio(
      sample: sample, role: role, streamID: streamID,
      deliveredAt: deliveredAt, admittedAt: .now, duration: max(0, duration),
      // DEBUG-57-CAPTURE
      diagnosticBuffer: diagnosticBuffer)
    let channel = role == .microphone ? 0 : 1
    let action = selection.withSelection { ids -> Int in
      guard ids[channel] == streamID else {
        diagnostics?.record(
          .init(
            kind: .admission, role: role, buffer: diagnosticBuffer,
            // DEBUG-57-CAPTURE
            outcome: .stale), stream: streamID)
        return 0
      }
      return lock.withLock { () -> Int in
        guard !rejected, !closed else {
          diagnostics?.record(
            .init(
              kind: .admission, role: role, buffer: diagnosticBuffer, durationSeconds: duration,
              pendingBuffers: outstanding, sourceSeconds: sourceSeconds[channel],
              otherSourceSeconds: sourceSeconds[1 - channel],
              // DEBUG-57-CAPTURE
              outcome: rejected ? .rejected : .closed), stream: streamID)
          return 0
        }
        guard outstanding < 256, duration.isFinite, duration >= 0,
          sourceSeconds[channel] + duration <= 1.000_001
        else {
          diagnostics?.record(
            .init(
              kind: .admission, role: role, buffer: diagnosticBuffer, durationSeconds: duration,
              pendingBuffers: outstanding, sourceSeconds: sourceSeconds[channel],
              otherSourceSeconds: sourceSeconds[1 - channel],
              outcome: outstanding >= 256
                ? .bufferLimit
                : (!duration.isFinite || duration < 0) ? .invalidDuration : .sourceLimit),
            // DEBUG-57-CAPTURE
            stream: streamID)
          rejected = true
          return -1
        }
        pending.append(value)
        outstanding += 1
        sourceSeconds[channel] += duration
        maxBuffers = max(maxBuffers, outstanding)
        maxSeconds = max(maxSeconds, sourceSeconds[channel])
        diagnostics?.record(
          .init(
            kind: .admission, role: role, buffer: diagnosticBuffer, durationSeconds: duration,
            pendingBuffers: outstanding, sourceSeconds: sourceSeconds[channel],
            // DEBUG-57-CAPTURE
            otherSourceSeconds: sourceSeconds[1 - channel], outcome: .accepted), stream: streamID)
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
          return true
        }
        diagnostics?.record(
          .init(
            kind: .streamSelection, role: role,
            pendingBuffers: outstanding, sourceSeconds: sourceSeconds[role == .microphone ? 0 : 1],
            otherSourceSeconds: sourceSeconds[role == .microphone ? 1 : 0], flags: id == nil ? 0 : 1
          ),
          // DEBUG-57-CAPTURE
          stream: id)
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
      diagnostics?.record(
        .init(kind: .consumeStart, role: next.role, buffer: next.diagnosticBuffer),
        // DEBUG-57-CAPTURE
        stream: next.streamID)
      if selection.accepts(next.streamID, for: next.role) { autoreleasepool { consume(next) } }
      let elapsed = next.admittedAt.duration(to: .now).components
      lock.withLock {
        sourceSeconds[next.role == .microphone ? 0 : 1] -= next.duration
        outstanding -= 1
        maxService = max(maxService, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        diagnostics?.record(
          .init(
            kind: .consumeFinish, role: next.role, buffer: next.diagnosticBuffer,
            pendingBuffers: outstanding,
            sourceSeconds: sourceSeconds[next.role == .microphone ? 0 : 1],
            otherSourceSeconds: sourceSeconds[next.role == .microphone ? 1 : 0]),
          // DEBUG-57-CAPTURE
          stream: next.streamID)
      }
    }
  }
}
