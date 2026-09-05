import SwiftUI
import TrigoNative

@main struct TrigoApp: App {
  private let variant: AppVariant =
    Bundle.main.bundleIdentifier == AppVariant.dev.bundleIdentifier ? .dev : .personal
  private let namespace = try! AppNamespace.installed()
  var body: some Scene {
    WindowGroup {
      VStack(alignment: .leading, spacing: 12) {
        Text(variant.appName).font(.largeTitle)
        Text("Your personal call archive").font(.title3)
        Text("Recording and transcription are coming in the next development steps.")
          .foregroundStyle(.secondary)
      }.padding(32).frame(minWidth: 420, minHeight: 220)
        .defaultAppStorage(UserDefaults(suiteName: namespace.preferences)!)
    }
  }
}
