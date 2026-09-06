import Foundation
import ScreenCaptureKit

@MainActor protocol CaptureStoppable: AnyObject {
  func stopForRetirement() async throws
}

extension SCStream: CaptureStoppable {
  func stopForRetirement() async throws {
    do { try await stopCapture() } catch {
      let failure = error as NSError
      // An OS-terminated stream is already retired, not a reason to restart it.
      guard failure.domain == SCStreamErrorDomain,
        failure.code == SCStreamError.Code.attemptToStopStreamState.rawValue
      else { throw error }
    }
  }
}

/// Retains failed-to-stop transports until a confirmed stop. Callers must not admit
/// replacements while hasPending is true, even after removing the old stream's callbacks.
@MainActor final class CaptureStreamRetirement {
  private var pending: [ObjectIdentifier: any CaptureStoppable] = [:]
  private var inFlight: Set<ObjectIdentifier> = []
  var hasPending: Bool { !pending.isEmpty }

  func retire(_ stream: any CaptureStoppable) async throws {
    let id = ObjectIdentifier(stream)
    pending[id] = stream
    guard inFlight.insert(id).inserted else { throw CaptureError.closed }
    defer { inFlight.remove(id) }
    try await stream.stopForRetirement()
    pending.removeValue(forKey: id)
  }

  func retryAll() async throws {
    for stream in Array(pending.values) { try await retire(stream) }
  }
}
