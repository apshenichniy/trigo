import Combine
import Foundation

public enum DesktopLoginStatus: Equatable, Sendable {
  case disabled, enabled, requiresApproval, unavailable
}

@MainActor public protocol DesktopLoginService {
  var status: DesktopLoginStatus { get }
  func setEnabled(_ enabled: Bool) async throws
  func openSettings()
}

/// Registration is opt-in. Construction and refresh only read the system's current state.
@MainActor public final class DesktopLoginModel: ObservableObject {
  @Published public private(set) var status: DesktopLoginStatus
  @Published public private(set) var isChanging = false
  @Published public private(set) var issue: String?
  private let service: any DesktopLoginService

  public init(service: any DesktopLoginService) {
    self.service = service
    self.status = service.status
  }

  public func refresh() { status = service.status }
  public func openSettings() { service.openSettings() }
  public func setEnabled(_ enabled: Bool) async {
    guard !isChanging else { return }
    isChanging = true
    defer {
      isChanging = false
      refresh()
    }
    do {
      try await service.setEnabled(enabled)
      issue = nil
    } catch {
      issue = "Could not change launch at login. Review Login Items in System Settings and retry."
    }
  }
}
