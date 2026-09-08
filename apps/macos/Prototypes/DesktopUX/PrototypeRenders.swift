import AppKit
import SwiftUI

// Render the actual SwiftUI components without opening or controlling desktop windows.
// These are layout references, not evidence for window focus, capture or persistence.
@MainActor func renderPrototypeFixtures(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let model = PrototypeModel()
    model.reduceMotion = true
    model.elapsed = 252

    func render<V: View>(_ view: V, name: String, width: CGFloat, height: CGFloat, scale: CGFloat = 4) throws {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let path = directory.appendingPathComponent(name + ".png")
        try png.write(to: path)
        print(path.path)
    }

    for (name, state, muted, available, pending) in [
        ("panel-recording", CaptureState.recording, false, true, false),
        ("panel-muted", .recording, true, true, false),
        ("panel-microphone-unavailable", .recording, false, false, false),
        ("panel-microphone-pending", .recording, false, true, true),
        ("panel-saving", .saving, false, true, false),
        ("panel-save-failed", .saveFailed, false, true, false),
        ("panel-stop-unconfirmed", .stopUnconfirmed, false, true, false),
        ("panel-starting", .starting, false, true, false),
        ("panel-interrupted", .interrupted, false, true, false),
    ] {
        model.capture = state
        model.microphoneMuted = muted
        model.microphoneAvailable = available
        model.microphonePending = pending
        try render(CompactRecordingPanelView(model: model), name: name, width: 192, height: 44)
    }

}
