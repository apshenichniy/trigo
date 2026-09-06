import SwiftUI
import TrigoNative

@main struct TrigoApp: App {
  @NSApplicationDelegateAdaptor(RecordingAppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow
  @StateObject private var coordinator: RecordingCoordinator
  @State private var didRestore = false
  private let variant: AppVariant
  private let namespace: AppNamespace

  init() {
    let variant: AppVariant =
      Bundle.main.bundleIdentifier == AppVariant.dev.bundleIdentifier ? .dev : .personal
    let namespace = try! AppNamespace.installed()
    self.variant = variant
    self.namespace = namespace
    _coordinator = StateObject(
      wrappedValue: RecordingCoordinator(
        connection: .live(namespace: namespace, variant: variant), namespace: namespace))
  }

  var body: some Scene {
    Window("Archive connection", id: "connection") {
      ConnectionView(appName: variant.appName, model: coordinator)
        .defaultAppStorage(UserDefaults(suiteName: namespace.preferences)!)
        .task {
          appDelegate.configure(coordinator: coordinator, appName: variant.appName) {
            openWindow(id: "connection")
            NSApp.activate(ignoringOtherApps: true)
          }
          guard !didRestore else { return }
          didRestore = true
          await coordinator.restore()
        }
    }
    .commands {
      CommandGroup(after: .windowArrangement) {
        Button("Show Recording Controls") { appDelegate.showRecordingControls() }
      }
    }
  }
}
