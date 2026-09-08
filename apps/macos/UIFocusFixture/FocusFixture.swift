import AppKit

/// An independent native application with a deterministic window and real
/// fullscreen acknowledgements. It never connects to capture, credentials or a server.
@MainActor
private final class FocusFixtureDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private var window: NSWindow?
  private let mode = NSTextField(labelWithString: "Windowed")

  func applicationDidFinishLaunching(_ notification: Notification) {
    let window = NSWindow(
      contentRect: NSRect(x: 300, y: 420, width: 500, height: 240),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Controlled focus fixture"
    window.setAccessibilityIdentifier("focus-window")
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.collectionBehavior = [.fullScreenPrimary]
    window.contentMinSize = NSSize(width: 500, height: 240)
    window.delegate = self
    let title = NSTextField(labelWithString: "Controlled focus fixture")
    title.font = .systemFont(ofSize: 20, weight: .medium)
    let detail = NSTextField(labelWithString: "Synthetic input and focus checks only.")
    let input = NSTextField(string: "")
    input.placeholderString = "Type here"
    input.setAccessibilityIdentifier("controlled-input")
    mode.setAccessibilityIdentifier("focus-fullscreen-state")
    let stack = NSStackView(views: [title, detail, input, mode])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    let content = NSView()
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -32),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
      input.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    window.contentView = content
    self.window = window
    let menu = NSMenu()
    let application = NSMenuItem()
    application.submenu = NSMenu()
    application.submenu?
      .addItem(
        NSMenuItem(
          title: "Quit Focus Fixture",
          action: #selector(NSApplication.terminate(_:)),
          keyEquivalent: "q"
        )
      )
    menu.addItem(application)
    let view = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
    view.submenu = NSMenu(title: "View")
    let fullscreen = NSMenuItem(
      title: "Toggle Full Screen",
      action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f"
    )
    fullscreen.keyEquivalentModifierMask = [.control, .command]
    view.submenu?.addItem(fullscreen)
    menu.addItem(view)
    NSApp.mainMenu = menu
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(input)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowDidEnterFullScreen(_ notification: Notification) { mode.stringValue = "Fullscreen" }
  func windowDidExitFullScreen(_ notification: Notification) { mode.stringValue = "Windowed" }
}

@main private enum FocusFixture {
  @MainActor static func main() {
    let application = NSApplication.shared
    let delegate = FocusFixtureDelegate()
    application.setActivationPolicy(.regular)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
