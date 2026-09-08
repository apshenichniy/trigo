import Foundation

public enum LocalRecordingSaveState: Equatable, Sendable {
  case notRequired, pending, confirmed, needsRecovery
}

/// These confirmations are independent. A retained local call does not prove
/// that its native streams or a late Start have finished.
public struct CaptureFinalizationState: Equatable, Sendable {
  public var callID: String?
  public var captureStopped = true
  public var localSave: LocalRecordingSaveState = .notRequired
  public var pendingNativeStart = false
  public init() {}

  public var isSettled: Bool {
    captureStopped && !pendingNativeStart
      && (localSave == .confirmed || localSave == .notRequired)
  }
}

/// The durable save boundary is injectable independently of native transport.
/// Both live paths still return the repository's actual committed completion.
struct CapturePersistence {
  var complete:
    @Sendable (CaptureArchiveSession, FinalizedMediaMaster, String?) async throws ->
      CaptureCompletion
  var recover: @Sendable (CaptureArchiveSession) async throws -> CaptureCompletion
  static let live = Self(
    complete: { try await $0.complete(media: $1, interruptionReason: $2) },
    recover: { try await $0.recoverCompletion() }
  )
}
