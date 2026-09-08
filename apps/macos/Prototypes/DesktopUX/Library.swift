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
    @State private var showDetails = false
    @State private var sidebarWidth: CGFloat?
    @State private var dividerDragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let sidebarLimit = min(420, max(238, geometry.size.width - 476))
            let width = min(sidebarLimit, max(238, sidebarWidth ?? min(336, geometry.size.width * 0.275)))
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    if model.sidebarVisible {
                        sidebar.frame(width: width)
                            .glassSurface(radius: 22)
                            .padding(.leading, 12)
                            .padding(.bottom, 12)
                        sidebarDivider(width: width, limit: sidebarLimit)
                    }
                    detail
                }
                .padding(.top, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .coordinateSpace(name: "library-layout")
        .sheet(isPresented: $showExport) { exportPreview }
        .alert("Sample recording details", isPresented: $showDetails) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("\(model.selectedCall.source)\n\(model.selectedCall.date) · \(model.selectedCall.time) · \(model.selectedCall.minutes) min\nSynthetic recording with provisional speaker labels.")
        }
    }

    private func sidebarDivider(width: CGFloat, limit: CGFloat) -> some View {
        Color.clear.frame(width: 12)
            .overlay {
                Color.clear.frame(width: 7).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("library-layout"))
                        .onChanged { value in
                            if dividerDragStart == nil { dividerDragStart = width }
                            sidebarWidth = min(limit, max(238, (dividerDragStart ?? width) + value.translation.width))
                        }
                        .onEnded { _ in dividerDragStart = nil })
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
            }
            .accessibilityRepresentation {
                Slider(value: Binding(get: { width }, set: { sidebarWidth = $0 }), in: 238...limit) {
                    Text("Call list width")
                }
            }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Library").font(.title3.weight(.semibold))
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.groups.enumerated()), id: \.element) { groupIndex, group in
                    if groupIndex > 0 { Spacer().frame(height: 20) }
                    Text(group)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 22)
                        .padding(.top, groupIndex == 0 ? 2 : 0)
                        .padding(.bottom, 8)
                    ForEach(model.calls.filter { $0.group == group }) { call in
                        callRow(call).padding(.horizontal, 10).padding(.bottom, 4)
                    }
                }
            }
            .padding(.bottom, 20)
        }
            .accessibilityLabel("Call library")
            Text("Sample data · Design study").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 22).padding(.vertical, 14)
        }
    }

    private func callRow(_ call: SampleCall) -> some View {
        let selected = call.id == model.selectedID
        let title = model.longTitle && selected ? model.sourceTitle : call.source
        return Button { model.select(call) } label: {
            HStack(spacing: 12) {
                AppIcon(bundle: call.bundle, size: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
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
            .frame(minHeight: call.state == .ready ? 56 : 74, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .background(selected ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel("\(title), \(call.date), \(call.time), \(call.minutes) minutes, \(call.state.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.sourceTitle)
                        .font(.title2.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
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
                .glassControl(circle: false)
                .accessibilityLabel("Export this transcript")
                Menu {
                    Button("Show sample recording details") { showDetails = true }
                    Button("Prototype controls…") { model.openControls?() }
                } label: { Image(systemName: "ellipsis").frame(width: 18, height: 18) }
                .menuStyle(.button).menuIndicator(.hidden).fixedSize()
                .glassControl(circle: true)
                .accessibilityLabel("More recording actions")
            }
            .padding(.horizontal, 32)
            .padding(.top, 18)
            .padding(.bottom, 24)

            if model.selectedCall.state == .ready || model.selectedCall.state == .interrupted {
                transcript
            } else {
                readingStatus
            }
            player
                .glassSurface(radius: 22)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 16)
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
                .accessibilityLabel("Transcript passages")
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
        HStack(spacing: 16) {
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
        .padding(.horizontal, 20)
        .frame(height: 60)
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

private extension View {
    @ViewBuilder func glassSurface(radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
        }
    }

    @ViewBuilder func glassControl(circle: Bool) -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass).buttonBorderShape(circle ? .circle : .capsule).controlSize(.large)
        } else {
            self.buttonStyle(.bordered).controlSize(.large)
        }
    }
}
