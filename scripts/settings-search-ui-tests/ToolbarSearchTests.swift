import XCTest
final class SearchProbeTests: XCTestCase {
    @MainActor func testToolbarClose() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let profile = app.staticTexts["profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 10), app.debugDescription)
        for attempt in 0 ..< 15 {
            let scenario = attempt % 3
            let search = app.buttons["settings.search.open"]
            XCTAssertTrue(search.waitForExistence(timeout: 3), app.debugDescription)
            let searchAnchor = search.frame.midX
            search.tap()
            let results = app.staticTexts["results"]
            XCTAssertTrue(results.waitForExistence(timeout: 3), app.debugDescription)
            let field = app.textFields["settings.search.field"]
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Opening must focus the field.")
            if attempt == 0 {
                let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                image.name = "Expanded Search"
                image.lifetime = .keepAlways
                add(image)
            }
            XCTAssertTrue(field.exists, app.debugDescription)
            XCTAssertLessThan(
                field.frame.maxY,
                app.keyboards.firstMatch.frame.minY - 80,
                "The field must remain in the top bar, away from the keyboard."
            )
            XCTAssertTrue(["", "Search Settings"].contains(field.value as? String ?? ""))
            if scenario > 0 { field.typeText("glucose") }
            if scenario == 2 {
                field.typeText("\n")
                XCTAssertTrue(results.exists, "Submitting must keep search results visible.")
                Thread.sleep(forTimeInterval: 1)
                XCTAssertEqual(app.keyboards.count, 0, "Submitting must not refocus the keyboard.")
            }
            let close = app.buttons["settings.search.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 3), app.debugDescription)
            let mode = app.navigationBars.buttons["settings.loop-mode"]
            XCTAssertFalse(mode.isHittable, "Loop Mode is hidden while search is active.")
            XCTAssertGreaterThanOrEqual(close.frame.minX, field.frame.maxX - 1, "Close must stay to the right of the field.")
            XCTAssertEqual(close.frame.midX, searchAnchor, accuracy: 1, "Search and close must use the same anchor.")
            close.tap()
            XCTAssertTrue(profile.waitForExistence(timeout: 5), app.debugDescription)
            // Catch a delayed reactivation after the close animation completes.
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(profile.exists, app.debugDescription)
            XCTAssertFalse(results.exists, app.debugDescription)
            // The collapsed field must not accept input.
            XCTAssertFalse(app.textFields["settings.search.field"].isHittable, app.debugDescription)
            XCTAssertEqual(app.keyboards.count, 0, app.debugDescription)
        }
    }
}
