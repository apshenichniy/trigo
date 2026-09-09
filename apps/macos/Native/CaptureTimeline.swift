import Foundation
import TrigoContracts

public enum CaptureIntervalState: String, Codable, Sendable {
  case recorded, muted, unavailable
}

public struct CaptureInterval: Codable, Equatable, Sendable {
  public let startMs: Int
  public var endMs: Int
  public let state: CaptureIntervalState
}

/// A bounded reorder window on the profile's call-relative clock. No raw microphone
/// sample leaves this in-memory boundary until its effective recording policy is applied.
/// The stream's serial queue owns the timeline and writer; UI acknowledgement follows
/// completion on that queue, never merely enqueueing a mute request.
public final class CaptureTimeline {
  private let writer: CaptureMediaWriter
  private var samples: [[Int16?]] = [[], []]
  private var committedFrame = 0
  private var microphonePolicy: [(frame: Int, enabled: Bool)] = [(0, true)]
  private var microphoneAvailability: [(frame: Int, available: Bool)] = [(0, true)]
  private var lastControlMs = 0
  public private(set) var microphoneEnabled = true

  public init(writer: CaptureMediaWriter) { self.writer = writer }

  public func append(role: MediaSourceRole, startFrame: Int, samples incoming: [Int16]) throws {
    guard startFrame >= -(MediaMasterProfile.sampleRate * 2),
      startFrame <= committedFrame + (MediaMasterProfile.sampleRate * 2),
      incoming.count <= (MediaMasterProfile.sampleRate * 2),
      startFrame + incoming.count <= committedFrame + (MediaMasterProfile.sampleRate * 2)
    else { throw CaptureError.invalidAudio }
    let end = startFrame + incoming.count
    guard end > committedFrame else { return }  // Late input cannot rewrite durable media.
    ensureCapacity(end - committedFrame)
    let track = channel(role)
    for frame in max(startFrame, committedFrame)..<end
    where role != .microphone || microphoneAllowed(at: frame) {
      // First delivery wins; a repeated/overlapping callback is not mixed twice.
      if samples[track][frame - committedFrame] == nil {
        samples[track][frame - committedFrame] = incoming[frame - startFrame]
      }
    }
  }

  public func setMicrophoneEnabled(_ enabled: Bool, atMs: Int) throws {
    guard atMs >= lastControlMs, atMs >= committedFrame / MediaMasterProfile.framesPerMs,
      atMs <= MediaMasterProfile.maximumDurationMs
    else {
      throw CaptureError.invalidAudio
    }
    lastControlMs = atMs
    microphoneEnabled = enabled
    microphonePolicy.append((atMs * MediaMasterProfile.framesPerMs, enabled))
    if !enabled { try discardMicrophone(fromMs: atMs) }
  }

  public func discardMicrophone(fromMs: Int) throws {
    guard fromMs >= committedFrame / MediaMasterProfile.framesPerMs,
      fromMs <= MediaMasterProfile.maximumDurationMs
    else { throw CaptureError.invalidAudio }
    let start = max(0, fromMs * MediaMasterProfile.framesPerMs - committedFrame)
    if start < samples[0].count {
      for index in start..<samples[0].count { samples[0][index] = nil }
    }
  }

  public func setMicrophoneAvailable(_ available: Bool, atMs: Int) throws {
    guard atMs >= committedFrame / MediaMasterProfile.framesPerMs,
      atMs <= MediaMasterProfile.maximumDurationMs,
      atMs * MediaMasterProfile.framesPerMs >= (microphoneAvailability.last?.frame ?? 0)
    else { throw CaptureError.invalidAudio }
    microphoneAvailability.append((atMs * MediaMasterProfile.framesPerMs, available))
    if !available { try discardMicrophone(fromMs: atMs) }
  }

  @discardableResult public func flush(throughMs: Int) throws -> RecordedAudioLevels {
    guard throughMs >= committedFrame / MediaMasterProfile.framesPerMs,
      throughMs <= MediaMasterProfile.maximumDurationMs
    else {
      throw CaptureError.durationLimit
    }
    var measurement = RecordedAudioMeasurement(
      fromFrame: max(
        committedFrame,
        throughMs * MediaMasterProfile.framesPerMs - MediaMasterProfile.sampleRate / 2
      ),
      microphoneFromFrame: max(
        microphonePolicy.last?.frame ?? 0,
        microphoneAvailability.last?.frame ?? 0
      )
    )
    while committedFrame < throughMs * MediaMasterProfile.framesPerMs {
      let count = min(
        MediaMasterProfile.sampleRate,
        throughMs * MediaMasterProfile.framesPerMs - committedFrame
      )
      ensureCapacity(count)
      var interleaved = [Int16]()
      interleaved.reserveCapacity(count * 2)
      var nextSpans: [[CaptureInterval]] = [[], []]
      for millisecond in stride(from: 0, to: count, by: MediaMasterProfile.framesPerMs) {
        let absoluteMs = (committedFrame + millisecond) / MediaMasterProfile.framesPerMs
        let microphonePresent =
          microphoneAvailability.last(where: { $0.frame <= committedFrame + millisecond })?
          .available ?? true
        for track in 0...1 {
          let muted = track == 0 && !microphoneAllowed(at: committedFrame + millisecond)
          let available = samples[track][
            millisecond..<(millisecond + MediaMasterProfile.framesPerMs)
          ]
          .allSatisfy { $0 != nil }
          mergeCaptureInterval(
            .init(
              startMs: absoluteMs,
              endMs: absoluteMs + 1,
              state: track == 0 && !microphonePresent
                ? .unavailable : muted ? .muted : available ? .recorded : .unavailable
            ),
            into: &nextSpans[track]
          )
        }
        for index in millisecond..<(millisecond + MediaMasterProfile.framesPerMs) {
          interleaved.append(
            microphonePresent && microphoneAllowed(at: committedFrame + index)
              ? samples[0][index] ?? 0 : 0
          )
          interleaved.append(samples[1][index] ?? 0)
        }
      }
      try writer.append(
        interleaved: interleaved,
        microphoneIntervals: nextSpans[0],
        applicationIntervals: nextSpans[1]
      )
      // Only the exact successfully appended samples may drive visible activity.
      measurement.include(interleaved, startFrame: committedFrame)
      for track in 0...1 {
        samples[track].removeFirst(count)
      }
      committedFrame += count
      // Retain only the policy active at the committed boundary and later changes.
      while microphonePolicy.count > 1 && microphonePolicy[1].frame <= committedFrame {
        microphonePolicy.removeFirst()
      }
      while microphoneAvailability.count > 1 && microphoneAvailability[1].frame <= committedFrame {
        microphoneAvailability.removeFirst()
      }
    }
    var levels = measurement.levels
    if !microphoneEnabled || microphoneAvailability.last?.available == false {
      levels.microphoneRMS = 0
    }
    return levels
  }

  private func ensureCapacity(_ count: Int) {
    for track in 0...1 where samples[track].count < count {
      samples[track].append(contentsOf: repeatElement(nil, count: count - samples[track].count))
    }
  }

  private func microphoneAllowed(at frame: Int) -> Bool {
    microphonePolicy.last(where: { $0.frame <= frame })?.enabled ?? true
  }

  private func channel(_ role: MediaSourceRole) -> Int { role == .microphone ? 0 : 1 }
}

func mergeCaptureInterval(_ span: CaptureInterval, into spans: inout [CaptureInterval]) {
  if let last = spans.last, last.endMs == span.startMs, last.state == span.state {
    spans[spans.count - 1].endMs = span.endMs
  } else {
    spans.append(span)
  }
}

func clippedCaptureIntervals(
  _ spans: [CaptureInterval],
  startMs: Int,
  endMs: Int
)
  -> [CaptureInterval]
{
  spans.compactMap { span in
    let start = max(startMs, span.startMs)
    let end = min(endMs, span.endMs)
    return end > start ? .init(startMs: start, endMs: end, state: span.state) : nil
  }
}
