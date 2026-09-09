import CoreMedia
import Foundation
import TrigoContracts

public struct CaptureRecordingSnapshot: Sendable, Equatable {
  public var state: CaptureLifecycleState
  public var elapsedMs: Int
  public var microphoneEnabled: Bool
  public var microphone: CaptureMicrophone?
  public var interruptionReason: String?
  public var levels = RecordedAudioLevels()
}

/// The production sink and controlled fixtures use this same synchronous boundary.
/// It has no TCC/UI/stream-opening side effects and cannot restart after termination.
public final class CaptureRecordingEngine {
  private let origin: CMTime
  private let writer: CaptureMediaWriter
  private let timeline: CaptureTimeline
  private var applicationDecoder: CaptureAudioDecoder
  private var microphoneDecoder: CaptureAudioDecoder
  private var microphoneEpochFrame = 0
  public private(set) var snapshot: CaptureRecordingSnapshot

  var committedTime: CMTime {
    CMTimeAdd(origin, CMTime(value: Int64(writer.durationMs), timescale: 1000))
  }

  public init(writer: CaptureMediaWriter, origin: CMTime, microphone: CaptureMicrophone?) throws {
    self.origin = origin
    self.writer = writer
    timeline = CaptureTimeline(writer: writer)
    applicationDecoder = try CaptureAudioDecoder()
    microphoneDecoder = try CaptureAudioDecoder()
    try timeline.setMicrophoneAvailable(microphone != nil, atMs: 0)
    snapshot = .init(
      state: .recording,
      elapsedMs: 0,
      microphoneEnabled: true,
      microphone: microphone,
      interruptionReason: nil
    )
  }

  public func receive(_ sample: CMSampleBuffer, role: MediaSourceRole) throws {
    guard snapshot.state == .recording else { throw CaptureError.closed }
    if role == .microphone {
      guard snapshot.microphone != nil, snapshot.microphoneEnabled else { return }
      let relative = CMTimeGetSeconds(CMTimeSubtract(sample.presentationTimeStamp, origin))
      guard relative.isFinite else { throw CaptureError.invalidAudio }
      // Reject before conversion: resampler history must never retain suppressed speech.
      if relative * Double(MediaMasterProfile.sampleRate) < Double(microphoneEpochFrame) { return }
    }
    let decoded = try (role == .microphone ? microphoneDecoder : applicationDecoder)
      .decode(
        sample,
        origin: origin
      )
    if role == .microphone && decoded.startFrame < microphoneEpochFrame { return }
    try timeline.append(role: role, startFrame: decoded.startFrame, samples: decoded.samples)
  }

  /// Flushes behind a 250 ms reorder allowance. Called every 500 ms by the production sink.
  public func advance(at time: CMTime, pendingAudioAt: CMTime? = nil) throws {
    guard snapshot.state == .recording else { throw CaptureError.closed }
    let ms = try relativeMs(time)
    guard ms <= MediaMasterProfile.maximumDurationMs else { throw CaptureError.durationLimit }
    let pendingMs: Int
    if let pendingAudioAt {
      let seconds = CMTimeGetSeconds(CMTimeSubtract(pendingAudioAt, origin))
      guard seconds.isFinite else { throw CaptureError.invalidAudio }
      pendingMs = max(0, Int((seconds * 1000).rounded(.down)))
    } else {
      pendingMs = ms
    }
    snapshot.levels = try timeline.flush(
      throughMs: min(max(writer.durationMs, ms - 250), max(writer.durationMs, pendingMs))
    )
    snapshot.elapsedMs = ms
  }

  public func setMicrophoneEnabled(_ enabled: Bool, at time: CMTime) throws {
    guard snapshot.state == .recording else { throw CaptureError.closed }
    try timeline.setMicrophoneEnabled(enabled, atMs: relativeMs(time))
    microphoneDecoder = try CaptureAudioDecoder()
    microphoneEpochFrame = try relativeMs(time) * MediaMasterProfile.framesPerMs
    snapshot.microphoneEnabled = enabled
    snapshot.levels.microphoneRMS = 0
  }

  public func microphoneChanged(_ microphone: CaptureMicrophone?, at time: CMTime) throws {
    guard snapshot.state == .recording else { throw CaptureError.closed }
    microphoneEpochFrame = try relativeMs(time) * MediaMasterProfile.framesPerMs
    try timeline.setMicrophoneAvailable(microphone != nil, atMs: relativeMs(time))
    microphoneDecoder = try CaptureAudioDecoder()
    snapshot.microphone = microphone
    snapshot.levels.microphoneRMS = 0
  }

  public func stop(at time: CMTime, reason: String? = nil) throws -> FinalizedMediaMaster {
    try requireCaptureInterruptionReason(reason)
    guard snapshot.state == .recording else { throw CaptureError.closed }
    try writer.requestStop(reason: reason)
    var failure = reason
    let media: FinalizedMediaMaster
    do {
      try timeline.flush(throughMs: min(MediaMasterProfile.maximumDurationMs, relativeMs(time)))
      media = try writer.finish()
    } catch {
      try writer.recordFailure()
      failure = reason ?? "media_write_failed"
      media = try CaptureMediaWriter.recover(session: writer.session).finish()
    }
    snapshot.state = failure == nil ? .stopped : .interrupted
    snapshot.elapsedMs = media.durationMs
    snapshot.interruptionReason = failure
    snapshot.levels = .init()
    return media
  }

  private func relativeMs(_ time: CMTime) throws -> Int {
    let seconds = CMTimeGetSeconds(CMTimeSubtract(time, origin))
    guard seconds.isFinite, seconds >= 0, seconds <= 86_400 else { throw CaptureError.invalidAudio }
    return Int((seconds * 1000).rounded(.down))
  }
}

func requireCaptureInterruptionReason(_ reason: String?) throws {
  if let reason, !isStableFailureCode(reason) {
    throw LocalPersistenceError.invalidFailureCode(reason)
  }
}
