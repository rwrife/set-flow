import Foundation
import XCTest

final class SetFlowLaunchTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        return app
    }

    @MainActor
    func testBootstrapHomeLaunches() throws {
        let app = launch()
        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Set Flow"].exists)
    }

    @MainActor
    func testCreateRoutineAndRunCompleteSession() throws {
        let app = launch()
        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))

        app.buttons["routine.create"].tap()
        XCTAssertTrue(app.textFields["routine.name"].waitForExistence(timeout: 5))

        let name = app.textFields["routine.name"]
        name.tap()
        name.typeText("Push Day")

        // Add both exercise rows BEFORE typing into them: `block.add`
        // dismisses the keyboard, and rows below the keyboard are unhittable.
        app.buttons["block.add"].tap()
        app.buttons["block.add"].tap()
        let exercise1 = app.textFields["block.name"].firstMatch
        XCTAssertTrue(exercise1.waitForExistence(timeout: 5))

        exercise1.tap()
        exercise1.typeText("Push Up")

        // The keyboard covers lower rows; scroll the Form before the next
        // exercise field can be hit. `matching(...).element(boundBy:)` is
        // query-level API (XCUIElement only exposes firstMatch).
        app.swipeUp()
        let exercise2 = app.textFields.matching(identifier: "block.name").element(boundBy: 1)
        XCTAssertTrue(exercise2.waitForExistence(timeout: 5))
        exercise2.tap()
        exercise2.typeText("Pull Up")

        app.buttons["routine.save"].tap()

        // Start the routine from the home list.
        let start = app.buttons["routine.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        // Session runner: first set.
        let reps = app.textFields["session.reps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["session.current"].label.contains("Push Up"))
        XCTAssertTrue(app.staticTexts["session.next"].label.contains("Pull Up"))

        reps.tap()
        reps.typeText("10")
        app.buttons["session.log"].tap()
        XCTAssertTrue(app.staticTexts["session.result"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["session.result"].label.contains("10"))

        // Second set is now current; preview shows no further exercise.
        XCTAssertTrue(app.staticTexts["session.current"].label.contains("Pull Up"))

        let reps2 = app.textFields["session.reps"]
        reps2.tap()
        reps2.typeText("8")
        app.buttons["session.log"].tap()

        // All planned slots resolved → finish becomes available.
        let finish = app.buttons["session.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        finish.tap()

        // Back on home, no active session remains (bounded poll: reload
        // happens asynchronously after the push is dismissed).
        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))
        var resumeGone = false
        for _ in 0..<20 {
            if !app.buttons["session.resume"].exists {
                resumeGone = true
                break
            }
            usleep(250_000)
        }
        XCTAssertTrue(resumeGone)
    }
}
