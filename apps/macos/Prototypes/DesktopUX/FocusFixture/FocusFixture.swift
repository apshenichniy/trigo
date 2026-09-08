import AppKit
import SwiftUI

// Disposable second process with an ordinary native editor window.
@MainActor
final class FocusFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = NSMenu(title: "Focus Fixture")
        applicationItem.submenu?.addItem(NSMenuItem(title: "Quit Focus Fixture", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.addItem(applicationItem)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = NSMenu(title: "Window")
        let fullscreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.control, .command]
        windowItem.submenu?.addItem(fullscreen)
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowItem.submenu

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 460), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Trigo UI Focus Fixture"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = NSHostingView(rootView: FocusFixtureView())
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct FocusFixtureView: View {
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keyboard focus fixture").font(.title2)
            Text("Synthetic test window. No recording, network or persistence.")
            TextField("Focus probe", text: $text).accessibilityIdentifier("focus-probe")
        }
        .padding(32).frame(minWidth: 500, minHeight: 260)
    }
}

@main
struct FocusFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FocusFixtureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
