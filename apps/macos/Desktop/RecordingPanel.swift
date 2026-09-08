import SwiftUI
import TrigoNative

/// Existing safe controls hosted by the shell. The measured compact presentation belongs to #45.
struct RecordingPanel: View {
  @ObservedObject var shell: DesktopShell
  private var state: DesktopRecordingState { shell.recording }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text(state.statusTitle).font(.headline).accessibilityIdentifier("recording-state")
        Spacer()
        Button {
          shell.hideRecording()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).help("Hide recording controls")
        .accessibilityLabel("Hide recording controls")
        .accessibilityIdentifier("recording-hide")
      }
      if let source = state.source {
        Text(source.applicationName).font(.subheadline.weight(.medium))
          .help(source.windowTitle ?? source.applicationName)
          .accessibilityIdentifier("recording-source")
      }
      if state.phase == .recording {
        HStack(spacing: 16) {
          Text(elapsed).font(.title2.monospacedDigit())
            .accessibilityLabel("Elapsed time, \(elapsed)")
            .accessibilityIdentifier("recording-elapsed")
          Spacer()
          Button {
            Task { await shell.toggleMicrophone() }
          } label: {
            Image(systemName: state.microphoneEnabled ? "mic.fill" : "mic.slash.fill")
          }
          .disabled(state.microphoneChanging || state.microphoneState == .unavailable)
          .help(microphoneLabel)
          .accessibilityLabel(microphoneLabel)
          .accessibilityIdentifier("microphone-toggle")
          Button("Finish") { Task { await shell.finish() } }
            .accessibilityLabel("Finish recording")
            .accessibilityIdentifier("recording-finish")
        }
        if state.microphoneChanging {
          Text("Applying microphone change…").font(.caption)
        } else if state.microphoneState == .unavailable {
          Text("Microphone unavailable. Application audio continues.").font(.caption)
        }
      } else if state.phase == .starting {
        Button("Cancel Start") { Task { await shell.finish() } }
          .accessibilityIdentifier("recording-cancel-start")
      } else if state.phase == .stopping || state.isRecovering {
        ProgressView("Waiting for recording to finish safely…").controlSize(.small)
      }
      if let notice = state.notice {
        Text(notice.message).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("recording-error")
      }
      if state.canRetryRecovery {
        Button("Retry Local Recovery") { Task { await shell.retryRecovery() } }
          .accessibilityIdentifier("recording-recovery")
      } else if state.phase == .error && state.canStart && state.source != nil {
        Button("Retry This Source") { Task { await shell.retryStart() } }
          .accessibilityIdentifier("recording-retry-start")
      }
      if state.phase != .recording {
        Button("Open Settings…") { shell.showSettings(settingsDestination) }
          .accessibilityIdentifier("recording-open-settings")
      }
    }
    .padding(20)
    .frame(width: 360)
    .accessibilityIdentifier("recording-panel")
  }

  private var elapsed: String {
    let seconds = max(0, state.elapsedMs) / 1000
    return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
  }
  private var microphoneLabel: String {
    if state.microphoneChanging { return "Applying microphone change" }
    if state.microphoneState == .unavailable { return "Microphone unavailable" }
    return state.microphoneEnabled ? "Mute microphone recording" : "Unmute microphone recording"
  }
  private var settingsDestination: DesktopSettingsSection {
    state.connection.binding == nil ? .connection : .diagnostics
  }
}
