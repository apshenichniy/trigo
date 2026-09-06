import SwiftUI
import TrigoNative

struct RecordingPanel: View {
  @ObservedObject var coordinator: RecordingCoordinator
  @ObservedObject var shortcut: GlobalRecordingShortcut
  let openConnection: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label(
            stateTitle,
            systemImage: coordinator.phase == .recording ? "record.circle.fill" : "waveform"
          )
          .font(.headline)
          .foregroundStyle(coordinator.phase == .recording ? .red : .primary)
          .accessibilityIdentifier("recording-state")
          Spacer()
          Text(elapsed).font(.title2.monospacedDigit())
            .accessibilityLabel("Elapsed time, \(elapsed)")
            .accessibilityIdentifier("recording-elapsed")
        }

        VStack(alignment: .leading, spacing: 4) {
          Text(coordinator.pinnedSource?.applicationName ?? "No application selected").font(
            .headline)
          Text(
            coordinator.pinnedSource.map {
              $0.windowTitle ?? "Window title unavailable. All application windows may be included."
            }
              ?? "Focus the target application and press the shortcut."
          )
          .font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("recording-source")

        HStack {
          Button("Start") { Task { await coordinator.startPinnedSource() } }
            .disabled(!coordinator.canStart)
            .accessibilityIdentifier("recording-start")
          Button("Stop") { Task { await coordinator.stop() } }
            .disabled(!coordinator.canStop)
            .accessibilityIdentifier("recording-stop")
          Spacer()
          Text(GlobalRecordingShortcut.label).font(.callout.monospaced())
            .accessibilityLabel("Recording shortcut: Control Option Command R")
            .accessibilityIdentifier("recording-shortcut")
        }
        Divider()
        Label(applicationState, systemImage: "app.dashed")
          .font(.callout).accessibilityIdentifier("application-audio-state")
        VStack(alignment: .leading, spacing: 6) {
          Label(
            coordinator.microphoneRecordingEnabled
              ? "Microphone recording on" : "Microphone recording off",
            systemImage: coordinator.microphoneRecordingEnabled ? "mic.fill" : "mic.slash.fill"
          )
          .accessibilityIdentifier("microphone-recording-policy")
          Label(
            microphoneState,
            systemImage: coordinator.microphoneRecordingEnabled ? "mic" : "mic.slash"
          )
          .accessibilityIdentifier("microphone-state")
          Text(coordinator.recordingSnapshot?.microphone?.name ?? "No active microphone device")
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityIdentifier("microphone-device")
          Button(
            coordinator.isMicrophoneChanging
              ? "Applying microphone change…"
              : coordinator.microphoneRecordingEnabled
                ? "Turn microphone recording off" : "Turn microphone recording on"
          ) {
            Task { await coordinator.toggleMicrophone() }
          }
          .disabled(coordinator.phase != .recording || coordinator.isMicrophoneChanging)
          .accessibilityValue(
            coordinator.microphoneRecordingEnabled
              ? "Microphone recording on" : "Microphone recording off"
          )
          .accessibilityIdentifier("microphone-toggle")
        }
        Text(
          "Captures the whole selected application, not one browser tab. Microphone recording is independent of the call app's mute. Audio levels and activity are not measured."
        )
        .font(.caption).foregroundStyle(.secondary)

        if let notice = coordinator.notice {
          VStack(alignment: .leading, spacing: 4) {
            Text(notice.title).font(.callout.bold())
            Text(notice.message).font(.caption)
          }
          .foregroundStyle(.orange)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("recording-error")
        }
        recoveryStatus
        if let issue = coordinator.connectionRecoveryIssue {
          Text(
            "\(issue.title). \(issue.recoverySuggestion) Open Archive connection to retry the saved connection."
          )
          .font(.caption).foregroundStyle(.orange)
          .accessibilityIdentifier("recording-connection-error")
        }
        if let issue = shortcut.issue {
          Text(issue).font(.caption).foregroundStyle(.orange)
            .accessibilityIdentifier("shortcut-error")
          Button("Retry shortcut registration") { shortcut.register() }
            .accessibilityIdentifier("shortcut-retry")
        }
        if coordinator.connectionSnapshot.binding == nil {
          Text("Connect to your archive before the first recording.").font(.caption)
        } else if !coordinator.connectionSnapshot.serverOperationsAvailable {
          Text("Server operations unavailable. Local recording remains available after recovery.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button("Archive connection…", action: openConnection)
          .accessibilityIdentifier("recording-connection")
      }
      .padding(16)
    }
    .frame(width: 380, height: 560)
    .accessibilityIdentifier("recording-panel")
  }

  @ViewBuilder private var recoveryStatus: some View {
    if coordinator.isRecovering {
      ProgressView("Recovering local recordings…").controlSize(.small)
    } else {
      if !coordinator.recoveryReport.recoveredCallIDs.isEmpty {
        Text(
          "Recovered \(coordinator.recoveryReport.recoveredCallIDs.count) local recording(s). Retained media is preserved; recording was not resumed."
        )
        .font(.caption).accessibilityIdentifier("recording-recovery-summary")
      }
      ForEach(coordinator.recoveryReport.recoveredCalls) { recovered in
        Text("\(recovered.callID): \(recovered.explanation)").font(.caption)
          .accessibilityIdentifier("recording-recovery-cause")
      }
      ForEach(coordinator.recoveryReport.failures) { failure in
        Text("\(failure.callID): \(failure.message)").font(.caption).foregroundStyle(.orange)
          .textSelection(.enabled)
          .accessibilityIdentifier("recording-recovery-error")
      }
      ForEach(coordinator.recoveryReport.warnings) { warning in
        Text("\(warning.callID): \(warning.message)").font(.caption).foregroundStyle(.orange)
          .accessibilityIdentifier("recording-recovery-warning")
      }
    }
    if coordinator.canRetryLocalRecovery {
      Button("Retry local recovery") { Task { await coordinator.retryRecovery() } }
        .disabled(coordinator.isRecovering)
        .accessibilityIdentifier("recording-recovery")
    }
  }

  private var elapsed: String {
    let seconds = max(0, coordinator.recordingSnapshot?.elapsedMs ?? 0) / 1000
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  }
  private var stateTitle: String {
    switch coordinator.phase {
    case .setupRequired: "Setup required"
    case .idle: "Ready to record"
    case .starting: "Starting…"
    case .recording: "Recording"
    case .stopping: "Stopping / cancelling…"
    case .recoveryRequired: "Recovery required"
    case .interrupted: "Recording interrupted"
    case .error: "Action required"
    }
  }
  private var applicationState: String {
    switch coordinator.phase {
    case .recording: "Application audio: capturing"
    case .starting: "Application audio: starting"
    case .stopping: "Application audio: stopping"
    default: "Application audio: not recording"
    }
  }
  private var microphoneState: String {
    switch coordinator.microphoneState {
    case .inactive: "Microphone: not recording"
    case .starting: "Microphone: starting"
    case .recording: "Microphone: recording"
    case .muted: "Microphone: muted in Trigo"
    case .unavailable: "Microphone: unavailable"
    }
  }
}
