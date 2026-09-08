import SwiftUI
import TrigoNative

struct CaptureReadinessView: View {
  @ObservedObject var shell: DesktopShell
  private var permissions: CapturePermissions { shell.recording.permissions }

  var body: some View {
    GroupBox("Capture readiness") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          permissions.screenAudio
            ? "Screen & system audio: access granted" : "Screen & system audio: access required"
        )
        .accessibilityIdentifier("screen-audio-readiness")
        if !permissions.screenAudio {
          Text("Enable access, or review Trigo's permission in System Settings.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("Enable screen & system audio") {
              Task { await shell.enableAccess(.screenAudio) }
            }
            .disabled(!shell.recording.canConfigureCapture)
            .accessibilityIdentifier("enable-screen-audio")
            Button("Open Screen Recording settings") {
              shell.openAccessSettings(.screenAudio)
            }
            .accessibilityIdentifier("open-screen-audio-settings")
          }
        }
        Text(microphoneAuthorization).accessibilityIdentifier("microphone-authorization")
        if !permissions.microphone {
          if permissions.microphoneAuthorization == .notDetermined {
            Button("Enable microphone access") {
              Task { await shell.enableAccess(.microphone) }
            }
            .disabled(!shell.recording.canConfigureCapture)
            .accessibilityIdentifier("enable-microphone")
          } else {
            Button("Open Microphone settings") { shell.openAccessSettings(.microphone) }
              .accessibilityIdentifier("open-microphone-settings")
          }
        }
        if !permissions.microphoneAvailable {
          Text(
            "No microphone input device. Connect an input; application audio can still record when access is granted."
          )
          .font(.caption).foregroundStyle(.orange)
          .accessibilityIdentifier("microphone-availability")
        }
        Button("Refresh readiness") { shell.refreshReadiness() }
          .accessibilityIdentifier("refresh-capture-readiness")
      }
      .font(.callout)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 6)
    }
    .onAppear { shell.refreshReadiness() }
  }

  private var microphoneAuthorization: String {
    switch permissions.microphoneAuthorization {
    case .notDetermined: "Microphone: access not requested"
    case .authorized: "Microphone: access granted"
    case .denied: "Microphone: access denied. Allow Trigo in System Settings."
    case .restricted: "Microphone: access restricted by system policy. Review device restrictions."
    case .unknown: "Microphone: authorization unavailable. Review System Settings and retry."
    }
  }
}
