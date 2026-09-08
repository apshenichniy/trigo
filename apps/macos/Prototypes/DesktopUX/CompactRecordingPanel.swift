import SwiftUI

// Owner-selected panel: always dark, icon controls, one level meter and a small elapsed timer.
struct CompactRecordingPanelView: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        HStack(spacing: 8) {
            if model.capture == .recording || model.capture == .saving {
                microphone
                applicationLevel
                Button { model.finish() } label: {
                    Image(systemName: model.capture == .saving ? "arrow.down" : "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(model.capture == .recording ? 1 : 0.4))
                        .frame(width: 28, height: 28)
                        .background(model.capture == .recording ? Color(red: 0.84, green: 0.13, blue: 0.14) : Color(white: 0.24), in: Circle())
                        .overlay { Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5) }
                }
                .buttonStyle(.plain)
                .disabled(model.capture != .recording)
                .help(model.capture == .saving ? "Saving recording on this Mac" : "Finish recording Google Chrome (\(clockText(model.elapsed))) and save on this Mac")
                .accessibilityLabel("Finish recording and save on this Mac")
            } else if model.capture == .starting {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary).frame(width: 30).help("Starting recording from Google Chrome")
                    .accessibilityLabel("Starting recording from Google Chrome")
                Spacer(minLength: 0)
                iconButton("xmark", help: "Cancel start") { model.cancelStart() }
            } else if model.capture == .saveFailed || model.capture == .stopUnconfirmed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 26)
                    .help(recoveryReason).accessibilityLabel(recoveryReason)
                iconButton("arrow.clockwise", help: model.capture == .saveFailed ? "Retry saving. Recording has stopped; the local save is not confirmed." : "Retry stopping. Capture may still be active.") { model.finish() }
                iconButton("gearshape", help: "Open settings and diagnostics") { model.openSettings?() }
                Spacer(minLength: 0)
            } else if model.capture == .interrupted || model.capture == .startFailed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).frame(width: 26)
                    .help(model.capture == .interrupted ? "Recording interrupted: Google Chrome closed. Audio is saved on this Mac." : "Couldn't start: the selected application is unavailable.")
                    .accessibilityLabel(model.capture.rawValue)
                Spacer(minLength: 0)
                iconButton("rectangle.split.2x1", help: "Open library") { model.openLibrary?() }
            } else {
                Image(systemName: model.capture == .saved ? "checkmark.circle.fill" : "record.circle")
                    .foregroundStyle(model.capture == .saved ? .green : .secondary)
                    .help(model.capture == .saved ? "Recording saved on this Mac. The transcript will follow." : "Ready for recording")
                Spacer(minLength: 0)
                iconButton("rectangle.split.2x1", help: "Open library") { model.openLibrary?() }
            }
            iconButton("chevron.down", help: model.capture == .recording ? "Hide controls. Recording continues." : "Hide status. It remains available in the menu bar.", width: 20) { model.panelVisible = false }
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 8)
        .frame(width: 192, height: 44)
        .background(Color(white: 0.085), in: RoundedRectangle(cornerRadius: 11))
        .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(0.16), lineWidth: 0.5) }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sample recording controls. All levels are simulated.")
    }

    private var microphone: some View {
        ZStack {
            iconButton(model.microphoneMuted ? "mic.slash" : "mic", help: microphoneHelp,
                       color: model.microphoneMuted || !model.microphoneAvailable ? .gray : model.micLevel > 0 ? .cyan : .white,
                       enabled: model.capture == .recording && model.microphoneAvailable && !model.microphonePending, width: 34) { model.toggleMicrophone() }
                .font(.system(size: 17))
                .frame(height: 34)
                .background(Color(white: 0.16), in: Circle())
                .background(.cyan.opacity(model.capture == .recording && model.micLevel > 0 ? model.micLevel * 0.14 : 0), in: Circle())
                .overlay { Circle().strokeBorder(.white.opacity(0.07), lineWidth: 0.5) }
                .scaleEffect(model.reduceMotion || model.micLevel == 0 ? 1 : 0.97 + model.micLevel * 0.05)
            if model.microphonePending {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.white.opacity(0.7)).frame(width: 28, height: 28)
                    .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 7)).allowsHitTesting(false)
            } else if !model.microphoneAvailable {
                Image(systemName: "exclamationmark.circle.fill").font(.system(size: 8)).foregroundStyle(.gray).offset(x: 8, y: 8).allowsHitTesting(false)
            }
        }
        .help(microphoneHelp)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(microphoneHelp)
        .disabled(model.capture != .recording || !model.microphoneAvailable || model.microphonePending)
    }

    private var applicationLevel: some View {
        VStack(spacing: 4) {
            Text(clockText(model.elapsed))
                .font(.system(size: 8, weight: .light, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.62))
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(model.capture == .recording && Double(index) / 10 < model.appLevel ? Color.cyan : .white.opacity(0.14))
                        .frame(width: 4, height: 8)
                }
            }
        }
        .frame(width: 64, height: 28)
        .help("Google Chrome · \(clockText(model.elapsed)) · \(model.capture == .saving ? "Saving recording" : "Application audio") · simulated level")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Application audio from Google Chrome, \(clockText(model.elapsed)), \(model.capture == .saving ? "Inactive" : model.applicationSignal ? "Signal present" : "Silent"), simulated")
    }

    private var microphoneHelp: String {
        if model.capture == .saving { return "Recording stopped. Saving on this Mac." }
        if model.microphonePending { return "Applying microphone change. Please wait." }
        if !model.microphoneAvailable { return "Microphone unavailable. No input device. Application audio continues; the microphone will reconnect when available." }
        return model.microphoneMuted ? "Unmute microphone recording" : "Mute Trigo's microphone recording"
    }
    private var recoveryReason: String {
        model.capture == .saveFailed ? "Recording has stopped. The local save is not confirmed. Keep Trigo open and retry saving." : "Cannot confirm recording has stopped. Capture may still be active. Keep Trigo open and retry stopping."
    }
    private func iconButton(_ symbol: String, help: String, color: Color = .white, enabled: Bool = true, width: CGFloat = 28, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: width, height: 28).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(enabled ? color : .gray)
            .disabled(!enabled).help(help).accessibilityLabel(help)
    }
}
