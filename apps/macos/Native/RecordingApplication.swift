import Combine
import Foundation

/// Admission boundary before any connection, recovery, shortcut or capture setup.
@MainActor public final class RecordingApplication: ObservableObject {
  public let coordinator: RecordingCoordinator?
  public let startupFailure: RecordingNotice?
  private let lease: AppInstanceLease?

  public convenience init(namespace: AppNamespace, variant: AppVariant) {
    self.init(namespace: namespace) {
      RecordingCoordinator(
        connection: .live(namespace: namespace, variant: variant), namespace: namespace)
    }
  }

  init(namespace: AppNamespace, makeCoordinator: () -> RecordingCoordinator) {
    do {
      lease = try AppInstanceLease(namespace: namespace)
      coordinator = makeCoordinator()
      startupFailure = nil
    } catch {
      lease = nil
      coordinator = nil
      if case AppInstanceLeaseError.alreadyRunning = error {
        startupFailure = .init(
          title: "This local archive is already open",
          message:
            "Another copy of Trigo is using this app namespace. Continue in that copy, or quit it before reopening this one. This copy has not started capture or recovery."
        )
      } else {
        startupFailure = .init(
          title: "Cannot safely open the local archive",
          message:
            "Exclusive access could not be established. Check free disk space and file access to \(namespace.connection.deletingLastPathComponent().path), then reopen the app. Do not remove application.lock while another copy is running."
        )
      }
    }
  }
}
