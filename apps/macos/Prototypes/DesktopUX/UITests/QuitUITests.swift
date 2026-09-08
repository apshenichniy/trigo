import AppKit
import XCTest

@MainActor
final class QuitUITests: XCTestCase {
    private let app = XCUIApplication()
    private var controls: XCUIElement { app.windows["Trigo Prototype Controls"] }

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    override func tearDown() async throws {
        if app.state != .notRunning { app.terminate() }
    }

    func testCommandQExitsIdlePrototype() {
        commandQuit()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 4))
    }

    func testCommandQExitsHeldSavingFixture() {
        selectFixture("Saving status")
        commandQuit()
        assertPrototypeExited()
    }

    func testCommandQExitsHeldRecoveryFixture() {
        selectFixture("Stop unconfirmed")
        commandQuit()
        assertPrototypeExited()
    }

    func testCommandQExitsRecordingFixture() {
        selectFixture("Active recording")
        commandQuit()
        assertPrototypeExited()
    }

    func testSimulatedQuitWaitsForHeldSaving() {
        selectFixture("Saving status")
        simulateQuit()
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 1))
        controls.buttons["Reset to idle"].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 4))
    }

    func testSimulatedQuitPreservesUnresolvedRecovery() {
        selectFixture("Stop unconfirmed")
        simulateQuit()
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 1))
        XCTAssertTrue(controls.buttons["Reset to idle"].exists)
        commandQuit()
        assertPrototypeExited()
    }

    func testSimulatedQuitCanCancelThenFinishRecording() {
        selectFixture("Active recording")
        simulateQuit()
        XCTAssertTrue(app.staticTexts["Finish recording and quit?"].waitForExistence(timeout: 4))
        app.buttons.matching(identifier: "Keep Trigo open").firstMatch.click()
        XCTAssertFalse(app.wait(for: .notRunning, timeout: 1))
        simulateQuit()
        app.buttons.matching(identifier: "Finish and quit").firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 6))
    }

    func testSimulatedQuitRetiresStartingFixture() {
        selectFixture("Starting status")
        simulateQuit()
        XCTAssertTrue(app.staticTexts["Finish recording and quit?"].waitForExistence(timeout: 4))
        app.buttons.matching(identifier: "Finish and quit").firstMatch.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 4))
    }

    private func simulateQuit() {
        app.menuBars.menuBarItems["Prototype"].click()
        app.menuItems["Simulate Trigo Quit…"].click()
    }

    private func selectFixture(_ title: String) {
        app.menuBars.menuBarItems["Prototype"].click()
        app.menuItems["Design Controls…"].click()
        controls.buttons[title].click()
    }

    private func commandQuit() {
        let layout = UserDefaults(suiteName: "com.apple.HIToolbox")?.string(forKey: "AppleCurrentKeyboardLayoutInputSourceID")
        app.typeKey(layout == "com.apple.keylayout.Russian" ? "й" : "q", modifierFlags: .command)
    }

    private func assertPrototypeExited() {
        let exited = app.wait(for: .notRunning, timeout: 4)
        if !exited {
            let attachment = XCTAttachment(string: controls.debugDescription)
            attachment.name = "quit-held-state"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(exited, "A held synthetic fixture must not trap the design workbench")
    }
}
