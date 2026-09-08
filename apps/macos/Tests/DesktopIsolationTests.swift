import Foundation
import Testing

@testable import TrigoNative

@Test @MainActor func desktopFixtureNeverFallsThroughToPersonalOrCreatesInstalledServices() throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  let namespace = fixture.composition.namespace
  #expect(fixture.composition.isFixture)
  #expect(namespace.variant == nil)
  for variant in [AppVariant.personal, .dev] {
    let installed = try AppNamespace(variant: variant, worktree: "test", support: fixture.root)
    #expect(namespace.archive != installed.archive)
    #expect(namespace.journal != installed.journal)
    #expect(namespace.connection != installed.connection)
    #expect(namespace.preferences != installed.preferences)
    #expect(namespace.keychainService != installed.keychainService)
    #expect(throws: NamespaceError.self) {
      try ServerConnection.live(namespace: namespace, variant: variant)
    }
    #expect(
      !FileManager.default.fileExists(atPath: installed.connection.deletingLastPathComponent().path)
    )
  }
  for identifier in [nil, "unknown.app", namespace.fixtureIdentifier] {
    #expect(throws: NamespaceError.self) { try AppVariant.installed(bundleIdentifier: identifier) }
  }
  #expect(try AppVariant.installed(bundleIdentifier: AppVariant.dev.bundleIdentifier) == .dev)
  #expect(
    try AppVariant.installed(bundleIdentifier: AppVariant.personal.bundleIdentifier) == .personal
  )
}

@Test @MainActor func desktopFixtureLeasePrecedesAdaptersAndRemainsHeldWithoutWindows() throws {
  let fixture = try DesktopTestFixture()
  defer { fixture.cleanup() }
  var madeSecondServices = false
  #expect(throws: AppInstanceLeaseError.self) {
    try DesktopComposition(
      fixtureBundleIdentifier: "io.github.apshenichniy.trigo.fixture.shell",
      runID: "test",
      support: fixture.root,
      makeServices: { _ in
        madeSecondServices = true
        return DesktopServicesFixture()
      }
    )
  }
  #expect(!madeSecondServices)
  let other = try DesktopComposition(
    fixtureBundleIdentifier: "io.github.apshenichniy.trigo.fixture.shell",
    runID: "another",
    support: fixture.root,
    makeServices: { _ in DesktopServicesFixture() }
  )
  #expect(other.namespace.archive != fixture.composition.namespace.archive)
  withExtendedLifetime(other) {}
}

@Test @MainActor func desktopFixtureRequiresAnExplicitDedicatedBundleAndSafeRunID() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-fixture-rejected-\(UUID())"
  )
  for identifier in [
    AppVariant.dev.bundleIdentifier, AppVariant.personal.bundleIdentifier, "unknown",
  ] {
    #expect(throws: NamespaceError.self) {
      try DesktopComposition(fixtureBundleIdentifier: identifier, runID: "run", support: root) {
        _ in
        Issue.record("Invalid fixture constructed services")
        return DesktopServicesFixture()
      }
    }
  }
  #expect(throws: NamespaceError.self) {
    try AppNamespace(
      fixtureBundleIdentifier: "io.github.apshenichniy.trigo.fixture.shell",
      runID: "../personal",
      support: root
    )
  }
  #expect(!FileManager.default.fileExists(atPath: root.path))
}

@Test @MainActor func desktopInstalledFactoryRejectsUnknownBundleBeforeAnyLiveComposition() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "trigo-fixture-bundle-\(UUID()).bundle"
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let contents = root.appendingPathComponent("Contents")
  try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
  let data = try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": "io.github.apshenichniy.trigo.fixture.shell"],
    format: .xml,
    options: 0
  )
  try data.write(to: contents.appendingPathComponent("Info.plist"))
  let bundle = try #require(Bundle(url: root))
  #expect(throws: NamespaceError.self) { try DesktopComposition.installed(bundle: bundle) }
  #expect(throws: NamespaceError.self) { try AppNamespace.installed(bundle: bundle) }
}

@MainActor private final class DesktopLoginFixture: DesktopLoginService {
  var status: DesktopLoginStatus = .disabled
  var changes: [Bool] = []
  var nextStatus: DesktopLoginStatus = .enabled
  var fails = false
  var gate: DesktopGate?
  func setEnabled(_ enabled: Bool) async throws {
    changes.append(enabled)
    await gate?.wait()
    if fails { throw CocoaError(.featureUnsupported) }
    status = enabled ? nextStatus : .disabled
  }
  func openSettings() {}
}

@Test @MainActor func desktopLoginIsOptInAndDisplaysOnlyAcknowledgedSystemState() async {
  let service = DesktopLoginFixture()
  let model = DesktopLoginModel(service: service)
  model.refresh()
  #expect(model.status == .disabled)
  #expect(service.changes.isEmpty)
  let gate = DesktopGate()
  service.gate = gate
  let enable = Task { await model.setEnabled(true) }
  await gate.waitUntilEntered()
  #expect(model.isChanging)
  #expect(model.status == .disabled)
  await model.setEnabled(false)
  #expect(service.changes == [true])
  service.nextStatus = .requiresApproval
  gate.release()
  await enable.value
  #expect(model.status == .requiresApproval)
  #expect(!model.isChanging)
  service.gate = nil
  service.fails = true
  await model.setEnabled(false)
  #expect(model.status == .requiresApproval)
  #expect(model.issue != nil)
  service.fails = false
  await model.setEnabled(false)
  #expect(model.status == .disabled)
  #expect(model.issue == nil)
}
