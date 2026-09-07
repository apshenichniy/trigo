import SwiftUI
import TrigoNative

struct CaptureReadinessView: View {
  @ObservedObject var coordinator: RecordingCoordinator

  var body: some View {
    GroupBox("Capture readiness") {
      VStack(alignment: .leading, spacing: 10) {
        Text(
          coordinator.capturePermissions.screenAudio
            ? "Screen & system audio: access granted" : "Screen & system audio: access required"
        )
        .accessibilityIdentifier("screen-audio-readiness")
        if !coordinator.capturePermissions.screenAudio {
          Text("Enable access, or review Trigo's permission in System Settings.")
            .font(.caption).foregroundStyle(.secondary)
          HStack {
            Button("Enable screen & system audio") {
              Task { await coordinator.enableCaptureAccess(.screenAudio) }
            }
            .disabled(!coordinator.canConfigureCapture)
            Button("Open Screen Recording settings") {
              coordinator.openCaptureSettings(.screenAudio)
            }
          }
        }
        Text(microphoneAuthorization).accessibilityIdentifier("microphone-authorization")
        if !coordinator.capturePermissions.microphone {
          if coordinator.capturePermissions.microphoneAuthorization == .notDetermined {
            Button("Enable microphone access") {
              Task { await coordinator.enableCaptureAccess(.microphone) }
            }
            .disabled(!coordinator.canConfigureCapture)
          } else {
            Button("Open Microphone settings") { coordinator.openCaptureSettings(.microphone) }
          }
        }
        if !coordinator.capturePermissions.microphoneAvailable {
          Text(
            "No microphone input device. Connect an input; application audio can still record when access is granted."
          )
          .font(.caption).foregroundStyle(.orange)
          .accessibilityIdentifier("microphone-availability")
        }
        Button("Refresh readiness") { coordinator.refreshCaptureReadiness() }
          .accessibilityIdentifier("refresh-capture-readiness")
      }
      .font(.callout)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 6)
    }
    .onAppear { coordinator.refreshCaptureReadiness() }
  }

  private var microphoneAuthorization: String {
    switch coordinator.capturePermissions.microphoneAuthorization {
    case .notDetermined: "Microphone: access not requested"
    case .authorized: "Microphone: access granted"
    case .denied: "Microphone: access denied. Allow Trigo in System Settings."
    case .restricted: "Microphone: access restricted by system policy. Review device restrictions."
    case .unknown: "Microphone: authorization unavailable. Review System Settings and retry."
    }
  }
}
