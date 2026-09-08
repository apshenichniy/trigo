import ServiceManagement
import TrigoNative

@MainActor struct SystemLoginService: DesktopLoginService {
  var status: DesktopLoginStatus {
    switch SMAppService.mainApp.status {
    case .notRegistered: .disabled
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }

  func setEnabled(_ enabled: Bool) async throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try await SMAppService.mainApp.unregister()
    }
  }

  func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
