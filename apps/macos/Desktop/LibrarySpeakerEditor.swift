import SwiftUI
import TrigoNative

struct LibrarySpeakerEditorContext: Identifiable {
  enum Mode { case rename, group, manage }
  let id = UUID()
  let call: LibraryCall
  let revision: LibraryRevision
  let speakers: [LocalSpeaker]
  let speaker: LocalSpeaker
  let mode: Mode
}

private struct SpeakerChoice: Identifiable {
  let id: String
  let members: [LocalSpeaker]
  var title: String { members[0].displayName }
  var groupID: String? { members[0].groupID }
}

struct LibrarySpeakerEditor: View {
  @ObservedObject var model: LibraryModel
  let context: LibrarySpeakerEditorContext
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var selected: Set<String> = []
  @State private var destination: String?
  @State private var newGroupID = UUID().uuidString.lowercased()
  @State private var saving = false
  @State private var failure: String?
  @State private var pending: SpeakerAnnotationEdit?

  private var sourceKey: String { context.speaker.groupID ?? context.speaker.speakerID }
  private var choices: [SpeakerChoice] {
    var choices: [SpeakerChoice] = []
    var seen: Set<String> = []
    for speaker in context.speakers {
      let key = speaker.groupID ?? speaker.speakerID
      guard seen.insert(key).inserted else { continue }
      choices.append(
        .init(
          id: key,
          members: context.speakers.filter {
            speaker.groupID == nil
              ? $0.speakerID == speaker.speakerID : $0.groupID == speaker.groupID
          }
        )
      )
    }
    return choices
  }
  private var selectedMembers: [LocalSpeaker] {
    choices.filter { selected.contains($0.id) }.flatMap(\.members)
  }
  private var selectedGroups: [SpeakerChoice] {
    choices.filter { selected.contains($0.id) && $0.groupID != nil }
  }
  private var groupMembers: [LocalSpeaker] {
    context.speakers.filter { $0.groupID == context.speaker.groupID }
  }
  private var title: String {
    switch context.mode {
    case .rename: context.speaker.groupID == nil ? "Rename speaker" : "Rename group"
    case .group: "Group speaker labels"
    case .manage: "Manage \(context.speaker.displayName)"
    }
  }
  private var valid: Bool {
    switch context.mode {
    case .rename:
      context.speaker.groupID == nil
        || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .group:
      selectedMembers.count >= 2 && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .manage: !selected.isEmpty
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.title2.weight(.semibold))
      Text(
        "These names apply only to the selected transcript revision. Original speech, timing and source labels stay intact."
      )
      .font(.callout).foregroundStyle(.secondary)
      if context.mode != .manage {
        TextField(context.mode == .group ? "Group name" : "Display name", text: $name)
          .textFieldStyle(.roundedBorder).accessibilityIdentifier("speaker-display-name")
          .disabled(pending != nil)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          switch context.mode {
          case .rename:
            Text(
              context.speaker.groupID == nil
                ? "Clearing the name restores the original neutral label."
                : "This shared name affects all of these labels:"
            )
            .font(.callout).foregroundStyle(.secondary)
            ForEach(context.speaker.groupID == nil ? [context.speaker] : groupMembers) {
              inspection($0)
            }
          case .group:
            Text("Select labels or complete groups to combine. No voice identity is inferred.")
              .font(.callout).foregroundStyle(.secondary)
            ForEach(choices) { choice in
              VStack(alignment: .leading, spacing: 8) {
                Toggle(
                  isOn: Binding(
                    get: { selected.contains(choice.id) },
                    set: { include in
                      if include {
                        selected.insert(choice.id);
                        if destination == nil { destination = choice.groupID }
                      } else {
                        selected.remove(choice.id);
                        if destination == choice.groupID {
                          destination = selectedGroups.first?.groupID
                        }
                      }
                    }
                  )
                ) {
                  Text(
                    choice.title
                      + (choice.members.count > 1 ? " · \(choice.members.count) labels" : "")
                  )
                }
                .disabled(choice.id == sourceKey || pending != nil)
                .accessibilityIdentifier("speaker-choice-\(choice.id)")
                DisclosureGroup("Inspect excerpts and sources") {
                  ForEach(choice.members) { inspection($0) }
                }
                .font(.callout)
              }
            }
            if selectedGroups.count > 1 {
              Picker(
                "Add the selected labels to",
                selection: Binding(
                  get: { destination ?? selectedGroups[0].id },
                  set: { destination = $0 }
                )
              ) {
                ForEach(selectedGroups) { Text($0.title).tag($0.id) }
              }
              .disabled(pending != nil)
            }
            Divider()
            Text("Resulting group: \(selectedMembers.map(\.neutralLabel).joined(separator: ", "))")
              .font(.callout).accessibilityIdentifier("speaker-group-result")
          case .manage:
            Text(
              "Select members to remove. Their individual names will return. Fewer than two remaining labels dissolves the group."
            )
            .font(.callout).foregroundStyle(.secondary)
            ForEach(groupMembers) { speaker in
              Toggle(
                isOn: Binding(
                  get: { selected.contains(speaker.speakerID) },
                  set: { include in
                    if include {
                      selected.insert(speaker.speakerID)
                    } else {
                      selected.remove(speaker.speakerID)
                    }
                  }
                )
              ) { inspection(speaker) }
              .disabled(pending != nil)
              .accessibilityIdentifier("speaker-remove-\(speaker.speakerID)")
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 400)
      if let failure {
        Text(failure).font(.callout).foregroundStyle(.red)
          .accessibilityIdentifier("speaker-save-error")
      }
      HStack {
        if context.mode == .manage, let groupID = context.speaker.groupID {
          Button("Ungroup") { submit(.ungroup(groupID: groupID)) }
            .disabled(saving || pending != nil).accessibilityIdentifier("speaker-ungroup")
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
          .disabled(saving)
        Button(
          pending == nil ? (context.mode == .manage ? "Remove Members" : "Save") : "Retry Save"
        ) { submit(mutation) }
        .keyboardShortcut(.defaultAction).disabled(saving || (pending == nil && !valid))
        .accessibilityIdentifier("speaker-save")
      }
    }
    .padding(28).frame(width: 540)
    .onAppear {
      name = context.speaker.groupName ?? context.speaker.individualName ?? ""
      if context.mode == .group { selected = [sourceKey]; destination = context.speaker.groupID }
    }
  }

  private func inspection(_ speaker: LocalSpeaker) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("\(speaker.neutralLabel) · \(speaker.trackRole.capitalized)")
        .font(.callout.weight(.medium))
      if let name = speaker.individualName { Text("Individual name: \(name)").font(.caption) }
      Text(
        "Provider label: \(speaker.providerLabel ?? "unavailable") · Scope: \(speaker.diarizationScopeID)"
      )
      .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      if let excerpt = speaker.excerpt {
        Button("Play \(LibraryDate.clock(excerpt.startMs))") {
          Task { await model.seek(to: excerpt.startMs, play: true) }
        }
        .disabled(!model.canPlay)
        Text(excerpt.text).font(.callout).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
  }

  private var mutation: SpeakerAnnotationMutation {
    switch context.mode {
    case .rename: .rename(speakerID: context.speaker.speakerID, name: name.isEmpty ? nil : name)
    case .group:
      .group(
        groupID: destination ?? newGroupID,
        displayName: name,
        speakerIDs: selectedMembers.map(\.speakerID)
      )
    case .manage:
      .removeMembers(groupID: context.speaker.groupID ?? "", speakerIDs: selected.sorted())
    }
  }

  private func submit(_ mutation: SpeakerAnnotationMutation) {
    guard !saving else { return }
    let edit =
      pending
      ?? SpeakerAnnotationEdit(
        operationID: context.id.uuidString.lowercased(),
        callID: context.call.callID,
        revisionID: context.revision.revisionID,
        expectedDocumentVersion: context.call.documentVersion,
        mutation: mutation
      )
    pending = edit; saving = true; failure = nil
    Task {
      do { try await model.save(edit); dismiss() } catch { failure = LibraryFailure.message(error) }
      saving = false
    }
  }
}
