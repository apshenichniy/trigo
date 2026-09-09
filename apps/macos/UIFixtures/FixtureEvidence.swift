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
  private var observations: [AnyCancellable] = []
  private var timer: Timer?

  init(
    root: URL,
    composition: DesktopComposition,
    shell: DesktopShell,
    shortcut: GlobalRecordingShortcut? = nil
  ) {
    self.root = root
    self.composition = composition
    self.shell = shell
    self.shortcut = shortcut
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
      let value: [String: Any] = [
        "schemaVersion": 1, "fixture": true, "bundleId": Bundle.main.bundleIdentifier!,
        "archiveRoot": composition.namespace.archive.path, "archiveId": repository.archiveID,
        "bootstrapped": shell.didBootstrap, "phase": String(describing: shell.recording.phase),
        "canStart": shell.recording.canStart,
        "microphoneEnabled": shell.recording.microphoneEnabled,
        "activationPolicy": NSApp.activationPolicy().rawValue,
        "credentialAdapter": "memory-fixture", "statusAdapter": "in-process-fixture",
        "captureAdapter": "no-input-fixture",
        "globalShortcut": shortcut == nil ? "disabled" : "in-process-fixture",
        "gestureState": shortcut?.gesture.status.rawValue ?? "disabled",
        "gestureEnabled": shortcut?.gesture.isEnabled ?? false,
        "callIds": calls.map(\.callID), "source": shell.recording.source?.applicationName ?? "",
      ]
      try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        .write(to: root.appendingPathComponent("state.json"), options: .atomic)
    } catch {
      try? Data("Fixture evidence unavailable\n".utf8)
        .write(to: root.appendingPathComponent("evidence-error.txt"))
    }
  }
}
