import Foundation
import ScreenCaptureKit

/// The OS transport boundary allows deterministic late-start/stop tests without TCC access.
@MainActor protocol CaptureTransport: CaptureStoppable {
  func addCaptureOutput(
    _ output: any SCStreamOutput, type: SCStreamOutputType, queue: DispatchQueue
  ) throws
  func startCapture() async throws
}

extension SCStream: CaptureTransport {
  func addCaptureOutput(
    _ output: any SCStreamOutput, type: SCStreamOutputType, queue: DispatchQueue
  ) throws {
    try addStreamOutput(output, type: type, sampleHandlerQueue: queue)
  }
}

@MainActor struct CaptureSystem {
  var permissions: () -> CapturePermissions
  var filter: (CaptureSource) async throws -> SCContentFilter
  var microphone: () -> CaptureMicrophone?
  var stream: (SCContentFilter, SCStreamConfiguration, any SCStreamDelegate) -> any CaptureTransport
}
