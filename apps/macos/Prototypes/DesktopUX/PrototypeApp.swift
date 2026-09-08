import AppKit
import SwiftUI

@MainActor final class RecordingPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class PrototypeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = PrototypeModel()
    private var libraryWindow: NSWindow?
    private var panelWindow: NSPanel?
    private var settingsWindow: NSWindow?
    private var controlsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var quittingAfterSave = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        model.onCaptureChange = { [weak self] in self?.updateStatus() }
        model.onPanelVisibilityChange = { [weak self] in self?.updatePanel() }
        model.onAppearanceChange = { [weak self] in self?.updateAppearance() }
        model.openLibrary = { [weak self] in self?.showLibrary() }
        model.openSettings = { [weak self] in self?.showSettings() }
        model.openControls = { [weak self] in self?.showControls() }
        model.resizeLibrary = { [weak self] narrow in self?.resizeLibrary(narrow: narrow) }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateAppearance()
        updateStatus()
        showLibrary()
        if CommandLine.arguments.contains("--controls") { showControls() }
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: "Trigo UX Prototype")
        application.submenu?.addItem(item("Settings…", #selector(showSettings), key: ","))
        application.submenu?.addItem(.separator())
        application.submenu?.addItem(item("Quit Trigo UX Prototype", #selector(quit), key: "q"))
        menu.addItem(application)
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(item("Open Library", #selector(showLibrary), key: "l"))
        file.submenu?.addItem(item("Close Window", #selector(closeKeyWindow), key: "w"))
        menu.addItem(file)
        let review = NSMenuItem(title: "Prototype", action: nil, keyEquivalent: "")
        review.submenu = NSMenu(title: "Prototype")
        review.submenu?.addItem(item("Design Controls…", #selector(showControls), key: "d"))
        review.submenu?.addItem(item("Start Sample Recording", #selector(start)))
        menu.addItem(review)
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        window.submenu = NSMenu(title: "Window")
        window.submenu?.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        window.submenu?.addItem(NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
        window.submenu?.items.last?.keyEquivalentModifierMask = [.control, .command]
        menu.addItem(window)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = window.submenu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc func showLibrary() {
        NSApp.setActivationPolicy(.regular)
        if libraryWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1216, height: 864), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Trigo"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .visible
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 800, height: 590)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.contentView = NSHostingView(rootView: LibraryView(model: model))
            window.delegate = self
            window.center()
            libraryWindow = window
            resizeLibrary(narrow: false)
        }
        libraryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizeLibrary(narrow: Bool) {
        guard let window = libraryWindow, let screen = window.screen ?? NSScreen.main else { return }
        let size = NSSize(width: narrow ? 820 : min(1216, screen.visibleFrame.width - 60), height: min(narrow ? 770 : 864, screen.visibleFrame.height - 20))
        var rect = window.frame
        rect.size = size
        rect.origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        window.setFrame(rect, display: true)
        showLibrary()
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Trigo Settings · Design Study"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showControls() {
        if controlsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 690), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Trigo Prototype Controls"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PrototypeControlsView(model: model))
            window.center()
            controlsWindow = window
        }
        controlsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updatePanel() {
        if model.panelVisible {
            if panelWindow == nil {
                let panel = RecordingPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 192, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "Trigo sample recording controls"
                panel.isFloatingPanel = true
                panel.level = .floating
                panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.appearance = NSAppearance(named: .darkAqua)
                panel.hasShadow = true
                panel.isMovableByWindowBackground = true
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                panel.contentView = NSHostingView(rootView: CompactRecordingPanelView(model: model))
                if let screen = NSScreen.main {
                    panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 226, y: screen.visibleFrame.minY + 100))
                }
                panelWindow = panel
            }
            panelWindow?.orderFrontRegardless()
        } else {
            panelWindow?.orderOut(nil)
        }
    }

    private func updateAppearance() {
        NSApp.appearance = model.appearance == "System" ? nil : NSAppearance(named: model.appearance == "Dark" ? .darkAqua : .aqua)
    }

    private func updateStatus() {
        if let button = statusItem?.button {
            button.title = " UX"
            let symbol = model.capture == .recording ? "record.circle.fill" : model.capture == .saving || model.capture == .starting ? "ellipsis.circle" : "waveform"
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Trigo UX Prototype")
            button.contentTintColor = model.capture == .recording ? .systemRed : nil
            button.toolTip = "Trigo UX Prototype — \(model.capture.rawValue) — sample data"
        }
        let menu = NSMenu()
        menu.delegate = self
        let heading = NSMenuItem(title: "Trigo · Design study", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        if model.capture == .recording {
            menu.addItem(NSMenuItem(title: "Recording Google Chrome · sample", action: nil, keyEquivalent: ""))
            menu.addItem(item("Show Recording Controls", #selector(showPanel)))
            let micItem = item(model.microphoneMuted ? "Unmute Microphone Recording" : "Mute Microphone Recording", #selector(mute))
            micItem.isEnabled = model.microphoneAvailable && !model.microphonePending
            menu.addItem(micItem)
            menu.addItem(item("Finish Recording", #selector(finish)))
        } else if model.capture == .starting {
            menu.addItem(item("Show Starting Status", #selector(showPanel)))
            menu.addItem(item("Cancel Start", #selector(cancelStart)))
        } else if [.saving, .saveFailed, .stopUnconfirmed, .interrupted, .startFailed].contains(model.capture) {
            menu.addItem(NSMenuItem(title: model.capture.rawValue, action: nil, keyEquivalent: ""))
            menu.addItem(item("Show Recording Status", #selector(showPanel)))
            if [.saveFailed, .stopUnconfirmed].contains(model.capture) { menu.addItem(item("Retry Recovery", #selector(finish))) }
            if !model.captureBusy { menu.addItem(item("Start Recording", #selector(start))) }
        } else {
            menu.addItem(item("Start Recording", #selector(start)))
            if model.capture == .saved { menu.addItem(NSMenuItem(title: "Recording saved · sample", action: nil, keyEquivalent: "")) }
        }
        let processingCount = model.calls.filter { $0.state == .processing }.count
        if processingCount > 0 {
            menu.addItem(NSMenuItem(title: "\(processingCount) transcript\(processingCount == 1 ? "" : "s") processing · sample", action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Library", #selector(showLibrary)))
        menu.addItem(item("Settings…", #selector(showSettings)))
        menu.addItem(.separator())
        menu.addItem(item("Prototype Controls…", #selector(showControls)))
        menu.addItem(item("Quit Trigo UX Prototype", #selector(quit)))
        menu.autoenablesItems = false
        for entry in menu.items where entry.action == nil { entry.isEnabled = false }
        statusItem?.menu = menu
        if quittingAfterSave {
            if model.capture == .saved || model.capture == .idle {
                quittingAfterSave = false
                DispatchQueue.main.async { NSApp.terminate(nil) }
            } else if model.capture == .saveFailed || model.capture == .stopUnconfirmed {
                quittingAfterSave = false
                model.panelVisible = true
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window == libraryWindow { NSApp.setActivationPolicy(.accessory) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showLibrary(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.capture == .recording || model.capture == .starting {
            let alert = NSAlert()
            alert.messageText = "Finish recording and quit?"
            alert.informativeText = "Trigo will finish the sample recording and save it before quitting."
            alert.addButton(withTitle: "Finish and quit")
            alert.addButton(withTitle: "Keep Trigo open")
            if alert.runModal() == .alertFirstButtonReturn {
                quittingAfterSave = true
                if model.capture == .starting { model.cancelStart() } else { model.finish() }
            }
            return .terminateCancel
        }
        if model.capture == .saving { quittingAfterSave = true; return .terminateCancel }
        if model.capture == .saveFailed || model.capture == .stopUnconfirmed { model.panelVisible = true; return .terminateCancel }
        return .terminateNow
    }
    @objc private func closeKeyWindow() { NSApp.keyWindow?.performClose(nil) }
    @objc private func start() { model.start() }
    @objc private func mute() { model.toggleMicrophone() }
    @objc private func finish() { model.finish() }
    @objc private func cancelStart() { model.cancelStart() }
    @objc private func showPanel() { model.panelVisible = true }
    @objc private func quit() { NSApp.terminate(nil) }
}

@main struct TrigoDesktopDesignStudy {
    @MainActor static func main() {
        let application = NSApplication.shared
        if let flag = CommandLine.arguments.firstIndex(of: "--render-fixtures"), CommandLine.arguments.count > flag + 1 {
            application.setActivationPolicy(.prohibited)
            do {
                try renderPrototypeFixtures(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true))
            } catch {
                print("Could not render prototype fixtures: \(error)")
                exit(1)
            }
            return
        }
        let delegate = PrototypeAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}
