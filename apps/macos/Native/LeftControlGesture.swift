import Carbon.HIToolbox
import CoreGraphics
import IOKit.hidsystem

/// Only event identity, modifier state and monotonic time cross this boundary.
/// No characters, event history or input diagnostics are retained.
struct RecordingGestureInput {
  enum Kind { case leftControl(Bool), cancellation, pointerMovement }
  var kind: Kind
  var timestamp: UInt64
  var neutral: Bool

  static func decode(type: CGEventType, event: CGEvent) -> Self {
    let flags = event.flags
    let left = flags.rawValue & UInt64(NX_DEVICELCTLKEYMASK) != 0
    let right = flags.rawValue & UInt64(NX_DEVICERCTLKEYMASK) != 0
    let other =
      !flags.intersection([
        .maskShift, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn,
      ])
      .isEmpty
    let neutral = !left && !right && !other && !flags.contains(.maskControl)
    let kind: Kind
    if type == .mouseMoved {
      kind = .pointerMovement
    } else if type == .flagsChanged,
      event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_Control),
      !right, !other,
      flags.contains(.maskControl) == left
    {
      kind = .leftControl(left)
    } else {
      kind = .cancellation
    }
    return .init(kind: kind, timestamp: event.timestamp, neutral: neutral)
  }
}

/// Two complete clean taps, once on the second release. Timing uses CG's nanoseconds.
struct LeftControlGesture {
  static let maximumPress: UInt64 = 250_000_000
  static let maximumGap: UInt64 = 350_000_000
  private enum Phase { case idle, firstPress(UInt64), firstRelease(UInt64), secondPress(UInt64) }
  private var phase: Phase = .idle
  private var lastTimestamp: UInt64?
  private var needsNeutral = false

  mutating func reset(neutral: Bool = true) {
    phase = .idle
    lastTimestamp = nil
    needsNeutral = !neutral
  }

  mutating func consume(_ input: RecordingGestureInput) -> Bool {
    if case .pointerMovement = input.kind { return false }
    if let lastTimestamp, input.timestamp <= lastTimestamp {
      reset(neutral: input.neutral)
      return false
    }
    lastTimestamp = input.timestamp
    if case .cancellation = input.kind {
      phase = .idle
      needsNeutral = !input.neutral
      return false
    }
    guard case .leftControl(let down) = input.kind else { return false }
    if needsNeutral {
      if input.neutral { needsNeutral = false }
      return false
    }
    switch (phase, down) {
    case (.idle, true): phase = .firstPress(input.timestamp)
    case (.firstPress(let start), false):
      phase = input.timestamp - start <= Self.maximumPress ? .firstRelease(input.timestamp) : .idle
    case (.firstRelease(let release), true):
      phase =
        input.timestamp - release <= Self.maximumGap
        ? .secondPress(input.timestamp) : .firstPress(input.timestamp)
    case (.secondPress(let start), false):
      phase = .idle
      return input.timestamp - start <= Self.maximumPress
    default:
      phase = .idle
      needsNeutral = !input.neutral
    }
    return false
  }
}
