import XCTest

final class DataSettingsTests: XCTestCase {
    func testPrivacyAndExplicitResetConfirmation() {
        let app = XCUIApplication()
        app.launchArguments.append("-ui-testing")
        app.launch()
        let open = app.buttons["settings.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.buttons["settings.backup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.import"].exists)
        app.buttons["settings.reset"].tap()
        let confirm = app.buttons["Delete all workouts"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["settings.notice"].waitForExistence(timeout: 5))
    }
}
