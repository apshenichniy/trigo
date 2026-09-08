import AppKit
import XCTest

@MainActor final class DesktopShellUITests: XCTestCase {
  private let app = XCUIApplication()
  private var root: URL!
  private var library: XCUIElement { app.windows["library-window"] }
  private var settings: XCUIElement { app.windows["settings-window"] }
  private var panel: XCUIElement { app.dialogs["recording-window"] }

  override func setUp() async throws {
    continueAfterFailure = false
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "trigo-ui-fixture-\(UUID().uuidString.lowercased())",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }

  override func tearDown() async throws {
    if let root {
      if let data = try? Data(contentsOf: root.appendingPathComponent("state.json")) {
        attach("fixture-final-state", String(decoding: data, as: UTF8.self))
      }
    }
    app.terminate()
    XCUIApplication(bundleIdentifier: "io.github.apshenichniy.trigo.fixture.focus").terminate()
    if let root { try? FileManager.default.removeItem(at: root) }
  }

  func testBackgroundMenuLibraryReopenAndSettings() throws {
    try launch()
    XCTAssertFalse(library.exists)
    XCTAssertFalse(settings.exists)
    XCTAssertFalse(panel.exists)
    XCTAssertEqual(try state()["activationPolicy"] as? Int, 1)
    openMenu()
    XCTAssertTrue(app.menuItems["menu-start-recording"].isEnabled)
    app.menuItems["menu-open-library"].click()
    XCTAssertTrue(library.waitForExistence(timeout: 5))
    XCTAssertTrue(library.staticTexts["No recordings yet"].exists)
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    capture("shell-library-empty-light", library)
    attach("shell-library-accessibility", library.debugDescription)
    XCTAssertTrue(waitState { $0["activationPolicy"] as? Int == 0 })
    library.buttons["_XCUI:CloseWindow"].click()
    wait(library, "exists == false")
    XCTAssertTrue(waitState { $0["activationPolicy"] as? Int == 1 })
    openMenu()
    app.menuItems["menu-open-library"].click()
    XCTAssertTrue(library.waitForExistence(timeout: 5))
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    capture("shell-settings-general", settings)
    settings.switches["launch-at-login"].click()
    wait(settings.switches["launch-at-login"], "value == 1")
    settings.radioButtons["settings-connection-tab"].click()
    capture("shell-settings-connection", settings)
    settings.radioButtons["settings-diagnostics-tab"].click()
    XCTAssertTrue(
      settings.staticTexts["Global shortcut registration is disabled in this fixture."].exists
    )
    capture("shell-settings-diagnostics", settings)
    settings.buttons["_XCUI:CloseWindow"].click()
    library.buttons["_XCUI:CloseWindow"].click()
    app.terminate()
    try FileManager.default.removeItem(at: root.appendingPathComponent("state.json"))
    app.launch()
    XCTAssertTrue(waitState { $0["bootstrapped"] as? Bool == true })
    XCTAssertFalse(library.exists)
    XCTAssertTrue(try (state()["callIds"] as? [String] ?? []).isEmpty)
    openMenu()
    app.menuItems["menu-open-library"].click()
    XCTAssertTrue(library.waitForExistence(timeout: 5))
  }

  func testRealCoordinatorStartMuteFinishAndBackgroundQuit() throws {
    try launch()
    openMenu()
    app.menuItems["menu-start-recording"].click()
    XCTAssertTrue(waitState { $0["phase"] as? String == "recording" })
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    XCTAssertEqual(try state()["source"] as? String, "Synthetic conversation")
    capture("shell-recording-started", panel)
    openMenu()
    app.menuItems["menu-microphone"].click()
    XCTAssertTrue(waitState { $0["microphoneEnabled"] as? Bool == false })
    openMenu()
    app.menuItems["menu-finish-recording"].click()
    XCTAssertTrue(
      waitState { $0["canStart"] as? Bool == true && ($0["callIds"] as? [String])?.count == 1 }
    )
    wait(panel, "exists == false")
    XCTAssertFalse(library.exists)
    openMenu()
    app.menuItems["menu-quit"].click()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
  }

  func testDeniedAccessRetainsSettingsAndPreventsStart() throws {
    try launch(scenario: "denied")
    openMenu()
    XCTAssertFalse(app.menuItems["menu-start-recording"].isEnabled)
    app.menuItems["menu-settings"].click()
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.radioButtons["settings-diagnostics-tab"].click()
    capture("shell-denied-capture-access", settings)
    XCTAssertFalse(panel.exists)
    XCTAssertTrue(try (state()["callIds"] as? [String] ?? []).isEmpty)
  }

  private func launch(scenario: String = "empty") throws {
    let configuration: [String: Any] = [
      "schemaVersion": 1, "runID": UUID().uuidString.lowercased(), "scenario": scenario,
      "clock": "2026-09-08T12:00:00Z", "timeZone": "Europe/Madrid",
    ]
    let bytes = try JSONSerialization.data(
      withJSONObject: configuration,
      options: [.sortedKeys, .prettyPrinted]
    )
    let file = root.appendingPathComponent("configuration.json")
    try bytes.write(to: file)
    attach("fixture-configuration", String(decoding: bytes, as: UTF8.self))
    app.launchArguments = [
      "--background", "--fixture-config", file.path, "-AppleLanguages", "(en)", "-AppleLocale",
      "en_US", "-AppleInterfaceStyle", "Light",
    ]
    app.launch()
    XCTAssertTrue(waitState { $0["bootstrapped"] as? Bool == true })
    let evidence = try state()
    XCTAssertEqual(evidence["fixture"] as? Bool, true)
    XCTAssertEqual(evidence["bundleId"] as? String, "io.github.apshenichniy.trigo.fixture.desktop")
    XCTAssertEqual(evidence["credentialAdapter"] as? String, "memory-fixture")
    XCTAssertEqual(evidence["statusAdapter"] as? String, "in-process-fixture")
    XCTAssertEqual(evidence["globalShortcut"] as? String, "disabled")
    let archive = try XCTUnwrap(evidence["archiveRoot"] as? String)
    XCTAssertTrue(
      URL(fileURLWithPath: archive).resolvingSymlinksInPath().path
        .hasPrefix(root.resolvingSymlinksInPath().path + "/")
    )
  }

  private func openMenu() {
    let item = app.statusItems["trigo-status-item"]
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    item.click()
    XCTAssertTrue(app.menuItems["menu-open-library"].waitForExistence(timeout: 5))
  }

  private func state() throws -> [String: Any] {
    try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("state.json"))
      ) as? [String: Any]
    )
  }

  private func waitState(_ matches: @escaping ([String: Any]) -> Bool) -> Bool {
    let predicate = NSPredicate { [weak self] _, _ in
      guard let self, let value = try? self.state() else { return false }
      return matches(value)
    }
    return XCTWaiter.wait(
      for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
      timeout: 10
    ) == .completed
  }

  private func wait(_ element: XCUIElement, _ format: String) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: format),
      object: element
    )
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
  }

  private func capture(_ name: String, _ element: XCUIElement) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func attach(_ name: String, _ value: String) {
    let attachment = XCTAttachment(string: value)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
