import Foundation
import XCTest

/// History journey (issue #5): complete a session, then verify the private
/// history screen explains each metric, keeps units/side facts explicit, and
/// labels sets missing load or reps rather than counting them as zero.
final class HistoryTests: XCTestCase {
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

    /// Bounded scroll for lazy List rows: swipe until the identifier exists.
    /// No keyboard is present at this point in the journey, so window-level
    /// swipes scroll the history List.
    @MainActor
    private func scrollUntilExists(_ element: XCUIElement, in app: XCUIApplication, timeoutLabel: String) {
        if element.exists { return }
        for _ in 0..<6 {
            app.swipeUp()
            if element.waitForExistence(timeout: 2) { return }
        }
        XCTAssertTrue(element.exists, "\(timeoutLabel) never appeared after scrolling")
    }

    @MainActor
    func testHistoryShowsExplainableSummaryAfterSession() throws {
        let app = launch()
        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))

        // Create a one-exercise, one-set routine.
        app.buttons["routine.create"].tap()
        XCTAssertTrue(app.textFields["routine.name"].waitForExistence(timeout: 5))
        app.buttons["block.add"].tap()

        let name = app.textFields["routine.name"]
        name.tap()
        name.typeText("Leg Day\n")
        let exercise = app.textFields["block.name"].firstMatch
        XCTAssertTrue(exercise.waitForExistence(timeout: 5))
        exercise.tap()
        exercise.typeText("Squat\n")
        app.buttons["routine.save"].tap()

        // Run and complete the session. The routine editor does not capture
        // loads, so the logged set will (and must) show as volume-excluded.
        let start = app.buttons["routine.start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        let reps = app.textFields["session.reps"]
        XCTAssertTrue(reps.waitForExistence(timeout: 10))
        reps.tap()
        reps.typeText("5")
        app.buttons["session.log"].firstMatch.tap()

        let finish = app.buttons["session.finish"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        finish.tap()
        XCTAssertTrue(app.otherElements["bootstrap.home"].waitForExistence(timeout: 10))

        // Open history.
        let historyButton = app.buttons["history.open"]
        XCTAssertTrue(historyButton.waitForExistence(timeout: 5))
        historyButton.tap()

        // Week is grouped and labeled; metrics carry their meaning in text.
        let weekLabel = app.staticTexts["history.week"]
        XCTAssertTrue(weekLabel.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["history.sessions"].label.contains("1 completed"))
        XCTAssertTrue(app.staticTexts["history.sessionCompletion"].label.contains("100%"))
        XCTAssertTrue(app.staticTexts["history.consistency"].label.contains("100%"))

        // The set had no recorded load → excluded from volume, labeled as such.
        let volumeNote = app.staticTexts["history.volume.note"]
        scrollUntilExists(volumeNote, in: app, timeoutLabel: "history.volume.note")
        XCTAssertTrue(volumeNote.exists)
        let exerciseRow = app.staticTexts["history.exercise"].firstMatch
        scrollUntilExists(exerciseRow, in: app, timeoutLabel: "history.exercise")
        XCTAssertTrue(exerciseRow.label.contains("Squat"))
        XCTAssertTrue(exerciseRow.label.contains("1 planned set"))
        let excluded = app.staticTexts["history.exercise.excluded"]
        scrollUntilExists(excluded, in: app, timeoutLabel: "history.exercise.excluded")
        XCTAssertTrue(excluded.label.contains("excluded"))

        // No asymmetry claim without both sides logged.
        XCTAssertFalse(app.staticTexts["history.asymmetry"].exists)

        // The formulas themselves are on-screen (below the fold — scroll).
        let formula = app.staticTexts["history.formula.volume"]
        scrollUntilExists(formula, in: app, timeoutLabel: "history.formula.volume")
        XCTAssertTrue(formula.exists)
        XCTAssertTrue(app.staticTexts["history.formula.consistency"].exists)
    }
}
