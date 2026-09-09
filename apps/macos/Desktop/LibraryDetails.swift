import SwiftUI
import TrigoNative

struct LibraryRecordingDetails: View {
  @ObservedObject var model: LibraryModel
  @ObservedObject var shell: DesktopShell
  let call: LibraryCall
  @Environment(\.dismiss) private var dismiss

  private var current: LibraryCall { model.calls.first { $0.callID == call.callID } ?? call }
  private var canRetry: Bool {
    [
      current.lifecycle.upload.failure, current.lifecycle.importState.failure,
      current.lifecycle.replica.failure,
    ]
    .compactMap { $0 }.contains { $0.retry != .never }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Recording Details").font(.title2.weight(.semibold))
      Text(current.sourceDescription).textSelection(.enabled)
      Text(
        "Application audio may include other windows or tabs of \(current.applicationName). Microphone recording mute is independent of the calling app."
      )
      .font(.callout).foregroundStyle(.secondary)
      Text(
        "\(current.startedDate.formatted(date: .long, time: .shortened)) · \(LibraryDate.clock(current.durationMs ?? 0))"
      )
      .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(LibraryStage.stages(current)) { stage in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(stage.name); Spacer();
                Text(stage.value.replacingOccurrences(of: "_", with: " ").capitalized)
                  .foregroundStyle(.secondary)
              }
              if let failure = stage.failure {
                Text(failure.code).font(.caption.monospaced()).textSelection(.enabled)
                if stage.name == "Recording" {
                  Text(current.interruptionExplanation).font(.callout).foregroundStyle(.secondary)
                }
              }
            }
          }
          Divider()
          Text("Call ID: \(current.callID)").font(.caption.monospaced()).textSelection(.enabled)
          if let revision = model.selectedRevision {
            Text("Viewed revision: \(revision.revisionID)\nEvidence SHA-256: \(revision.sha256)")
              .font(.caption.monospaced()).textSelection(.enabled)
          }
        }
      }
      .frame(maxHeight: 360)
      HStack {
        if canRetry {
          Button("Retry Upload and Sync") { Task { await model.retrySynchronization() } }
        }
        Button("Connection Settings…") {
          dismiss(); shell.showSettings(.connection)
        }
        Spacer()
        Button("Done", role: .cancel) { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(28).frame(width: 580)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-recording-details")
  }
}

struct LibraryConflictContext: Identifiable {
  let id = UUID()
  let conflict: SpeakerAnnotationConflict
}

struct LibraryConflictSheet: View {
  @ObservedObject var model: LibraryModel
  let context: LibraryConflictContext
  @Environment(\.dismiss) private var dismiss
  @State private var saving = false
  @State private var chosen: SpeakerConflictChoice?
  @State private var failure: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Choose speaker names and groups").font(.title2.weight(.semibold))
      Text(
        "Choose the annotations for this transcript revision. Both versions stay available until you choose; the original transcript and other revisions are retained."
      )
      .font(.callout).foregroundStyle(.secondary)
      ScrollView {
        HStack(alignment: .top, spacing: 24) {
          annotations("This Mac", value: context.conflict.local)
          Divider()
          annotations("Server", value: context.conflict.server)
        }
      }
      .frame(maxHeight: 340)
      if let failure { Text(failure).font(.callout).foregroundStyle(.red) }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
          .disabled(saving)
        Spacer()
        Button("Keep This Mac's Names") { choose(.keepThisMac) }
          .disabled(saving || chosen == .useServer)
          .accessibilityIdentifier("library-conflict-keep-mac")
        Button("Use Server Names") { choose(.useServer) }
          .disabled(saving || chosen == .keepThisMac)
          .accessibilityIdentifier("library-conflict-use-server")
      }
    }
    .padding(28).frame(width: 700)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("library-conflict-comparison")
  }

  private func annotations(_ title: String, value: SpeakerAnnotations) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).font(.headline)
      if value.names.isEmpty && value.groups.isEmpty {
        Text("Original speaker labels; no manual names or groups.").foregroundStyle(.secondary)
      }
      ForEach(value.names.keys.sorted(), id: \.self) { speakerID in
        Text("\(label(speakerID)): \(value.names[speakerID] ?? "")").textSelection(.enabled)
      }
      ForEach(value.groups, id: \.groupId) { group in
        VStack(alignment: .leading, spacing: 4) {
          Text(group.displayName).font(.body.weight(.medium))
          Text(group.speakerIds.map(label).joined(separator: ", ")).font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func label(_ id: String) -> String {
    model.speakers.first { $0.speakerID == id }?.neutralLabel ?? id
  }
  private func choose(_ choice: SpeakerConflictChoice) {
    guard !saving else { return }
    chosen = choice; saving = true; failure = nil
    Task {
      do {
        try await model.resolve(
          context.conflict,
          choice: choice,
          operationID: context.id.uuidString.lowercased()
        )
        dismiss()
      } catch { failure = LibraryFailure.message(error) }
      saving = false
    }
  }
}
