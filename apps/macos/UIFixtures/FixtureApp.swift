import AppKit
import TrigoDesktop

@testable import TrigoNative

@main enum TrigoFixtureApp {
  @MainActor static func main() {
    do {
      let (configuration, root) = try FixtureConfiguration.load()
      let environment = FixtureEnvironment(configuration: configuration)
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
      let delegate = try DesktopAppDelegate(
        fixture: composition,
        loginService: FixtureLoginService(),
        reader: .empty,
        makeShortcut: makeShortcut
      )
      let application = NSApplication.shared
      application.delegate = delegate
      let evidence = FixtureEvidence(
        root: root,
        composition: composition,
        shell: delegate.shell!,
        shortcut: environment.shortcut
      )
      withExtendedLifetime((delegate, environment, evidence)) { application.run() }
    } catch {
      fputs("Fixture launch rejected: configuration or isolated adapters are invalid.\n", stderr)
      exit(78)
    }
  }
}
