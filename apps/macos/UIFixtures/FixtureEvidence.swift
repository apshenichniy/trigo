import AppKit
import Combine
import Foundation

@testable import TrigoNative

/// Fixture-only telemetry observes the same shell and real repository used by the views.
@MainActor final class FixtureEvidence {
  private let root: URL
  private let composition: DesktopComposition
  private let shell: DesktopShell
  private let shortcut: GlobalRecordingShortcut?
  private let panel: FixturePanelControl?
  private var observations: [AnyCancellable] = []
  private var timer: Timer?

  init(
    root: URL,
    composition: DesktopComposition,
    shell: DesktopShell,
    shortcut: GlobalRecordingShortcut? = nil,
    panel: FixturePanelControl? = nil
  ) {
    self.root = root
    self.composition = composition
    self.shell = shell
    self.shortcut = shortcut
    self.panel = panel
    observations.append(
      shell.objectWillChange.sink { [weak self] in
        Task { @MainActor in await self?.write() }
      }
    )
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.write() }
    }
    Task { await write() }
  }

  private func write() async {
    do {
      let repository = try LocalRepository(
        root: composition.namespace.archive,
        archiveID: FixtureConfiguration.archiveID
      )
      let calls = try await repository.calls()
      let state = shell.recording
      let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      var value: [String: Any] = [
        "schemaVersion": 1, "fixture": true, "bundleId": Bundle.main.bundleIdentifier!,
        "archiveRoot": composition.namespace.archive.path, "archiveId": repository.archiveID,
        "bootstrapped": shell.didBootstrap, "phase": String(describing: shell.recording.phase),
        "canStart": shell.recording.canStart,
        "recordingVisible": shell.recordingVisible,
        "microphoneEnabled": shell.recording.microphoneEnabled,
        "activationPolicy": NSApp.activationPolicy().rawValue,
        "credentialAdapter": "memory-fixture", "statusAdapter": "in-process-fixture",
        "captureAdapter": panel == nil ? "no-input-fixture" : "synthetic-pcm-fixture",
        "globalShortcut": shortcut == nil ? "disabled" : "in-process-fixture",
        "gestureState": shortcut?.gesture.status.rawValue ?? "disabled",
        "gestureEnabled": shortcut?.gesture.isEnabled ?? false,
        "callIds": calls.map(\.callID), "source": shell.recording.source?.applicationName ?? "",
        "elapsedMs": state.elapsedMs, "microphoneChanging": state.microphoneChanging,
        "microphoneState": String(describing: state.microphoneState),
        "microphoneRMS": state.levels.microphoneRMS,
        "applicationRMS": state.levels.applicationRMS,
        "microphoneNoticeSequence": state.microphoneNoticeSequence,
        "notificationTitle": shell.recordingNotification?.notice.title ?? "",
        "notificationId": shell.recordingNotification?.id.uuidString ?? "",
        "captureStopped": state.finalization.captureStopped,
        "localSave": String(describing: state.finalization.localSave),
        "pendingNativeStart": state.finalization.pendingNativeStart,
        "quitRequirement": String(describing: state.quitRequirement),
        "statusTitle": state.statusTitle, "statusDetail": state.statusDetail,
        "focusOwner": front == "io.github.apshenichniy.trigo.fixture.focus"
          ? "focus-fixture" : front == FixtureConfiguration.bundleID ? "desktop-fixture" : "other",
      ]
      if let panel {
        value["controlSequence"] = panel.sequence
        value["controls"] = panel.commands
        value["controlFailure"] =
          panel.failure ?? panel.application.failure ?? panel.microphone.failure ?? ""
        value["waitingForStart"] = panel.application.waitingForStart
        value["waitingForSave"] = panel.waitingForSave
        value["saveCalls"] = panel.saveCalls
        value["applicationRunning"] = panel.application.running
        value["microphoneRunning"] = panel.microphone.running
        value["applicationBuffers"] = panel.application.emittedBuffers
        value["microphoneBuffers"] = panel.microphone.emittedBuffers
      }
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        .write(to: root.appendingPathComponent("state.json"), options: .atomic)
    } catch {
      try? Data("Fixture evidence unavailable\n".utf8)
        .write(to: root.appendingPathComponent("evidence-error.txt"))
    }
  }
}
