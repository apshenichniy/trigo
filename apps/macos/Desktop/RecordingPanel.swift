import SwiftUI
import TrigoNative

/// The accepted 192 × 44-point strip, driven only by acknowledged capture state.
struct RecordingPanel: View {
  @ObservedObject var shell: DesktopShell
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private var state: DesktopRecordingState { shell.recording }

  var body: some View {
    HStack(spacing: 8) {
      if state.phase == .recording {
        microphone
        applicationLevel
        Button {
          Task { await shell.finish() }
        } label: {
          Image(systemName: "stop.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Color(red: 0.84, green: 0.13, blue: 0.14), in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
        .help(
          "Finish recording \(state.source?.applicationName ?? "the selected application") (\(state.elapsedText)) and save on this Mac"
        )
        .accessibilityLabel("Finish recording and save on this Mac")
        .accessibilityIdentifier("recording-finish")
      } else {
        status
      }
      iconButton(
        "chevron.down",
        label: state.phase == .recording
          ? "Hide recording controls. Recording continues."
          : "Hide status. It remains available in the menu bar.",
        width: 20,
        identifier: "recording-hide"
      ) { shell.hideRecording() }
    }
    .font(.system(size: 13, weight: .medium))
    .padding(.horizontal, 8)
    .frame(width: 192, height: 44)
    .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
    }
    .environment(\.colorScheme, .dark)
    .preferredColorScheme(.dark)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      state.phase == .recording
        ? "Recording controls. \(state.sourceDescription)" : state.statusDetail
    )
    .accessibilityIdentifier("recording-panel")
  }

  private var microphone: some View {
    Button {
      Task { await shell.toggleMicrophone() }
    } label: {
      ZStack {
        Image(systemName: state.microphoneEnabled ? "mic" : "mic.slash")
          .font(.system(size: 17))
          .foregroundStyle(microphoneColor)
          .frame(width: 34, height: 34)
          .background(Color(white: 0.16), in: Circle())
          .overlay { Circle().fill(.cyan.opacity(state.microphoneActivity * 0.14)) }
          .overlay { Circle().strokeBorder(.white.opacity(0.07), lineWidth: 0.5) }
          .scaleEffect(
            reduceMotion || state.microphoneActivity == 0
              ? 1 : 0.97 + state.microphoneActivity * 0.05
          )
          .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.microphoneActivity)
        if state.microphoneChanging {
          Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
            .frame(width: 15, height: 15).background(Color(white: 0.22), in: Circle())
            .offset(x: 10, y: 10)
        } else if state.microphoneState == .unavailable {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 9)).foregroundStyle(.orange).offset(x: 9, y: 9)
        }
      }
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(state.microphoneChanging || state.microphoneState == .unavailable)
    .help(state.microphoneHelp)
    .accessibilityLabel(state.microphoneHelp)
    .accessibilityValue(
      state.microphoneChanging
        ? "Change pending"
        : state.microphoneState == .unavailable
          ? "Unavailable" : state.microphoneEnabled ? "Enabled" : "Muted"
    )
    .accessibilityIdentifier("microphone-toggle")
  }

  private var microphoneColor: Color {
    if !state.microphoneEnabled || state.microphoneState == .unavailable { return .gray }
    return state.microphoneActivity > 0 ? .cyan : .white
  }

  private var applicationLevel: some View {
    VStack(spacing: 4) {
      Text(state.elapsedText)
        .font(.system(size: 8, weight: .light, design: .monospaced))
        .monospacedDigit().foregroundStyle(.white.opacity(0.62))
        .accessibilityLabel("Elapsed recording time, \(state.elapsedText)")
        .accessibilityIdentifier("recording-elapsed")
      HStack(spacing: 2) {
        ForEach(0..<10, id: \.self) { index in
          RoundedRectangle(cornerRadius: 1)
            .fill(
              Double(index) / 10 < state.applicationActivity ? Color.cyan : .white.opacity(0.14)
            )
            .frame(width: 4, height: 8)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: state.applicationActivity)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Application audio from \(state.source?.applicationName ?? "the selected application")"
      )
      .accessibilityValue(state.levels.applicationRMS > 0 ? "Recorded signal present" : "Silent")
      .accessibilityIdentifier("recording-application-level")
    }
    .frame(width: 64, height: 28)
    .help(
      "\(state.sourceDescription) Elapsed \(state.elapsedText). Measured recorded application audio."
    )
  }

  @ViewBuilder private var status: some View {
    if state.phase == .starting {
      statusGlyph("arrow.triangle.2.circlepath", color: .secondary)
      statusText("Starting…")
      iconButton("xmark", label: "Cancel start", identifier: "recording-cancel-start") {
        Task { await shell.finish() }
      }
    } else if state.phase == .stopping || state.isRecovering {
      statusGlyph("arrow.down.circle", color: .secondary)
      statusText(state.isRecovering ? "Recovering…" : "Saving…")
      Spacer(minLength: 0)
    } else if state.phase == .recoveryRequired {
      statusGlyph("exclamationmark.triangle.fill", color: .orange)
      statusText(state.finalization.captureStopped ? "Save needs\nrecovery" : "Stop\nunconfirmed")
      if state.canRetryRecovery {
        iconButton(
          "arrow.clockwise",
          label: state.recoveryActionTitle,
          identifier: "recording-recovery"
        ) {
          Task { await shell.retryRecovery() }
        }
      }
      iconButton(
        "gearshape",
        label: "Open settings and diagnostics",
        identifier: "recording-open-settings"
      ) {
        shell.showSettings(settingsDestination)
      }
    } else {
      statusGlyph(
        state.phase == .idle ? "record.circle" : "exclamationmark.circle.fill",
        color: state.phase == .idle ? .secondary : .orange
      )
      statusText(
        state.phase == .interrupted
          ? "Interrupted"
          : state.phase == .error
            ? state.statusTitle : state.phase == .setupRequired ? "Setup required" : "Ready"
      )
      if state.phase == .error && state.canStart && state.source != nil {
        iconButton(
          "arrow.clockwise",
          label: "Retry this source",
          identifier: "recording-retry-start"
        ) {
          Task { await shell.retryStart() }
        }
      }
      if state.phase == .interrupted {
        iconButton(
          "rectangle.split.2x1",
          label: "Open library",
          identifier: "recording-open-library"
        ) { shell.reopen() }
      } else {
        iconButton("gearshape", label: "Open settings", identifier: "recording-open-settings") {
          shell.showSettings(settingsDestination)
        }
      }
    }
  }

  private func statusGlyph(_ symbol: String, color: Color) -> some View {
    Image(systemName: symbol).foregroundStyle(color).frame(width: 20)
      .help(state.statusDetail).accessibilityLabel(state.statusDetail)
      .accessibilityIdentifier("recording-error")
  }

  private func statusText(_ text: String) -> some View {
    Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.8))
      .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
      .help(state.statusDetail).accessibilityLabel(state.statusTitle)
      .accessibilityIdentifier("recording-state")
  }

  private func iconButton(
    _ symbol: String,
    label: String,
    width: CGFloat = 22,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).frame(width: width, height: 28).contentShape(Rectangle())
    }
    .buttonStyle(.plain).foregroundStyle(.white)
    .help(label).accessibilityLabel(label).accessibilityIdentifier(identifier)
  }

  private var settingsDestination: DesktopSettingsSection {
    state.connection.binding == nil ? .connection : .diagnostics
  }
}

struct RecordingNotificationView: View {
  let notification: DesktopRecordingNotification
  let dismiss: () -> Void
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: notification.isSaved ? "checkmark.circle.fill" : "mic.badge.xmark")
        .foregroundStyle(notification.isSaved ? .green : .orange)
      VStack(alignment: .leading, spacing: 4) {
        Text(notification.notice.title).font(.system(size: 12, weight: .semibold))
        Text(notification.notice.message).font(.system(size: 10)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button(action: dismiss) {
        Image(systemName: "xmark").font(.system(size: 10)).frame(width: 18, height: 18)
      }
      .buttonStyle(.plain).accessibilityLabel("Dismiss notification")
    }
    .padding(12).frame(width: 310)
    .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 11))
    .overlay {
      RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.16), lineWidth: 0.5)
    }
    .environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("recording-notification-content")
  }
}
