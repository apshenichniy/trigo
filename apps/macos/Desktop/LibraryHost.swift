import SwiftUI
import TrigoNative

/// #20 owns reader contents inside this host. #72 can supply seeded views without a live store.
@MainActor public struct DesktopReader {
  let makeContent: (DesktopShell) -> AnyView

  public init<Content: View>(@ViewBuilder content: @escaping (DesktopShell) -> Content) {
    makeContent = { AnyView(content($0)) }
  }

  public static var unavailable: Self {
    Self { LibraryPlaceholder(shell: $0, isEmpty: false) }
  }

  public static var empty: Self {
    Self { LibraryPlaceholder(shell: $0, isEmpty: true) }
  }
}

private struct LibraryPlaceholder: View {
  @ObservedObject var shell: DesktopShell
  let isEmpty: Bool

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 18) {
        Text("Library").font(.title3.weight(.semibold))
        Text(isEmpty ? "Your recordings will appear here." : "Your call archive")
          .font(.callout).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(22)
      .frame(width: 270, alignment: .leading)
      .libraryGlass()
      .accessibilityIdentifier("library-sidebar")
      VStack(alignment: .leading, spacing: 16) {
        Image(systemName: "text.bubble").font(.largeTitle).foregroundStyle(.secondary)
        Text(isEmpty ? "No recordings yet" : "Your call library")
          .font(.title2.weight(.semibold))
        Text(
          isEmpty
            ? "Focus the application you want to record, then use the recording shortcut."
            : "You can record calls and keep them on this Mac. Viewing saved calls is not available in this version yet."
        )
        .foregroundStyle(.secondary)
        .frame(maxWidth: 430, alignment: .leading)
        Button("Start Recording") { shell.startOrReveal(from: .library) }
          .disabled(!shell.recording.canStart || !shell.recording.permissions.ready)
          .accessibilityIdentifier("library-start-recording")
        if !shell.recording.canStart || !shell.recording.permissions.ready {
          Text(shell.recording.statusTitle).font(.callout).foregroundStyle(.secondary)
          Button("Open Settings…") { shell.showSettings(.connection) }
            .accessibilityIdentifier("library-open-settings")
        }
        Text("Start or show controls: \(GlobalRecordingShortcut.label)")
          .font(.callout).foregroundStyle(.secondary)
      }
      .padding(32)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .accessibilityIdentifier("library-detail")
    }
    .padding(12)
    .background(Color(nsColor: .textBackgroundColor))
    .accessibilityIdentifier("library-content")
  }
}

private extension View {
  @ViewBuilder func libraryGlass() -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: .rect(cornerRadius: 22))
    } else {
      background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
    }
  }
}
