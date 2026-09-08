import Foundation

/// Owns the instance lease for the entire process, independently of any window/view.
@MainActor public final class DesktopComposition {
  public let appName: String
  public let namespace: AppNamespace
  public let services: (any DesktopRecordingServices)?
  public let startupFailure: RecordingNotice?
  public var isFixture: Bool { namespace.fixtureIdentifier != nil }
  private let application: RecordingApplication?
  private let fixtureLease: AppInstanceLease?

  public static func installed(bundle: Bundle = .main) throws -> DesktopComposition {
    let variant = try AppVariant.installed(bundleIdentifier: bundle.bundleIdentifier)
    let namespace = try AppNamespace.installed(bundle: bundle)
    let application = RecordingApplication(namespace: namespace, variant: variant)
    return DesktopComposition(namespace: namespace, variant: variant, application: application)
  }

  private init(namespace: AppNamespace, variant: AppVariant, application: RecordingApplication) {
    self.namespace = namespace
    self.appName = variant.appName
    self.application = application
    self.fixtureLease = nil
    self.startupFailure = application.startupFailure
    self.services = application.coordinator.map(LiveDesktopRecordingServices.init)
  }

  /// #72's fixture executable calls this factory explicitly, before constructing any UI.
  /// Dedicated bundle identity, per-run storage and injected services are all required.
  /// It performs no installed-service, Keychain, TCC or network fallback.
  public init(
    fixtureBundleIdentifier: String,
    runID: String,
    support: URL,
    makeServices: (AppNamespace) throws -> any DesktopRecordingServices
  ) throws {
    let namespace = try AppNamespace(
      fixtureBundleIdentifier: fixtureBundleIdentifier,
      runID: runID,
      support: support
    )
    let lease = try AppInstanceLease(namespace: namespace)
    let services = try makeServices(namespace)
    self.namespace = namespace
    self.appName = "Trigo Fixture"
    self.fixtureLease = lease
    self.application = nil
    self.startupFailure = nil
    self.services = services
  }
}
