import AppKit
import TrigoDesktop

@testable import TrigoNative

@main enum TrigoFixtureApp {
  @MainActor static func main() {
    do {
      let (configuration, root) = try FixtureConfiguration.load()
      let environment = FixtureEnvironment(configuration: configuration, root: root)
      let composition = try DesktopComposition(
        fixtureBundleIdentifier: FixtureConfiguration.bundleID,
        runID: configuration.runID,
        support: root,
        makeServices: environment.makeServices
      )
      let makeShortcut: ((DesktopShell) -> GlobalRecordingShortcut)?
      if configuration.scenario == .gesture {
        makeShortcut = { shell in environment.makeShortcut(shell) }
      } else {
        makeShortcut = nil
      }
      let reader =
        configuration.scenario == .reader
        ? FixtureLibrary.model(configuration: configuration, namespace: composition.namespace) : nil
      let delegate = try DesktopAppDelegate(
        fixture: composition,
        loginService: FixtureLoginService(),
        reader: reader.map(DesktopReader.live) ?? .empty,
        makeShortcut: makeShortcut
      )
      let application = NSApplication.shared
      // Launch defaults alone do not change AppKit's effective appearance on every macOS.
      // Set the fixture's appearance explicitly without changing the system preference.
      application.appearance = NSAppearance(
        named: UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
          ? .darkAqua : .aqua
      )
      application.delegate = delegate
      let evidence = FixtureEvidence(
        root: root,
        composition: composition,
        shell: delegate.shell!,
        shortcut: environment.shortcut,
        panel: environment.panel,
        reader: reader
      )
      withExtendedLifetime((delegate, environment, evidence)) { application.run() }
    } catch {
      fputs("Fixture launch rejected: configuration or isolated adapters are invalid.\n", stderr)
      exit(78)
    }
  }
}
