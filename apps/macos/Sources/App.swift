import AppKit
import TrigoDesktop

@main enum TrigoApp {
  @MainActor static func main() {
    let application = NSApplication.shared
    let delegate = DesktopAppDelegate.installed()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
  }
}
