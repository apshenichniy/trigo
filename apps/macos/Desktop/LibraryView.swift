import AppKit
import SwiftUI
import TrigoNative

struct LibraryView: View {
  @ObservedObject var model: LibraryModel
  @ObservedObject var shell: DesktopShell
  @State private var sidebarWidth: CGFloat = 300
  @State private var dragWidth: CGFloat?
  @State private var editor: LibrarySpeakerEditorContext?
  @State private var comparison: LibraryConflictContext?

  var body: some View {
    GeometryReader { geometry in
      let limit = max(238, min(420, geometry.size.width - 440))
      let width = min(limit, sidebarWidth)
      HStack(spacing: 0) {
        if model.sidebarVisible {
          sidebar.frame(width: width).librarySurface().padding(.leading, 12).padding(.bottom, 12)
          Color.clear.frame(width: 12).contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0)
                .onChanged { value in
                  if dragWidth == nil { dragWidth = width }
                  sidebarWidth = min(
                    limit,
                    max(238, (dragWidth ?? width) + value.translation.width)
                  )
                }
                .onEnded { _ in dragWidth = nil }
            )
            .accessibilityRepresentation {
              Slider(
                value: Binding(get: { Double(width) }, set: { sidebarWidth = $0 }),
                in: 238...Double(limit)
              ) {
                Text("Call list width")
              }
            }
        }
        detail
      }
      .padding(.top, 6)
      .background(Color(nsColor: .textBackgroundColor))
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-content")
    .sheet(item: $editor) { LibrarySpeakerEditor(model: model, context: $0) }
    .sheet(item: $comparison) { LibraryConflictSheet(model: model, context: $0) }
    .sheet(isPresented: $model.showsDetails) {
      if let call = model.selectedCall {
        LibraryRecordingDetails(model: model, shell: shell, call: call)
      }
    }
    .task { model.start() }
  }

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Library").font(.title3.weight(.semibold)).padding(.horizontal, 22)
        .padding(.vertical, 18)
      List(selection: Binding(get: { model.selectedCallID }, set: { model.selectCall($0) })) {
        ForEach(model.days) { day in
          Section(day.title) {
            ForEach(day.calls) { call in
              callRow(call).tag(call.callID)
                .contextMenu {
                  Button("Recording Details…") {
                    model.selectCall(call.callID); model.showsDetails = true
                  }
                }
            }
          }
        }
      }
      .listStyle(.sidebar).scrollContentBackground(.hidden)
      .accessibilityLabel("Call library").accessibilityIdentifier("library-call-list")
      if let failure = model.synchronization?.failure {
        Label(LibraryFailure.synchronization(failure), systemImage: "wifi.exclamationmark")
          .font(.caption).foregroundStyle(.secondary).padding(16)
      } else if let count = model.synchronization?.pendingRestorationCount, count > 0 {
        Text("Restoring \(count) recordings…").font(.caption).foregroundStyle(.secondary)
          .padding(16)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-sidebar")
  }

  private func callRow(_ call: LibraryCall) -> some View {
    let status = LibraryCallStatus(call)
    return HStack(spacing: 12) {
      LibraryApplicationIcon(bundleID: call.bundleID).frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 5) {
        Text(call.applicationName).font(.body).lineLimit(1)
        Text(
          "\(call.startedDate.formatted(date: .omitted, time: .shortened)) · \(LibraryDate.clock(call.durationMs ?? 0))"
        )
        .font(.callout).foregroundStyle(.secondary)
        Label(status.title, systemImage: status.symbol).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 8).frame(minHeight: 64)
    .help(call.sourceDescription).accessibilityElement(children: .combine)
    .accessibilityIdentifier("library-call-\(call.callID)")
  }

  @ViewBuilder private var detail: some View {
    if let call = model.selectedCall {
      VStack(alignment: .leading, spacing: 0) {
        header(call)
        if let failure = model.failure { notice(failure, symbol: "exclamationmark.circle") }
        let status = LibraryCallStatus(call)
        if status.isPending || status.needsAttention { notice(status.title, symbol: status.symbol) }
        if call.lifecycle.capture.state == .interrupted {
          notice(
            "Recording interrupted. \(call.interruptionExplanation)",
            symbol: "exclamationmark.circle"
          )
        }
        if let conflict = model.conflicts.first {
          Button("Compare names on this Mac and server…") {
            model.selectRevision(conflict.revisionID)
            comparison = .init(conflict: conflict)
          }
          .padding(.horizontal, 32).padding(.bottom, 12)
          .accessibilityIdentifier("library-compare-names")
        }
        transcript(call)
        LibraryPlayerView(model: model, shell: shell)
          .librarySurface().padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("library-detail")
    } else {
      VStack(alignment: .leading, spacing: 16) {
        Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.secondary)
        Text(emptyTitle).font(.title2.weight(.semibold))
        if let failure = model.failure {
          Text(failure).foregroundStyle(.secondary)
          Button("Try Again") { Task { await model.refresh(force: true) } }
        } else if model.isLoading {
          ProgressView().accessibilityLabel("Loading local recordings")
        } else {
          Text(
            model.needsConnection
              ? "Connect this copy of Trigo to your archive in Settings."
              : "Focus the application you want to record, then use the recording shortcut."
          )
          .foregroundStyle(.secondary)
          Button("Start Recording") { shell.startOrReveal(from: .library) }
            .disabled(!shell.recording.canStart || !shell.recording.permissions.ready)
            .accessibilityIdentifier("library-start-recording")
          if !shell.recording.canStart || !shell.recording.permissions.ready {
            Text(shell.recording.statusTitle).font(.callout).foregroundStyle(.secondary)
          }
          Button("Open Settings…") { shell.showSettings(.connection) }
            .accessibilityIdentifier("library-open-settings")
        }
      }
      .frame(maxWidth: 440, alignment: .leading).padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("library-detail")
    }
  }

  private var emptyTitle: String {
    if model.failure != nil { return "Local archive needs attention" }
    if model.isLoading { return "Opening your recordings" }
    if model.needsConnection { return "Connect your archive" }
    if (model.synchronization?.pendingRestorationCount ?? 0) > 0 {
      return "Restoring your recordings"
    }
    if model.synchronization?.failure != nil { return "Waiting for your archive" }
    return "No recordings yet"
  }

  private func header(_ call: LibraryCall) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(call.sourceDescription).font(.title2.weight(.semibold))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("library-source")
      Text(
        "\(call.startedDate.formatted(date: .long, time: .shortened)) · \(LibraryDate.clock(call.durationMs ?? 0))"
      )
      .font(.callout).foregroundStyle(.secondary)
      if !model.revisions.isEmpty {
        Picker(
          "Transcript revision",
          selection: Binding(
            get: { model.selectedRevisionID ?? "" },
            set: { model.selectRevision($0) }
          )
        ) {
          ForEach(model.revisions) { revision in
            Text(
              "\(LibraryDate.date(revision.createdAt).formatted(date: .abbreviated, time: .shortened))\(revision.revisionID == call.activeRevisionID ? " · Current" : " · Retained")"
            )
            .tag(revision.revisionID)
          }
        }
        .pickerStyle(.menu).fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("library-revision-picker")
      }
    }
    .padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 20)
  }

  private func notice(_ message: String, symbol: String) -> some View {
    Label(message, systemImage: symbol).font(.callout).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 32).padding(.bottom, 12)
  }

  @ViewBuilder private func transcript(_ call: LibraryCall) -> some View {
    if let revision = model.selectedRevision {
      if revision.turnCount == 0 {
        VStack(alignment: .leading, spacing: 12) {
          Text("No speech detected").font(.title3.weight(.semibold))
          Text(
            "This transcript contains no detected speech. The recording and its metadata remain available."
          )
          .foregroundStyle(.secondary)
          Spacer()
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            ForEach(model.turns, id: \.turnID) { turn in
              passage(turn, call: call, revision: revision)
            }
            if model.hasMoreTurns {
              Button("Load more passages") { Task { await model.loadMoreTurns() } }
                .disabled(model.isReading).accessibilityIdentifier("library-more-passages")
            }
          }
          .padding(.horizontal, 32).padding(.bottom, 24)
        }
        .id("\(call.callID):\(revision.revisionID)")
        .accessibilityLabel("Transcript passages").accessibilityIdentifier("library-transcript")
      }
    } else {
      VStack(alignment: .leading, spacing: 14) {
        Text(
          call.lifecycle.capture.state == .recording ? "Recording in progress" : "Saved on this Mac"
        )
        .font(.title3.weight(.semibold))
        Text("The transcript will appear here after server processing and local import.")
          .foregroundStyle(.secondary)
        if LibraryCallStatus(call).isPending || model.isReading {
          ProgressView().controlSize(.small)
        }
        Button("Recording Details…") { model.showsDetails = true }
        Spacer()
      }
      .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func passage(_ turn: LocalTurn, call: LibraryCall, revision: LibraryRevision) -> some View
  {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Button(LibraryDate.clock(turn.startMs)) {
          Task { await model.seek(to: turn.startMs, play: true) }
        }
        .buttonStyle(.plain).disabled(!model.canPlay).monospacedDigit()
        .help(model.playbackReason ?? "Play this passage")
        .accessibilityLabel("Play from \(LibraryDate.clock(turn.startMs))")
        .accessibilityIdentifier("library-timestamp-\(turn.turnID)")
        if let speaker = model.speakers.first(where: { $0.speakerID == turn.speakerID }) {
          Menu {
            Button("Rename…") {
              editor = .init(
                call: call,
                revision: revision,
                speakers: model.speakers,
                speaker: speaker,
                mode: .rename
              )
            }
            Button("Group with…") {
              editor = .init(
                call: call,
                revision: revision,
                speakers: model.speakers,
                speaker: speaker,
                mode: .group
              )
            }
            if speaker.groupID != nil {
              Button("Manage group…") {
                editor = .init(
                  call: call,
                  revision: revision,
                  speakers: model.speakers,
                  speaker: speaker,
                  mode: .manage
                )
              }
            }
          } label: {
            Text(speaker.displayName)
          }
          .menuStyle(.borderlessButton).fixedSize()
          .help(
            "\(speaker.trackRole.capitalized) · \(speaker.neutralLabel) · Scope \(speaker.diarizationScopeID)"
          )
          .accessibilityLabel("Speaker actions for \(speaker.displayName)")
          .accessibilityIdentifier("library-speaker-\(turn.turnID)")
        } else {
          Text("Unknown speaker")
        }
      }
      .font(.subheadline).foregroundStyle(.secondary)
      Text(turn.text).font(.body).lineSpacing(2).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-turn-\(turn.turnID)")
  }
}

struct LibraryPlayerView: View {
  @ObservedObject var model: LibraryModel
  @ObservedObject var shell: DesktopShell
  @State private var seeking: Double?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 14) {
        Button {
          Task { await model.togglePlayback() }
        } label: {
          Image(systemName: model.playback.phase == .playing ? "pause.fill" : "play.fill")
            .frame(width: 30, height: 36)
        }
        .buttonStyle(.plain).disabled(!model.canPlay)
        .accessibilityLabel(model.playback.phase == .playing ? "Pause playback" : "Play recording")
        .accessibilityIdentifier("library-play-pause")
        Text(LibraryDate.clock(model.playback.positionMs)).font(.callout).monospacedDigit()
          .accessibilityIdentifier("library-playback-position")
        Slider(
          value: Binding(
            get: { seeking ?? Double(model.playback.positionMs) },
            set: { seeking = $0 }
          ),
          in: 0...Double(max(1, model.selectedCall?.durationMs ?? 1)),
          onEditingChanged: { editing in
            if !editing, let position = seeking {
              seeking = nil
              Task { await model.seek(to: Int(position), play: false) }
            }
          }
        )
        .disabled(!model.canPlay).accessibilityLabel("Playback position")
        .accessibilityIdentifier("library-playback-slider")
        Text(LibraryDate.clock(model.selectedCall?.durationMs ?? 0)).font(.callout)
          .monospacedDigit()
        if model.playback.phase == .loading {
          ProgressView().controlSize(.small).accessibilityLabel("Loading audio")
        }
      }
      if let reason = model.playbackReason {
        Text(reason).font(.caption).foregroundStyle(.secondary)
      }
      if model.playback.failure == .accessBlocked {
        Button("Connection Settings…") { shell.showSettings(.connection) }
          .accessibilityIdentifier("library-playback-settings")
      }
      if model.canRetryPlayback {
        Button("Retry Playback") { Task { await model.retryPlayback() } }
          .accessibilityIdentifier("library-retry-playback")
      }
    }
    .padding(.horizontal, 20).padding(.vertical, 12)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-player")
  }
}

private struct LibraryApplicationIcon: View {
  let bundleID: String
  var body: some View {
    Group {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
      } else {
        Image(systemName: "app").resizable().scaledToFit().padding(4)
      }
    }
    .accessibilityHidden(true)
  }
}

extension View {
  @ViewBuilder func librarySurface() -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: .rect(cornerRadius: 22))
    } else {
      background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
  }
}
