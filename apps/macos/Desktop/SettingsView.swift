import SwiftUI
import TrigoNative

struct DesktopSettingsView: View {
  @ObservedObject var shell: DesktopShell
  @ObservedObject var login: DesktopLoginModel
  let shortcut: GlobalRecordingShortcut?

  var body: some View {
    VStack(spacing: 0) {
      Picker("Settings section", selection: $shell.settingsSection) {
        ForEach(DesktopSettingsSection.allCases, id: \.self) { section in
          Text(section.rawValue).tag(section)
            .accessibilityIdentifier("settings-\(section.rawValue.lowercased())-tab")
        }
      }
      .pickerStyle(.segmented)
      .padding(20)
      .accessibilityIdentifier("settings-section")
      switch shell.settingsSection {
      case .general: general
      case .connection:
        ConnectionView(
          model: shell,
          localConfiguration: shell.composition.namespace.localDevelopment
        )
      case .diagnostics: diagnostics
      }
    }
    .frame(minWidth: 580, minHeight: 520)
    .accessibilityIdentifier("settings-window-content")
  }

  private var general: some View {
    Form {
      Section("Recording") {
        LabeledContent("Start or show controls", value: GlobalRecordingShortcut.gestureLabel)
        LabeledContent("Ordinary shortcut", value: GlobalRecordingShortcut.fallbackName)
        if let shortcut { GestureSettings(gesture: shortcut.gesture) }
        Text(
          "Focus the application to record, then use either shortcut. Use Finish to end the recording."
        )
        .font(.callout).foregroundStyle(.secondary)
        Text("Microphone recording mute affects Trigo only. It does not mute your calling app.")
          .font(.callout).foregroundStyle(.secondary)
      }
      Section("Startup") {
        Toggle(
          "Launch at login",
          isOn: Binding(
            get: { login.status == .enabled || login.status == .requiresApproval },
            set: { enabled in Task { await login.setEnabled(enabled) } }
          )
        )
        .disabled(login.isChanging || login.status == .unavailable)
        .accessibilityIdentifier("launch-at-login")
        Text("Login starts Trigo in the menu bar. Recording always starts explicitly.")
          .font(.callout).foregroundStyle(.secondary)
        if login.isChanging { ProgressView().controlSize(.small) }
        if login.status == .requiresApproval {
          Text("Approval is required in System Settings before Trigo can launch at login.")
            .accessibilityIdentifier("login-approval-required")
        } else if login.status == .unavailable {
          Text("Launch at login is unavailable for this app installation.")
        }
        if let issue = login.issue {
          Text(issue).foregroundStyle(.secondary).accessibilityIdentifier("login-error")
        }
        Button("Open Login Items Settings") { login.openSettings() }
          .accessibilityIdentifier("open-login-settings")
      }
    }
    .formStyle(.grouped)
    .accessibilityIdentifier("settings-general")
  }

  private var diagnostics: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        CaptureReadinessView(shell: shell)
        GroupBox("Recording shortcut") {
          if let shortcut {
            ShortcutDiagnostics(shortcut: shortcut)
          } else {
            Text("Global shortcut registration is disabled in this fixture.")
              .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        GroupBox("Local recording") {
          VStack(alignment: .leading, spacing: 10) {
            Text(shell.recording.statusTitle).accessibilityIdentifier("diagnostics-recording-state")
            if let source = shell.recording.source {
              LabeledContent("Application", value: source.applicationName)
              if let title = source.windowTitle { LabeledContent("Window", value: title) }
            }
            if let notice = shell.recording.notice {
              Text(notice.title).font(.headline)
              Text(notice.message).foregroundStyle(.secondary)
            }
            ForEach(Array(shell.recording.recoveryMessages.enumerated()), id: \.offset) {
              _,
              message in
              Text(message).font(.callout).textSelection(.enabled)
            }
            if shell.recording.canRetryRecovery {
              Button("Retry Local Recovery") { Task { await shell.retryRecovery() } }
                .accessibilityIdentifier("diagnostics-retry-recovery")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
        GroupBox("Server pipeline") {
          VStack(alignment: .leading, spacing: 10) {
            if case .connected(let status) = shell.recording.connection.health {
              LabeledContent("Transcription", value: status.readiness.transcription.rawValue)
              LabeledContent("Call operations", value: status.readiness.callOperations.rawValue)
              ForEach(status.errors) { notice in
                Text("\(notice.code): \(notice.message)").font(.callout).textSelection(.enabled)
              }
            } else {
              Text("Server readiness is unavailable. Retained local recordings remain on this Mac.")
                .foregroundStyle(.secondary)
            }
            Button("Open Connection Settings") { shell.settingsSection = .connection }
              .accessibilityIdentifier("diagnostics-open-connection")
          }
          .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
      }
      .padding(20)
    }
    .accessibilityIdentifier("settings-diagnostics")
  }
}

private struct ShortcutDiagnostics: View {
  @ObservedObject var shortcut: GlobalRecordingShortcut

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(
        shortcut.isRegistered
          ? "\(GlobalRecordingShortcut.fallbackName): available" : "Ordinary shortcut unavailable"
      )
      .accessibilityIdentifier("shortcut-readiness")
      if let issue = shortcut.issue {
        Text(issue).font(.callout).foregroundStyle(.secondary)
        Button("Retry Shortcut Registration") { shortcut.register() }
          .accessibilityIdentifier("shortcut-retry")
      }
      GestureSettings(gesture: shortcut.gesture)
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
  }
}

private struct GestureSettings: View {
  @ObservedObject var gesture: RecordingGestureController

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(gesture.status.message)
        .font(.callout).accessibilityIdentifier("gesture-readiness")
      if gesture.isEnabled {
        HStack {
          Button("Disable Gesture") { gesture.disable() }
            .accessibilityIdentifier("gesture-disable")
          if gesture.status != .available {
            Button("Check Again") { gesture.refresh() }
              .accessibilityIdentifier("gesture-refresh")
          }
        }
        if [.permissionRequired, .denied, .revoked, .unavailable].contains(gesture.status) {
          Button("Open Input Monitoring Settings") { gesture.openSettings() }
            .accessibilityIdentifier("gesture-open-settings")
        }
      } else {
        Text(
          "Input Monitoring is required for this gesture. The ordinary shortcut and menu remain available."
        )
        .font(.callout).foregroundStyle(.secondary)
        Button("Enable Double Left Control") { gesture.enable() }
          .accessibilityIdentifier("gesture-enable")
      }
      Text("Press and release Left Control twice. Other apps may also respond to this gesture.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }
}
