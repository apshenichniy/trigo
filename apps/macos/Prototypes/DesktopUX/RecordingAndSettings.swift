import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: PrototypeModel
    @State private var tab = "General"
    @State private var server = "https://example.invalid"
    @State private var token = ""
    @State private var connectionStatus = "Connected · sample"
    var body: some View {
        VStack(spacing: 20) {
            Picker("Settings section", selection: $tab) { ForEach(["General", "Connection", "Diagnostics"], id: \.self) { Text($0) } }
                .pickerStyle(.segmented)
            Form {
                if tab == "General" {
                    Section("Recording") {
                        LabeledContent("Start or show controls", value: "Double Left Control")
                        LabeledContent("Fallback shortcut", value: "Control–Option–Command–R")
                        Text("The gesture starts a recording, or reveals its current controls.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Startup") {
                        Toggle("Launch at login", isOn: $model.launchAtLogin)
                        Text("Login opens Trigo in the menu bar. Recording always starts explicitly.").font(.caption).foregroundStyle(.secondary)
                    }
                } else if tab == "Connection" {
                    Section("Server") {
                        TextField("Server address", text: $server)
                        SecureField("Replacement token", text: $token, prompt: Text("Use a sample value only"))
                        LabeledContent("Status", value: connectionStatus)
                        HStack {
                            Button("Validate and Save") {
                                connectionStatus = "Connected · sample update accepted"
                                token = ""
                            }
                            .disabled(server.isEmpty || token.isEmpty)
                            Button("Retry Saved Connection") {
                                connectionStatus = "Connected · sample connection checked"
                            }
                        }
                    }
                    Text("Use sample values only. This preview sends no requests and saves no credentials.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Section("Recording access") {
                        LabeledContent("Application audio", value: "Available · sample")
                        LabeledContent("Microphone", value: model.microphoneAvailable ? "Available · sample" : "Unavailable · sample")
                        LabeledContent("Recording gesture", value: "Not registered in this preview")
                    }
                    Section("Local recording") {
                        LabeledContent("Current state", value: model.capture.rawValue)
                    }
                }
            }
            .formStyle(.grouped)
            Text("Design study · settings are temporary").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 550, height: 400)
    }
}

struct PrototypeControlsView: View {
    @ObservedObject var model: PrototypeModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Desktop design study").font(.title2.weight(.semibold))
                    Text("Selected library: option 1. All calls, audio levels and transitions are simulated. Speaker labels and reading states are provisional examples.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("Review the library") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Button("Open library") { model.openLibrary?() }; Button("Narrow window") { model.resizeLibrary?(true) }; Button("Reference size") { model.resizeLibrary?(false) } }
                        Picker("Appearance", selection: $model.appearance) { ForEach(["Light", "Dark", "System"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                        Toggle("Long source title", isOn: $model.longTitle)
                        Toggle("Reduce motion", isOn: $model.reduceMotion)
                        Picker("Selected call", selection: Binding(get: { model.selectedCall.state }, set: { model.setReading($0) })) {
                            ForEach(ReadingState.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }.padding(8)
                }
                GroupBox("Walk through recording") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button("Start sample") { model.start() }
                            Button("Show controls") { model.panelVisible = true }
                            Button("Reset to idle") { model.showCapture(.idle) }
                        }
                        HStack { Button("Active recording") { model.showCapture(.recording) }; Button("Interruption") { model.showCapture(.interrupted) } }
                        HStack { Button("Starting status") { model.showCapture(.starting) }; Button("Saving status") { model.showCapture(.saving) } }
                        Toggle("Microphone available", isOn: $model.microphoneAvailable)
                        Toggle("Hold microphone change pending", isOn: $model.microphonePending)
                        Toggle("Microphone signal", isOn: $model.microphoneSignal)
                        Toggle("Application signal", isOn: $model.applicationSignal)
                        Toggle("Make the next save fail", isOn: $model.simulateSaveFailure)
                        HStack { Button("Save failure") { model.showCapture(.saveFailed) }; Button("Stop unconfirmed") { model.showCapture(.stopUnconfirmed) }; Button("Start failure") { model.showCapture(.startFailed) } }
                    }.padding(8)
                }
                HStack { Button("Settings…") { model.openSettings?() }; Spacer() }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Current sample state").font(.headline)
                    Text("\(model.capture.rawValue) · panel \(model.panelVisible ? "visible" : "hidden") · mic \(model.microphonePending ? "pending" : model.microphoneAvailable ? model.microphoneMuted ? "muted" : "enabled" : "unavailable") · reading \(model.selectedCall.state.rawValue)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(24)
        }
        .frame(width: 520, height: 690)
    }
}
