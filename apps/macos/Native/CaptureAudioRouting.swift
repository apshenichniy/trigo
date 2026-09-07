import CoreMedia
import Foundation
import TrigoContracts

enum CaptureAudioDelivery: Equatable {
  case accepted, ignored, microphoneUnavailable, applicationFailed
}

/// Stream identity admission and source fault isolation, shared by the actual SCK
/// callback and controlled adapters. Its owner is the same serial queue as the engine.
final class CaptureAudioRouting {
  private let engine: CaptureRecordingEngine
  private let selection: CaptureStreamSelection
  init(engine: CaptureRecordingEngine, selection: CaptureStreamSelection = CaptureStreamSelection())
  {
    self.engine = engine
    self.selection = selection
  }

  func select(_ streamID: ObjectIdentifier?, for role: MediaSourceRole) {
    selection.select(streamID, for: role)
  }

  func receive(
    _ sample: CMSampleBuffer,
    role: MediaSourceRole,
    streamID: ObjectIdentifier,
    at time: CMTime
  ) -> CaptureAudioDelivery {
    guard selection.accepts(streamID, for: role) else { return .ignored }
    do {
      try engine.receive(sample, role: role)
      return .accepted
    } catch {
      if role == .microphone {
        selection.select(nil, for: .microphone)
        try? engine.microphoneChanged(nil, at: time)
        return .microphoneUnavailable
      }
      selection.select(nil, for: .application)
      return .applicationFailed
    }
  }
}

/// Identity gates are shared by pre-queue admission and decode-time routing. Updating a
/// stream and reserving queue capacity are ordered by the same lock.
final class CaptureStreamSelection: @unchecked Sendable {
  private let lock = NSLock()
  private var ids: [ObjectIdentifier?] = [nil, nil]
  func select(
    _ id: ObjectIdentifier?,
    for role: MediaSourceRole,
    update: ([ObjectIdentifier?]) -> Void = { _ in }
  ) {
    lock.withLock {
      ids[role == .microphone ? 0 : 1] = id
      update(ids)
    }
  }
  func withSelection<Value>(_ body: ([ObjectIdentifier?]) -> Value) -> Value {
    lock.withLock { body(ids) }
  }
  func accepts(_ id: ObjectIdentifier, for role: MediaSourceRole) -> Bool {
    withSelection { $0[role == .microphone ? 0 : 1] == id }
  }
}
