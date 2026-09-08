import AppKit
import XCTest

@MainActor final class DesktopShellUITests: XCTestCase {
  private let app = XCUIApplication()
  private let focus = XCUIApplication(
    bundleIdentifier: "io.github.apshenichniy.trigo.fixture.focus"
  )
  private var pointerDriver: XCUIApplication?
  private var statusLocation: CGPoint?
  private var controlSequence = 0
  private var root: URL!
  private var library: XCUIElement { app.windows["library-window"] }
  private var settings: XCUIElement { app.windows["settings-window"] }
  private var panel: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "recording-window").firstMatch
  }

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
    clickMenuItem("menu-open-library")
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
    clickMenuItem("menu-open-library")
    XCTAssertTrue(library.waitForExistence(timeout: 5))
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    XCTAssertTrue(settings.staticTexts["Double Left Control"].exists)
    XCTAssertTrue(settings.staticTexts["Control–Option–Command–R"].exists)
    XCTAssertFalse(settings.buttons["gesture-enable"].exists)
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
    clickMenuItem("menu-open-library")
    XCTAssertTrue(library.waitForExistence(timeout: 5))
  }

  func testRealCoordinatorStartMuteFinishAndBackgroundQuit() throws {
    try launch()
    openMenu()
    clickMenuItem("menu-start-recording")
    XCTAssertTrue(waitState { $0["phase"] as? String == "recording" })
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    XCTAssertEqual(try state()["source"] as? String, "Synthetic conversation")
    capture("shell-recording-started", panel)
    openMenu()
    clickMenuItem("menu-microphone")
    XCTAssertTrue(waitState { $0["microphoneEnabled"] as? Bool == false })
    openMenu()
    clickMenuItem("menu-finish-recording")
    XCTAssertTrue(
      waitState { $0["canStart"] as? Bool == true && ($0["callIds"] as? [String])?.count == 1 }
    )
    wait(panel, "exists == false")
    XCTAssertFalse(library.exists)
    openMenu()
    clickMenuItem("menu-quit")
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
  }

  func testDeniedAccessRetainsSettingsAndPreventsStart() throws {
    try launch(scenario: "denied")
    openMenu()
    XCTAssertFalse(app.menuItems["menu-start-recording"].isEnabled)
    clickMenuItem("menu-settings")
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.radioButtons["settings-diagnostics-tab"].click()
    capture("shell-denied-capture-access", settings)
    XCTAssertFalse(panel.exists)
    XCTAssertTrue(try (state()["callIds"] as? [String] ?? []).isEmpty)
  }

  func testGestureSetupDenialKeepsMenuStartAvailable() throws {
    try launch(scenario: "gesture")
    openMenu()
    clickMenuItem("menu-settings")
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    XCTAssertTrue(settings.buttons["gesture-enable"].exists)
    capture("shell-gesture-disabled", settings)
    settings.buttons["gesture-enable"].click()
    XCTAssertTrue(waitState { $0["gestureState"] as? String == "denied" })
    XCTAssertTrue(settings.buttons["gesture-open-settings"].exists)
    XCTAssertTrue(settings.staticTexts["Control–Option–Command–R"].exists)
    capture("shell-gesture-denied", settings)
    settings.buttons["gesture-refresh"].click()
    XCTAssertTrue(waitState { $0["gestureState"] as? String == "denied" })
    settings.buttons["gesture-disable"].click()
    XCTAssertTrue(waitState { $0["gestureState"] as? String == "disabled" })
    settings.buttons["_XCUI:CloseWindow"].click()
    openMenu()
    clickMenuItem("menu-start-recording")
    XCTAssertTrue(waitState { $0["phase"] as? String == "recording" })
    openMenu()
    clickMenuItem("menu-finish-recording")
    XCTAssertTrue(
      waitState { ($0["callIds"] as? [String])?.count == 1 && $0["canStart"] as? Bool == true }
    )
  }

  func testCompactPanelMeasuredSignalsAndMicrophoneAvailability() throws {
    try launch(scenario: "panel")
    try startControlledRecording()
    XCTAssertEqual(panel.frame.width, 192, accuracy: 0.5)
    XCTAssertEqual(panel.frame.height, 44, accuracy: 0.5)
    XCTAssertTrue(
      waitState { Self.level($0, "application") > 0.1 && Self.level($0, "microphone") > 0.05 }
    )
    capture("shell-panel-measured", panel)
    attach("shell-panel-accessibility", panel.debugDescription)
    try attachState("shell-panel-measured-state")
    try control("applicationOnly")
    XCTAssertTrue(
      waitState { Self.level($0, "application") > 0.1 && Self.level($0, "microphone") == 0 }
    )
    try attachState("shell-panel-application-only")
    try control("microphoneOnly")
    XCTAssertTrue(
      waitState { Self.level($0, "application") == 0 && Self.level($0, "microphone") > 0.05 }
    )
    try attachState("shell-panel-microphone-only")
    try control("silence")
    XCTAssertTrue(
      waitState { Self.level($0, "application") == 0 && Self.level($0, "microphone") == 0 }
    )
    capture("shell-panel-silent", panel)
    try control("bothSignals")
    pointerClick(panel.buttons["microphone-toggle"])
    XCTAssertTrue(
      waitState {
        $0["microphoneEnabled"] as? Bool == false && Self.level($0, "microphone") == 0
          && Self.level($0, "application") > 0.1
      }
    )
    capture("shell-panel-muted", panel)
    pointerClick(panel.buttons["recording-hide"])
    wait(panel, "exists == false")
    try control("microphoneLost")
    XCTAssertTrue(
      waitState {
        $0["microphoneState"] as? String == "unavailable"
          && $0["notificationTitle"] as? String == "Microphone unavailable"
      }
    )
    XCTAssertFalse(panel.exists)
    XCTAssertFalse(library.exists)
    capture("shell-panel-microphone-unavailable", recordingNotification)
    let transition = try state()["microphoneNoticeSequence"] as? Int
    try control("applicationOnly")
    XCTAssertEqual(try state()["microphoneNoticeSequence"] as? Int, transition)
    try control("microphoneReturned")
    XCTAssertTrue(
      waitState {
        $0["microphoneState"] as? String == "muted" && $0["microphoneEnabled"] as? Bool == false
          && Self.level($0, "microphone") == 0
      }
    )
    try attachState("shell-panel-reattached-muted")
    openMenu()
    clickMenuItem("menu-show-recording")
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    pointerClick(panel.buttons["recording-finish"])
    try assertSavedCall(count: 1)
  }

  func testCompactPanelFocusDragHideRevealInFullscreen() throws {
    try launch(scenario: "panel")
    let input = focus.textFields["controlled-input"]
    input.click()
    input.typeText("before")
    focus.typeKey("f", modifierFlags: [.control, .command])
    wait(
      focus.staticTexts["focus-fullscreen-state"],
      "value == 'Fullscreen' OR label == 'Fullscreen'"
    )
    try startControlledRecording()
    assertFocusPreserved()
    let original = panel.frame
    let start = pointerCoordinate(CGPoint(x: original.midX - 8, y: original.maxY - 3))
    let destination = pointerCoordinate(CGPoint(x: original.midX + 72, y: original.maxY + 57))
    start.press(forDuration: 0.2, thenDragTo: destination)
    XCTAssertGreaterThan(abs(panel.frame.midX - original.midX), 30)
    let moved = panel.frame
    assertFocusPreserved()
    pointerClick(panel.buttons["microphone-toggle"])
    XCTAssertTrue(waitState { $0["microphoneEnabled"] as? Bool == false })
    assertFocusPreserved()
    focus.typeText("during")
    XCTAssertEqual(input.value as? String, "beforeduring")
    capture("shell-panel-fullscreen", panel)
    capture("shell-panel-focus-input", focus.windows.firstMatch)
    pointerClick(panel.buttons["recording-hide"])
    wait(panel, "exists == false")
    assertFocusPreserved()
    openMenu()
    clickMenuItem("menu-show-recording")
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    XCTAssertEqual(panel.frame.minX, moved.minX, accuracy: 1)
    XCTAssertEqual(panel.frame.minY, moved.minY, accuracy: 1)
    assertFocusPreserved()
    pointerClick(panel.buttons["recording-finish"])
    try assertSavedCall(count: 1)
    assertFocusPreserved()
    focus.typeText("after")
    XCTAssertEqual(input.value as? String, "beforeduringafter")
    try attachState("shell-panel-fullscreen-finished")
    focus.typeKey("f", modifierFlags: [.control, .command])
    wait(focus.staticTexts["focus-fullscreen-state"], "value == 'Windowed' OR label == 'Windowed'")
  }

  func testCompactPanelPendingMuteKeepsFinishAvailable() throws {
    try launch(scenario: "panel")
    try startControlledRecording()
    try control("holdAudio")
    pointerClick(panel.buttons["microphone-toggle"])
    XCTAssertTrue(
      waitState {
        $0["microphoneChanging"] as? Bool == true && $0["microphoneEnabled"] as? Bool == true
      }
    )
    XCTAssertFalse(panel.buttons["microphone-toggle"].isEnabled)
    XCTAssertTrue(panel.buttons["recording-finish"].isEnabled)
    capture("shell-panel-mute-pending", panel)
    attach("shell-panel-mute-pending-accessibility", panel.debugDescription)
    pointerClick(panel.buttons["recording-finish"])
    XCTAssertTrue(
      waitState { $0["phase"] as? String == "stopping" && $0["canStart"] as? Bool == false }
    )
    try control("releaseAudio")
    try assertSavedCall(count: 1)
    try startControlledRecording()
    XCTAssertTrue(
      waitState {
        $0["microphoneEnabled"] as? Bool == true && $0["microphoneChanging"] as? Bool == false
          && Self.level($0, "microphone") > 0.05
      }
    )
    try attachState("shell-panel-next-call-microphone")
    pointerClick(panel.buttons["recording-finish"])
    try assertSavedCall(count: 2)
  }

  func testCompactPanelCancelRetiresLateStart() throws {
    try launch(scenario: "panel")
    try control("holdStart")
    openMenu()
    clickMenuItem("menu-start-recording")
    XCTAssertTrue(
      waitState {
        $0["phase"] as? String == "starting" && $0["waitingForStart"] as? Bool == true
          && ($0["applicationBuffers"] as? Int ?? 0) > 2
      }
    )
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    XCTAssertFalse(panel.buttons["recording-finish"].exists)
    capture("shell-panel-starting", panel)
    pointerClick(panel.buttons["recording-cancel-start"])
    XCTAssertTrue(
      waitState {
        $0["localSave"] as? String == "confirmed" && $0["pendingNativeStart"] as? Bool == true
          && $0["canStart"] as? Bool == false
      }
    )
    XCTAssertEqual(try state()["quitRequirement"] as? String, "waitForSafety")
    capture("shell-panel-cancelling-late-start", panel)
    try attachState("shell-panel-cancelling-state")
    try control("releaseStart")
    XCTAssertTrue(
      waitState {
        $0["pendingNativeStart"] as? Bool == false && $0["applicationRunning"] as? Bool == false
          && $0["canStart"] as? Bool == true && ($0["callIds"] as? [String])?.count == 1
      }
    )
    XCTAssertEqual(try state()["localSave"] as? String, "confirmed")
    XCTAssertEqual(try state()["quitRequirement"] as? String, "ready")
    XCTAssertFalse(library.exists)
  }

  func testCompactPanelSaveWaitAndFailureRecovery() throws {
    try launch(scenario: "panel")
    try control("holdSave")
    try control("failNextSave")
    try startControlledRecording()
    pointerClick(panel.buttons["recording-finish"])
    XCTAssertTrue(
      waitState {
        $0["waitingForSave"] as? Bool == true && $0["captureStopped"] as? Bool == true
          && $0["localSave"] as? String == "pending"
      }
    )
    XCTAssertFalse(panel.buttons["recording-finish"].exists)
    XCTAssertEqual(try state()["canStart"] as? Bool, false)
    XCTAssertEqual(try state()["quitRequirement"] as? String, "waitForSafety")
    let elapsed = try state()["elapsedMs"] as? Int
    capture("shell-panel-saving", panel)
    pointerClick(panel.buttons["recording-hide"])
    wait(panel, "exists == false")
    XCTAssertEqual(try state()["elapsedMs"] as? Int, elapsed)
    try control("releaseSave")
    XCTAssertTrue(
      waitState {
        $0["phase"] as? String == "recoveryRequired"
          && $0["localSave"] as? String == "needsRecovery" && $0["captureStopped"] as? Bool == true
      }
    )
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    XCTAssertEqual(try state()["saveCalls"] as? Int, 1)
    XCTAssertEqual(panel.buttons["recording-recovery"].label, "Retry saving")
    capture("shell-panel-save-failed", panel)
    attach("shell-panel-save-failed-accessibility", panel.debugDescription)
    pointerClick(panel.buttons["recording-recovery"])
    try assertSavedCall(count: 1)
  }

  func testCompactPanelStopFailureRetainsSavedAudio() throws {
    try launch(scenario: "panel")
    try startControlledRecording()
    try control("failStops")
    pointerClick(panel.buttons["recording-finish"])
    XCTAssertTrue(
      waitState {
        $0["phase"] as? String == "recoveryRequired" && $0["localSave"] as? String == "confirmed"
          && $0["captureStopped"] as? Bool == false
      }
    )
    XCTAssertEqual(try state()["applicationRunning"] as? Bool, true)
    XCTAssertEqual(try state()["canStart"] as? Bool, false)
    XCTAssertEqual(try state()["quitRequirement"] as? String, "waitForSafety")
    XCTAssertNotEqual(try state()["notificationTitle"] as? String, "Recording saved")
    XCTAssertEqual(panel.buttons["recording-recovery"].label, "Retry stopping")
    capture("shell-panel-stop-failed", panel)
    attach("shell-panel-stop-failed-accessibility", panel.debugDescription)
    try attachState("shell-panel-stop-failed-state")
    try control("allowStops")
    pointerClick(panel.buttons["recording-recovery"])
    try assertSavedCall(count: 1)
    XCTAssertEqual(try state()["applicationRunning"] as? Bool, false)
  }

  private var recordingNotification: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "recording-notification").firstMatch
  }

  private static func level(_ state: [String: Any], _ role: String) -> Double {
    state["\(role)RMS"] as? Double ?? -1
  }

  private func startControlledRecording() throws {
    openMenu()
    clickMenuItem("menu-start-recording")
    XCTAssertTrue(waitState { $0["phase"] as? String == "recording" })
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    XCTAssertEqual(try state()["source"] as? String, "Controlled focus fixture")
    XCTAssertEqual(try state()["captureAdapter"] as? String, "synthetic-pcm-fixture")
    assertFocusPreserved()
  }

  private func assertFocusPreserved() {
    XCTAssertEqual(focus.state, .runningForeground)
    XCTAssertTrue(waitState { $0["focusOwner"] as? String == "focus-fixture" })
  }

  private func assertSavedCall(count: Int) throws {
    XCTAssertTrue(
      waitState {
        $0["canStart"] as? Bool == true && $0["captureStopped"] as? Bool == true
          && $0["localSave"] as? String == "confirmed" && $0["pendingNativeStart"] as? Bool == false
          && ($0["callIds"] as? [String])?.count == count
      }
    )
    XCTAssertEqual(try state()["quitRequirement"] as? String, "ready")
    XCTAssertFalse(library.exists)
  }

  private func control(_ command: String) throws {
    controlSequence += 1
    let value: [String: Any] = [
      "schemaVersion": 1, "sequence": controlSequence, "command": command,
    ]
    try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
      .write(to: root.appendingPathComponent("control.json"), options: .atomic)
    XCTAssertTrue(waitState { $0["controlSequence"] as? Int == self.controlSequence })
    XCTAssertEqual(try state()["controlFailure"] as? String, "")
  }

  private func attachState(_ name: String) throws {
    attach(
      name,
      String(
        decoding: try Data(contentsOf: root.appendingPathComponent("state.json")),
        as: UTF8.self
      )
    )
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
    XCTAssertEqual(
      evidence["globalShortcut"] as? String,
      scenario == "gesture" ? "in-process-fixture" : "disabled"
    )
    let archive = try XCTUnwrap(evidence["archiveRoot"] as? String)
    XCTAssertTrue(
      URL(fileURLWithPath: archive).resolvingSymlinksInPath().path
        .hasPrefix(root.resolvingSymlinksInPath().path + "/")
    )
    focus.launch()
    XCTAssertTrue(focus.wait(for: .runningForeground, timeout: 5))
    let item = app.statusItems["trigo-status-item"]
    let frame = item.frame
    statusLocation = CGPoint(x: frame.midX, y: frame.midY)
  }

  private func openMenu() {
    if app.state == .runningForeground {
      pointerDriver = app
    } else {
      if focus.state != .runningForeground { focus.activate() }
      pointerDriver = focus
    }
    if focus.staticTexts["focus-fullscreen-state"].exists,
      focus.staticTexts["focus-fullscreen-state"].label == "Fullscreen", let statusLocation
    {
      pointerCoordinate(CGPoint(x: statusLocation.x, y: 1)).hover()
    }
    let item = app.statusItems["trigo-status-item"]
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    pointerClick(item)
    waitForVisibleMenuItem(app.menuItems["menu-open-library"])
  }

  private func clickMenuItem(_ identifier: String) {
    let item = app.menuItems[identifier]
    waitForVisibleMenuItem(item)
    XCTAssertTrue(item.isEnabled)
    pointerClick(item)
  }

  private func pointerClick(_ element: XCUIElement) {
    let frame = element.frame
    XCTAssertFalse(frame.isEmpty)
    // Anchor the real pointer event to the already-foreground controlled app.
    // An element in the background accessory app makes XCTest activate that app
    // before synthesis, which both alters focus and can dismiss its status menu.
    pointerCoordinate(CGPoint(x: frame.midX, y: frame.midY)).click()
  }

  private func pointerCoordinate(_ point: CGPoint) -> XCUICoordinate {
    let driver = pointerDriver ?? focus
    let window = driver.windows.firstMatch
    let origin = window.frame.origin
    return window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: point.x - origin.x, dy: point.y - origin.y))
  }

  private func waitForVisibleMenuItem(_ item: XCUIElement) {
    let predicate = NSPredicate { _, _ in
      item.exists && !item.frame.isEmpty && item.isHittable
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)],
        timeout: 5
      ),
      .completed
    )
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
