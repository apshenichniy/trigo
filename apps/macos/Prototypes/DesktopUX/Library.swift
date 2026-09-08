import AppKit
import SwiftUI

struct AppIcon: View {
    let bundle: String
    var size: CGFloat = 40
    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
            } else {
                Image(systemName: "app").resizable().scaledToFit().padding(5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct LibraryView: View {
    @ObservedObject var model: PrototypeModel
    @State private var showExport = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // The actual NSWindow supplies the title and traffic lights.
                HStack(spacing: 18) {
                    Spacer()
                    Button { showExport = true } label: { Image(systemName: "square.and.arrow.up").font(.body) }
                        .help("Export transcript").accessibilityLabel("Export transcript")
                    libraryMenu
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .frame(height: 40)
                .background(Color(nsColor: .windowBackgroundColor))
                Divider()
                HStack(spacing: 0) {
                    sidebar.frame(width: min(352, max(238, geometry.size.width * 0.289)))
                    Divider()
                    detail
                }
                Divider()
                HStack(spacing: 8) {
                    Spacer()
                    Text("Sample data  ·  Design study").font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .frame(height: 26)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showExport) { exportPreview }
    }

    private var libraryMenu: some View {
        Menu {
            Button("Settings…") { model.openSettings?() }
            Divider()
            Button("Prototype controls…") { model.openControls?() }
        } label: {
            Image(systemName: "ellipsis.circle").resizable().scaledToFit().frame(width: 17, height: 17)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More library actions")
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.groups.enumerated()), id: \.element) { groupIndex, group in
                    if groupIndex > 0 { Divider().padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 14) }
                    Text(group)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 26)
                        .padding(.top, groupIndex == 0 ? 14 : 0)
                        .padding(.bottom, 12)
                    ForEach(model.calls.filter { $0.group == group }) { call in
                        callRow(call).padding(.horizontal, 14).padding(.bottom, 4)
                    }
                }
            }
            .padding(.bottom, 20)
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.76))
        .accessibilityLabel("Call library")
    }

    private func callRow(_ call: SampleCall) -> some View {
        let selected = call.id == model.selectedID
        return Button { model.select(call) } label: {
            HStack(spacing: 12) {
                AppIcon(bundle: call.bundle, size: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.longTitle && selected ? model.sourceTitle : call.source)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(call.time)  ·  \(call.minutes) min")
                        .font(.callout)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    if call.state != .ready {
                        Text(call.state.rawValue).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 56, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor.opacity(0.3) : .clear, lineWidth: 0.8) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(call.source), \(call.date), \(call.time), \(call.minutes) minutes, \(call.state.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.sourceTitle)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text("\(model.selectedCall.date)  ·  \(model.selectedCall.time)  ·  \(model.selectedCall.minutes) min")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    Button { showExport = true } label: {
                        Label("Export", systemImage: "square.and.arrow.up").font(.body)
                    }
                    Button { showExport = true } label: { Image(systemName: "square.and.arrow.up").font(.body) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Export this transcript")
                Menu {
                    Button("Show sample recording details") { model.notice = "Sample · Google Chrome · locally saved audio · provisional speaker labels" }
                    Button("Prototype controls…") { model.openControls?() }
                } label: { Image(systemName: "ellipsis.circle").resizable().scaledToFit().frame(width: 17, height: 17) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More recording actions")
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 24)

            if model.selectedCall.state == .ready || model.selectedCall.state == .interrupted {
                transcript
            } else {
                readingStatus
            }
            Divider()
            player
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.selectedCall.state == .interrupted {
                Label("Recording interrupted · source application closed. Audio saved.", systemImage: "exclamationmark.circle")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.horizontal, 32).padding(.bottom, 18)
            }
            Text("Transcript")
                .font(.headline)
                .padding(.horizontal, 32)
                .padding(.bottom, 18)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 17) {
                        ForEach(sampleTurns) { turn in
                            Button { model.position = Double(turn.time) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(clockText(turn.time))  ·  \(turn.speaker)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    Text(turn.text)
                                        .font(.body)
                                        .lineSpacing(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .overlay(alignment: .leading) {
                                    if model.selectedTurn == turn.id {
                                        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 2).offset(x: -24)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(turn.id)
                            .accessibilityLabel("\(turn.speaker), \(clockText(turn.time)). \(turn.text)")
                            .accessibilityHint("Selects this passage in the sample player")
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                    .padding(.leading, 1)
                }
                .onChange(of: model.selectedID) { _, _ in reader.scrollTo(0, anchor: .top) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var readingStatus: some View {
        let state = model.selectedCall.state
        let symbol: String = switch state {
        case .processing: "text.bubble"
        case .offline: "wifi.slash"
        case .noSpeech: "waveform"
        case .failed: "exclamationmark.bubble"
        default: "text.bubble"
        }
        let title: String = switch state {
        case .processing: "Your recording is saved"
        case .offline: "Waiting for a connection"
        case .noSpeech: "No speech detected"
        case .failed: "Couldn't create a transcript"
        default: "Your recording is saved"
        }
        let description: String = switch state {
        case .processing: "The transcript is being prepared. You can listen to the saved recording below."
        case .offline: "The recording is saved on this Mac. Processing can continue when the connection returns."
        case .noSpeech: "No transcript was produced. You can still listen to the saved recording."
        case .failed: "The recording is saved on this Mac. Try processing it again."
        default: ""
        }
        return VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(description).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440, alignment: .leading)
            if state == .failed || state == .offline {
                Button("Retry") { model.setReading(.processing) }.controlSize(.large)
            }
            if state == .processing { ProgressView().controlSize(.small).accessibilityLabel("Preparing transcript") }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var player: some View {
        HStack(spacing: 21) {
            Button { model.playing.toggle() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 18)).frame(width: 30, height: 40)
            }
            .buttonStyle(.plain)
            .help(model.playing ? "Pause sample playback" : "Play sample timeline (silent)")
            .accessibilityLabel(model.playing ? "Pause sample playback" : "Play sample timeline")
            Text(clockText(Int(model.position))).monospacedDigit().font(.callout).frame(width: 44)
            Slider(value: $model.position, in: 0...Double(model.selectedCall.minutes * 60))
                .accessibilityLabel("Playback position").accessibilityValue(clockText(Int(model.position)))
            Text(clockText(model.selectedCall.minutes * 60)).monospacedDigit().font(.callout)
            Button { model.volume.toggle() } label: {
                Image(systemName: model.volume ? "speaker.wave.2.fill" : "speaker.slash.fill").font(.body).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).accessibilityLabel(model.volume ? "Mute sample playback" : "Unmute sample playback")
        }
        .padding(.horizontal, 30)
        .frame(height: 54)
    }

    private var exportPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sample transcript export").font(.title2.weight(.semibold))
            Text("Preview of the generated sample text.").foregroundStyle(.secondary)
            ScrollView {
                Text(sampleTurns.map { "[\(clockText($0.time))] \($0.speaker)\n\($0.text)" }.joined(separator: "\n\n"))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 260)
            HStack {
                Spacer()
                Button("Done") { showExport = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 520)
    }
}
