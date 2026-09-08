import Foundation

extension DesktopRecordingState {
  public var elapsedText: String {
    let seconds = max(0, elapsedMs) / 1000
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  }

  public var recoveryTitle: String {
    guard finalization.callID != nil, !finalization.isSettled else {
      return "Recording needs recovery"
    }
    if !finalization.captureStopped || finalization.pendingNativeStart {
      return "Cannot confirm recording has stopped"
    }
    return "Recording stopped; saving needs recovery"
  }

  public var recoveryActionTitle: String {
    guard finalization.callID != nil else { return "Retry local recovery" }
    return finalization.captureStopped && !finalization.pendingNativeStart
      ? "Retry saving" : "Retry stopping"
  }

  public var statusDetail: String {
    let save: String
    switch finalization.localSave {
    case .confirmed: save = "Audio is saved on this Mac."
    case .pending, .needsRecovery: save = "The local save is not confirmed. Keep Trigo open."
    case .notRequired: save = ""
    }
    let retirement =
      finalization.pendingNativeStart
      ? "Waiting for a pending native start to retire."
      : finalization.captureStopped ? "" : "Capture termination is not confirmed."
    if phase == .starting {
      return "Starting recording from \(source?.applicationName ?? "the selected application")."
    }
    if phase == .stopping {
      return [statusTitle, save, retirement].filter { !$0.isEmpty }.joined(separator: " ")
    }
    return [statusTitle, notice?.message ?? "", save, retirement].filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  public var sourceDescription: String {
    let name = source?.applicationName ?? "Selected application"
    let window = source?.windowTitle.map { " Selected through \($0)." } ?? ""
    return "\(name).\(window) Recording application audio can include its other windows or tabs."
  }

  public var microphoneHelp: String {
    if microphoneChanging {
      return
        "Applying microphone change. Microphone recording is currently \(microphoneEnabled ? "enabled" : "muted"). Finish remains available."
    }
    if microphoneState == .unavailable {
      return
        "Microphone unavailable. \(microphoneUnavailableReason ?? "Application audio continues; check or connect an input device.")"
    }
    let action = microphoneEnabled ? "Mute" : "Unmute"
    let activity =
      levels.microphoneRMS > 0 && microphoneEnabled ? " Recorded signal is present." : ""
    return
      "\(action) Trigo's microphone recording. This does not change mute in the calling application.\(activity)"
  }

  public var microphoneActivity: Double {
    guard phase == .recording, microphoneState == .recording, microphoneEnabled else { return 0 }
    return Self.displayLevel(levels.microphoneRMS)
  }

  public var applicationActivity: Double {
    phase == .recording ? Self.displayLevel(levels.applicationRMS) : 0
  }

  // One -60...0 dBFS display range; the underlying snapshot retains linear RMS.
  private static func displayLevel(_ rms: Double) -> Double {
    guard rms.isFinite, rms > 0 else { return 0 }
    return min(1, max(0, (20 * log10(rms) + 60) / 60))
  }
}

public struct DesktopRecordingNotification: Equatable, Sendable, Identifiable {
  public let id: UUID
  public let notice: RecordingNotice
  public let isSaved: Bool
  public init(notice: RecordingNotice, isSaved: Bool) {
    id = UUID()
    self.notice = notice
    self.isSaved = isSaved
  }
}
