import XCTest

final class DataSettingsTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Settings row was not reachable")
    }

    @MainActor
    func testPrivacyAndExplicitResetConfirmation() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()
        let open = app.buttons["settings.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["settings.backup"].waitForExistence(timeout: 5))
        reveal(app.buttons["settings.import"], in: app)
        let reset = app.buttons["settings.reset"]
        reveal(reset, in: app)
        reset.tap()
        let confirm = app.buttons["Delete all workouts"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["settings.notice"].waitForExistence(timeout: 5))
    }
}
