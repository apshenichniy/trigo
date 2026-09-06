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
  private var applicationID: ObjectIdentifier?
  private var microphoneID: ObjectIdentifier?
  init(engine: CaptureRecordingEngine) { self.engine = engine }

  func select(_ streamID: ObjectIdentifier?, for role: MediaSourceRole) {
    if role == .application { applicationID = streamID } else { microphoneID = streamID }
  }

  func receive(
    _ sample: CMSampleBuffer, role: MediaSourceRole,
    streamID: ObjectIdentifier, at time: CMTime
  ) -> CaptureAudioDelivery {
    guard streamID == (role == .application ? applicationID : microphoneID) else { return .ignored }
    do {
      try engine.receive(sample, role: role)
      return .accepted
    } catch {
      if role == .microphone {
        microphoneID = nil
        try? engine.microphoneChanged(nil, at: time)
        return .microphoneUnavailable
      }
      applicationID = nil
      return .applicationFailed
    }
  }
}
