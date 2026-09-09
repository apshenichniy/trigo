import AppKit
import SwiftUI

@main struct FocusFixture: App {
  @State private var input = ""
  var body: some Scene {
    WindowGroup("Controlled focus fixture") {
      VStack(alignment: .leading, spacing: 16) {
        Text("Controlled focus fixture").font(.title2)
        Text("Synthetic input and focus checks only.")
        TextField("Type here", text: $input)
          .accessibilityIdentifier("controlled-input")
      }
      .padding(32).frame(width: 500, height: 200)
    }
  }
}
