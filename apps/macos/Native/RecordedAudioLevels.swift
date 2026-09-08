import Foundation

/// Linear RMS of the latest committed half-second, after source admission,
/// overlap rejection and effective microphone suppression. No audio is retained.
public struct RecordedAudioLevels: Equatable, Sendable {
  public var microphoneRMS: Double = 0
  public var applicationRMS: Double = 0
  public init(microphoneRMS: Double = 0, applicationRMS: Double = 0) {
    self.microphoneRMS = microphoneRMS
    self.applicationRMS = applicationRMS
  }
}

struct RecordedAudioMeasurement {
  let fromFrame: Int
  let microphoneFromFrame: Int
  private var microphoneEnergy = 0.0
  private var applicationEnergy = 0.0
  private var microphoneFrames = 0
  private var applicationFrames = 0

  init(fromFrame: Int, microphoneFromFrame: Int) {
    self.fromFrame = fromFrame
    self.microphoneFromFrame = microphoneFromFrame
  }

  mutating func include(_ interleaved: [Int16], startFrame: Int) {
    let first = max(0, fromFrame - startFrame)
    let end = interleaved.count / 2
    guard first < end else { return }
    for frame in first..<end {
      let application = Double(interleaved[frame * 2 + 1]) / 32_768
      applicationEnergy += application * application
      applicationFrames += 1
      if startFrame + frame >= microphoneFromFrame {
        let microphone = Double(interleaved[frame * 2]) / 32_768
        microphoneEnergy += microphone * microphone
        microphoneFrames += 1
      }
    }
  }

  var levels: RecordedAudioLevels {
    .init(
      microphoneRMS: microphoneFrames == 0 ? 0 : sqrt(microphoneEnergy / Double(microphoneFrames)),
      applicationRMS: applicationFrames == 0
        ? 0 : sqrt(applicationEnergy / Double(applicationFrames))
    )
  }
}
