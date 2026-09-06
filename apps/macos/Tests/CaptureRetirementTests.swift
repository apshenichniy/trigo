import Foundation
import Testing

@testable import TrigoNative

@MainActor private final class ControlledCaptureStream: CaptureStoppable {
  var shouldFail = true
  var stops = 0
  func stopForRetirement() async throws {
    stops += 1
    if shouldFail { throw CaptureError.closed }
  }
}

@Test @MainActor func failedStreamStopRemainsOwnedAndBlocksReplacementUntilRetryCompletes()
  async throws
{
  let retirement = CaptureStreamRetirement()
  var stream: ControlledCaptureStream? = ControlledCaptureStream()
  weak let retained = stream
  await #expect(throws: CaptureError.closed) { try await retirement.retire(#require(stream)) }
  stream = nil
  #expect(retained != nil)
  #expect(retirement.hasPending)
  retained?.shouldFail = false
  try await retirement.retryAll()
  #expect(!retirement.hasPending)
  #expect(retained == nil)
}
