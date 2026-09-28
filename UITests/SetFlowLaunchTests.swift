import XCTest

final class SetFlowLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testBootstrapHomeLaunches() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Set Flow"].exists)
        XCTAssertTrue(app.staticTexts["Routine editor, session runner, rest timer, and private history land in the next milestones."].exists)
    }
}
