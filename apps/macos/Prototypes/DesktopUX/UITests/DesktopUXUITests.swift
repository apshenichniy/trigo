import AppKit
import XCTest

@MainActor
final class DesktopUXUITests: XCTestCase {
    private let app = XCUIApplication()
    private var prototypeProcess: NSRunningApplication?
    private var library: XCUIElement { app.windows["Trigo"] }
    private var controls: XCUIElement { app.windows["Trigo Prototype Controls"] }
    private var panel: XCUIElement { app.dialogs["Trigo sample recording controls"] }
    private var statusItem: XCUIElement { app.statusItems["Trigo UX Prototype"] }
    private let finishLabel = "Finish recording and save on this Mac"
    private let muteLabel = "Mute Trigo's microphone recording"

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        prototypeProcess = NSWorkspace.shared.frontmostApplication
        XCTAssertEqual(prototypeProcess?.bundleIdentifier, "io.github.apshenichniy.trigo.prototype.desktopux")
    }

    override func tearDown() async throws {
        app.terminate()
        XCUIApplication(bundleIdentifier: "io.github.apshenichniy.trigo.prototype.desktopux.focusfixture").terminate()
    }

    func testNativeControlAndSecondaryWindows() throws {
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        capture("library-light", library)
        attachTree("library-accessibility", library)
        XCTAssertEqual(library.buttons["Hide sidebar"].frame.midY, library.buttons["_XCUI:CloseWindow"].frame.midY, accuracy: 2)
        XCTAssertLessThan(library.buttons["Hide sidebar"].frame.midX, library.frame.minX + 200)
        let telegram = library.buttons["Telegram, Mon, Sep 7, 2026, 14:15, 12 minutes, Ready"]
        XCTAssertTrue(telegram.exists)
        telegram.click()
        XCTAssertTrue(telegram.isSelected)
        capture("library-call-selected", library)

        openControls()
        XCTAssertTrue(controls.buttons["Active recording"].exists)
        capture("design-controls", controls)
        attachTree("secondary-window-accessibility", controls)

        controls.buttons["Active recording"].click()
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        capture("panel-recording-native", panel)
        attachTree("recording-accessibility", panel)
        XCTAssertTrue(panel.buttons["Finish recording and save on this Mac"].exists)
        XCTAssertTrue(panel.buttons["Finish recording and save on this Mac"].isEnabled)
        XCTAssertTrue(panel.buttons[muteLabel].isEnabled)
    }

    func testRecordingWalkthroughAndMenus() throws {
        openStatusMenu()
        XCTAssertTrue(app.menuItems["Start Recording"].isEnabled)
        attachTree("menu-idle-accessibility", statusItem)
        XCTAssertTrue(app.menuItems["Start Recording"].isHittable)
        try captureMenu("menu-idle")
        app.menuItems["Start Recording"].click()
        XCTAssertTrue(panel.buttons[muteLabel].waitForExistence(timeout: 5))
        XCTAssertEqual(panel.frame.width, 192, accuracy: 1)
        XCTAssertEqual(panel.frame.height, 44, accuracy: 1)
        capture("panel-started", panel)

        panel.buttons[muteLabel].click()
        XCTAssertTrue(panel.buttons["Unmute microphone recording"].waitForExistence(timeout: 4))
        capture("panel-muted-native", panel)
        panel.buttons["Unmute microphone recording"].click()
        XCTAssertTrue(panel.buttons[muteLabel].waitForExistence(timeout: 4))

        let originalFrame = panel.frame
        let handle = panel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07))
        handle.click(forDuration: 0.25, thenDragTo: handle.withOffset(CGVector(dx: -220, dy: -90)))
        XCTAssertGreaterThan(abs(panel.frame.minX - originalFrame.minX), 100)
        let movedFrame = panel.frame
        capture("panel-dragged", panel)
        panel.buttons["Hide controls. Recording continues."].click()
        waitFor(panel, "exists == false")

        openStatusMenu()
        XCTAssertTrue(app.menuItems["Recording Google Chrome · sample"].exists)
        XCTAssertTrue(app.menuItems["Finish Recording"].isEnabled)
        try captureMenu("menu-recording-hidden-panel")
        app.menuItems["Show Recording Controls"].click()
        XCTAssertTrue(panel.waitForExistence(timeout: 4))
        XCTAssertEqual(panel.frame.minX, movedFrame.minX, accuracy: 1)
        XCTAssertEqual(panel.frame.minY, movedFrame.minY, accuracy: 1)

        panel.buttons[finishLabel].click()
        waitFor(panel, "exists == false")
        let savedCall = library.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Tue, Sep 8, 2026", "Processing")).firstMatch
        XCTAssertTrue(savedCall.waitForExistence(timeout: 5))
        savedCall.click()
        XCTAssertTrue(library.staticTexts["Your recording is saved"].exists)
        capture("library-new-call-processing", library)
        openStatusMenu()
        XCTAssertTrue(app.menuItems["1 transcript processing · sample"].exists)
        XCTAssertTrue(app.menuItems["Start Recording"].isEnabled)
        try captureMenu("menu-processing")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testSettingsAndReadingStates() throws {
        library.menuButtons["More library actions"].click()
        library.menuButtons["More library actions"].menuItems["Settings…"].click()
        let settings = app.windows["Trigo Settings · Design Study"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        capture("settings-general", settings)
        settings.radioButtons["Connection"].click()
        XCTAssertFalse(settings.buttons["Validate and Save"].isEnabled)
        let token = settings.secureTextFields.firstMatch
        token.click()
        token.typeText("synthetic-test-token")
        XCTAssertTrue(settings.buttons["Validate and Save"].isEnabled)
        settings.buttons["Validate and Save"].click()
        XCTAssertTrue(settings.staticTexts["Connected · sample update accepted"].exists)
        XCTAssertFalse(settings.buttons["Validate and Save"].isEnabled)
        settings.buttons["Retry Saved Connection"].click()
        XCTAssertTrue(settings.staticTexts["Connected · sample connection checked"].exists)
        capture("settings-connection", settings)
        settings.radioButtons["Diagnostics"].click()
        capture("settings-diagnostics", settings)
        settings.buttons["_XCUI:CloseWindow"].click()

        let states: [(String, String, String)] = [
            ("Processing", "Your recording is saved", "processing"),
            ("No speech", "No speech detected", "no-speech"),
            ("Waiting for connection", "Waiting for a connection", "offline"),
            ("Transcription failed", "Couldn't create a transcript", "failed")
        ]
        for (option, heading, name) in states {
            openControls()
            controls.popUpButtons.firstMatch.click()
            app.menuItems[option].click()
            controls.buttons["Open library"].click()
            XCTAssertTrue(library.staticTexts[heading].isHittable)
            capture("library-\(name)", library)
        }
        controls.buttons["_XCUI:CloseWindow"].click()
        library.buttons["Retry"].click()
        XCTAssertTrue(library.staticTexts["Your recording is saved"].exists)
    }

    func testRecoveryAndMicrophoneStates() throws {
        openControls()
        controls.checkBoxes["Reduce motion"].click()
        controls.buttons["Active recording"].click()
        XCTAssertTrue(panel.buttons[muteLabel].waitForExistence(timeout: 4))
        capture("panel-reduced-motion", panel)
        panel.buttons[muteLabel].click()
        XCTAssertTrue(panel.buttons["Unmute microphone recording"].waitForExistence(timeout: 4))
        controls.checkBoxes["Microphone available"].click()
        let unavailable = panel.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Microphone unavailable.")).firstMatch
        XCTAssertTrue(unavailable.exists)
        XCTAssertFalse(unavailable.isEnabled)
        XCTAssertTrue(panel.buttons[finishLabel].isEnabled)
        capture("panel-microphone-unavailable-native", panel)
        attachTree("unavailable-microphone-accessibility", panel)
        controls.checkBoxes["Microphone available"].click()
        XCTAssertTrue(panel.buttons["Unmute microphone recording"].exists)
        controls.checkBoxes["Hold microphone change pending"].click()
        XCTAssertFalse(panel.buttons["Applying microphone change. Please wait."].isEnabled)
        XCTAssertTrue(panel.buttons[finishLabel].isEnabled)
        capture("panel-microphone-pending-native", panel)
        panel.buttons[finishLabel].click()
        waitFor(panel, "exists == false")

        controls.buttons["Saving status"].click()
        XCTAssertFalse(panel.buttons[finishLabel].isEnabled)
        let meter = panel.staticTexts.firstMatch
        XCTAssertTrue((meter.value as? String ?? "").contains("Inactive"))
        capture("panel-saving-native", panel)

        controls.buttons["Save failure"].click()
        XCTAssertTrue(panel.buttons["Retry saving. Recording has stopped; the local save is not confirmed."].isEnabled)
        capture("panel-save-failure-native", panel)
        panel.buttons["Hide status. It remains available in the menu bar."].click()
        openStatusMenu()
        XCTAssertTrue(app.menuItems["Retry Recovery"].isEnabled)
        XCTAssertFalse(app.menuItems["Start Recording"].exists)
        try captureMenu("menu-save-recovery")
        app.menuItems["Show Recording Status"].click()
        XCTAssertTrue(panel.waitForExistence(timeout: 4))
        panel.buttons["Retry saving. Recording has stopped; the local save is not confirmed."].click()
        waitFor(panel, "exists == false")

        controls.buttons["Stop unconfirmed"].click()
        XCTAssertTrue(panel.buttons["Retry stopping. Capture may still be active."].isEnabled)
        capture("panel-stop-unconfirmed-native", panel)
        controls.buttons["Interruption"].click()
        capture("panel-interrupted-native", panel)
        controls.buttons["Start failure"].click()
        capture("panel-start-failed-native", panel)
        let countBeforeCancel = library.scrollViews["Call library"].buttons.count
        controls.buttons["Starting status"].click()
        capture("panel-starting-native", panel)
        panel.buttons["Cancel start"].click()
        waitFor(panel, "exists == false")
        XCTAssertEqual(library.scrollViews["Call library"].buttons.count, countBeforeCancel)
    }

    func testAccessibleControlDescriptions() throws {
        try auditDescriptions()
        openControls()
        controls.buttons["Active recording"].click()
        XCTAssertTrue(panel.waitForExistence(timeout: 4))
        controls.buttons["_XCUI:CloseWindow"].click()
        try auditDescriptions()
    }

    func testLibraryAppearanceAndWindowLifecycle() throws {
        openControls()
        controls.checkBoxes["Long source title"].click()
        controls.checkBoxes["Reduce motion"].click()
        controls.buttons["Narrow window"].click()
        XCTAssertEqual(library.frame.width, 820, accuracy: 1)
        capture("library-narrow-long-title-light", library)
        openControls()
        controls.radioButtons["Dark"].click()
        controls.buttons["Open library"].click()
        capture("library-narrow-long-title-dark", library)
        XCTAssertTrue(library.sliders["Playback position"].isHittable)
        library.buttons["Export this transcript"].click()
        XCTAssertTrue(library.sheets.firstMatch.waitForExistence(timeout: 4))
        library.typeKey(.return, modifierFlags: [])
        waitFor(library.sheets.firstMatch, "exists == false")

        toggleFullscreen(app)
        waitUntil("library enters fullscreen") { self.library.frame.width.isFinite && self.library.frame.width > 1000 }
        capture("library-fullscreen-dark", library)
        toggleFullscreen(app)
        waitUntil("library exits fullscreen") { self.library.frame.width < 1000 }

        openControls()
        controls.buttons["_XCUI:CloseWindow"].click()
        library.buttons["_XCUI:MinimizeWindow"].click()
        XCTAssertEqual(runningPrototype()?.activationPolicy, .regular)
        app.menuBars.menuBarItems["File"].click()
        app.menuItems["Open Library"].firstMatch.click()
        XCTAssertTrue(library.isHittable)
        XCTAssertEqual(app.windows.matching(identifier: "Trigo").count, 1)
        library.buttons["_XCUI:CloseWindow"].click()
        XCTAssertFalse(library.exists)
        XCTAssertEqual(runningPrototype()?.activationPolicy, .accessory)
        openStatusMenu()
        statusItem.menuItems["Settings…"].click()
        XCTAssertTrue(app.windows["Trigo Settings · Design Study"].waitForExistence(timeout: 4))
        XCTAssertEqual(runningPrototype()?.activationPolicy, .accessory)
        capture("settings-without-library", app.windows["Trigo Settings · Design Study"])
    }

    func testPanelPreservesOtherApplicationFocusAndFullscreen() throws {
        openControls()
        controls.buttons["Active recording"].click()
        XCTAssertTrue(panel.waitForExistence(timeout: 4))
        controls.buttons["_XCUI:CloseWindow"].click()
        let companionID = "io.github.apshenichniy.trigo.prototype.desktopux.focusfixture"
        let companion = XCUIApplication(bundleIdentifier: companionID)
        companion.launch()
        defer { companion.terminate() }
        let input = companion.textFields["focus-probe"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        input.typeText("123")
        XCTAssertEqual(input.value as? String, "123")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, companionID)
        // Clicking a background app's XCUIElement activates that app before event delivery.
        // Anchor the real pointer event to the foreground fixture to test NSPanel nonactivation.
        let companionWindow = companion.windows.firstMatch
        clickWithoutActivating(panel.buttons[muteLabel], from: companionWindow)
        XCTAssertTrue(panel.buttons["Unmute microphone recording"].waitForExistence(timeout: 4))
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, companionID)
        input.typeText(" 456")
        XCTAssertEqual(input.value as? String, "123 456")

        toggleFullscreen(companion)
        XCTAssertTrue(companion.wait(for: .runningForeground, timeout: 8))
        XCTAssertTrue(companionWindow.waitForExistence(timeout: 8))
        waitUntil("companion enters fullscreen") { companionWindow.frame.width.isFinite && companionWindow.frame.width > 1000 }
        XCTAssertTrue(panel.buttons[finishLabel].isHittable)
        capture("focus-fixture-fullscreen", companionWindow)
        capture("panel-above-fullscreen", panel)
        clickWithoutActivating(panel.buttons[finishLabel], from: companionWindow)
        waitFor(panel, "exists == false")
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, companionID)
        input.typeText(" 789")
        XCTAssertEqual(input.value as? String, "123 456 789")
    }

    private func openControls() {
        app.menuBars.menuBarItems["Prototype"].click()
        app.menuItems["Design Controls…"].click()
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
    }

    func testKeyboardCommands() throws {
        commandKey("d", russian: "в")
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        commandKey("w", russian: "ц")
        waitFor(controls, "exists == false")
        commandKey(",", russian: "б")
        let settings = app.windows["Trigo Settings · Design Study"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        commandKey("w", russian: "ц")
        waitFor(settings, "exists == false")
    }

    func testPlayerAndScrollableTranscript() throws {
        let callList = library.scrollViews["Call library"]
        let originalWidth = callList.frame.width
        XCTAssertEqual(originalWidth, library.frame.width * 0.275, accuracy: 1)
        let divider = library.sliders["Call list width"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        divider.click(forDuration: 0.2, thenDragTo: divider.withOffset(CGVector(dx: -70, dy: 0)))
        XCTAssertEqual(callList.frame.width, originalWidth - 70, accuracy: 3)
        let resizedWidth = callList.frame.width
        capture("library-sidebar-resized", library)
        library.buttons["Hide sidebar"].click()
        XCTAssertFalse(callList.exists)
        capture("library-sidebar-hidden", library)
        library.buttons["Show sidebar"].click()
        XCTAssertTrue(callList.exists)
        XCTAssertEqual(callList.frame.width, resizedWidth, accuracy: 1)
        let slider = library.sliders["Playback position"]
        library.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Speaker 2, 00:46.")).firstMatch.click()
        XCTAssertEqual((slider.value as? NSNumber)?.doubleValue, 46)
        library.buttons["Play sample timeline"].click()
        waitUntil("sample playback advances") { (slider.value as? NSNumber)?.doubleValue ?? 0 > 47 }
        library.buttons["Pause sample playback"].click()
        XCTAssertTrue(library.buttons["Play sample timeline"].exists)
        library.buttons["Mute sample playback"].click()
        XCTAssertTrue(library.buttons["Unmute sample playback"].exists)
        slider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertGreaterThan((slider.value as? NSNumber)?.doubleValue ?? 0, 100)
        openControls()
        controls.buttons["Narrow window"].click()
        library.scrollViews["Transcript passages"].scroll(byDeltaX: 0, deltaY: -500)
        let lastPassage = library.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Speaker 2, 01:51.")).firstMatch
        XCTAssertTrue(lastPassage.isHittable)
        lastPassage.click()
        XCTAssertEqual((slider.value as? NSNumber)?.doubleValue, 111)
        XCTAssertTrue(slider.isHittable)
        capture("library-narrow-scrolled", library)
        library.menuButtons["More recording actions"].click()
        app.menuItems["Show sample recording details"].click()
        XCTAssertTrue(app.staticTexts["Sample recording details"].waitForExistence(timeout: 4))
        capture("library-recording-details", library)
        library.sheets.firstMatch.buttons["Done"].click()
    }

    private func commandKey(_ latin: String, russian: String) {
        // XCUI key strings must exist on the selected physical layout. Do not change the user's layout.
        let layout = UserDefaults(suiteName: "com.apple.HIToolbox")?.string(forKey: "AppleCurrentKeyboardLayoutInputSourceID")
        app.typeKey(layout == "com.apple.keylayout.Russian" ? russian : latin, modifierFlags: .command)
    }

    private func waitFor(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 6) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed { attachTree("wait-failure-accessibility", app) }
        XCTAssertEqual(result, .completed, predicate)
    }

    private func runningPrototype() -> NSRunningApplication? {
        prototypeProcess
    }

    private func capture(_ name: String, _ element: XCUIElement) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureMenu(_ name: String) throws {
        capture(name, statusItem.menus.firstMatch)
    }

    private func toggleFullscreen(_ application: XCUIApplication, menuName: String = "Window") {
        let windowMenu = application.menuBars.menuBarItems[menuName]
        windowMenu.click()
        let enter = windowMenu.menuItems["Enter Full Screen"].firstMatch
        let item = enter.exists ? enter : windowMenu.menuItems["Exit Full Screen"].firstMatch
        XCTAssertGreaterThan(item.frame.width, 0)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func openStatusMenu() {
        if let screen = NSScreen.main, let safeArea = screen.auxiliaryTopRightArea,
           statusItem.frame.minX < safeArea.minX {
            // The crowded local menu bar can place this disposable item under the camera notch.
            // Move only our item using macOS's standard Command-drag; it vanishes on termination.
            let visibleLeft = max(statusItem.frame.minX, safeArea.minX)
            let visibleMidX = (visibleLeft + statusItem.frame.maxX) / 2
            XCTAssertLessThan(visibleLeft, statusItem.frame.maxX, "The prototype status item must have a visible part outside the notch")
            let normalizedX = (visibleMidX - statusItem.frame.minX) / statusItem.frame.width
            let start = statusItem.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.5))
            let offset = screen.frame.maxX - 240 - visibleMidX
            XCUIElement.perform(withKeyModifiers: .command) {
                start.click(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: offset, dy: 0)))
            }
        }
        statusItem.click()
        waitUntil("status menu is visible") { self.statusItem.menus.firstMatch.frame.width > 0 }
    }

    private func waitUntil(_ description: String, condition: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 8)
        if result != .completed { attachTree("wait-failure-accessibility", app) }
        XCTAssertEqual(result, .completed, description)
    }

    private func clickWithoutActivating(_ element: XCUIElement, from foregroundWindow: XCUIElement) {
        let target = element.frame
        let origin = foregroundWindow.frame.origin
        foregroundWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: target.midX - origin.x, dy: target.midY - origin.y)).click()
    }

    private func auditDescriptions() throws {
        try app.performAccessibilityAudit(for: .sufficientElementDescription) { issue in
            // AppKit exposes an empty virtual Touch Bar on this Mac without Touch Bar hardware.
            // It has no controls or content to describe; keep every actual UI issue reportable.
            if let element = issue.element, element.elementType == .touchBar,
               element.descendants(matching: .any).count == 0 { return true }
            if let element = issue.element { self.attachTree("accessibility-audit-element", element) }
            return false
        }
    }

    private func attachTree(_ name: String, _ element: XCUIElement) {
        let attachment = XCTAttachment(string: element.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
