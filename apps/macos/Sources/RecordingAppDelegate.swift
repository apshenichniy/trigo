import AppKit
import SwiftUI
import TrigoNative

@MainActor final class RecordingAppDelegate: NSObject, NSApplicationDelegate {
  private var coordinator: RecordingCoordinator?
  private var shortcut: GlobalRecordingShortcut?
  private var panel: NSPanel?
  private var terminationPending = false

  func configure(
    coordinator: RecordingCoordinator,
    appName: String,
    openConnection: @escaping () -> Void
  ) {
    guard self.coordinator == nil else { return }
    self.coordinator = coordinator
    let shortcut = GlobalRecordingShortcut { [weak self, weak coordinator] in
      // Do not activate Trigo or show a key window before source selection.
      Task { @MainActor in
        await coordinator?.shortcutPressed()
        self?.showRecordingControls()
      }
    }
    self.shortcut = shortcut
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 560),
      styleMask: [.titled, .closable, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = "\(appName) — Recording"
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(
      rootView: RecordingPanel(
        coordinator: coordinator,
        shortcut: shortcut,
        openConnection: openConnection
      )
    )
    panel.center()
    self.panel = panel
    shortcut.register()
    showRecordingControls()
  }

  func showRecordingControls() { panel?.orderFrontRegardless() }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let coordinator else { return .terminateNow }
    guard !terminationPending else { return .terminateLater }
    terminationPending = true
    Task { @MainActor in
      let safe = await coordinator.prepareForTermination()
      if safe {
        shortcut?.unregister()
        panel?.close()
      } else {
        terminationPending = false
        showRecordingControls()
      }
      sender.reply(toApplicationShouldTerminate: safe)
    }
    return .terminateLater
  }
}
