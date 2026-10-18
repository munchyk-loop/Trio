import XCTest
final class SearchProbeTests: XCTestCase {
    @MainActor func testRealTrio() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "__TRIO_TEST_BUNDLE_IDENTIFIER__")
        app.launchArguments = ["--settings-search-ui-tests"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for _ in 0 ..< 20 {
            if app.buttons["I'm a Tester"].exists { app.buttons["I'm a Tester"].tap() }
            if springboard.buttons["Don’t Allow"].exists { springboard.buttons["Don’t Allow"].tap() }
            if app.tabBars.buttons["Settings"].exists { break }
            Thread.sleep(forTimeInterval: 1)
        }
        if app.buttons["I'm a Tester"].waitForExistence(timeout: 5) { app.buttons["I'm a Tester"].tap() }
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        let profile = app.buttons["settings.profile"]
        for _ in 0 ..< 3 {
            settings.tap()
            if profile.waitForExistence(timeout: 2) { break }
            if app.buttons["I'm a Tester"].exists { app.buttons["I'm a Tester"].tap() }
        }
        XCTAssertTrue(profile.waitForExistence(timeout: 5), app.debugDescription)
        for attempt in 0 ..< 15 {
            let scenario = attempt % 3
            let search = app.buttons["settings.search.open"]
            XCTAssertTrue(search.waitForExistence(timeout: 3), app.debugDescription)
            let searchAnchor = search.frame.midX
            search.tap()
            let field = app.textFields["settings.search.field"]
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "Opening must focus the field.")
            XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertLessThan(
                field.frame.maxY,
                app.keyboards.firstMatch.frame.minY - 80,
                "The field must remain in the top bar, away from the keyboard."
            )
            XCTAssertTrue(["", "Search Settings"].contains(field.value as? String ?? ""), "Reopening must clear the query.")
            if attempt == 0 {
                let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                image.name = "Trio Expanded Search"
                image.lifetime = .keepAlways
                add(image)
            }
            Thread.sleep(forTimeInterval: [0.0, 0.1, 0.4, 1.0, 2.0][attempt % 5])
            if scenario > 0 { field.typeText("glucose") }
            if scenario == 2 {
                field.typeText("\n")
                Thread.sleep(forTimeInterval: 1)
                XCTAssertEqual(app.keyboards.count, 0, "Submitting must leave the keyboard dismissed.")
                XCTAssertFalse(profile.exists, "Submitting must preserve the search results screen.")
            }
            let close = app.buttons["settings.search.close"]
            XCTAssertTrue(close.waitForExistence(timeout: 3), app.debugDescription)
            let mode = app.navigationBars.buttons["settings.loop-mode"]
            XCTAssertFalse(mode.isHittable, "Loop Mode is hidden while search is active.")
            XCTAssertGreaterThanOrEqual(close.frame.minX, field.frame.maxX - 1, "Close must stay to the right of the field.")
            XCTAssertEqual(close.frame.midX, searchAnchor, accuracy: 1, "Search and close must use the same anchor.")
            close.tap()
            XCTAssertTrue(profile.waitForExistence(timeout: 5), app.debugDescription)
            Thread.sleep(forTimeInterval: 2)
            XCTAssertTrue(profile.exists, app.debugDescription)
            XCTAssertEqual(app.keyboards.count, 0, app.debugDescription)
            // The collapsed field must not accept input.
            XCTAssertFalse(app.textFields["settings.search.field"].isHittable, app.debugDescription)
            XCTAssertTrue(mode.isHittable, app.debugDescription)
            XCTAssertTrue(search.isHittable, app.debugDescription)
            XCTAssertLessThan(mode.frame.maxX, search.frame.minX)
        }
        app.buttons["settings.search.open"].tap()
        app.textFields["settings.search.field"].typeText("Caregivers")
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Caregivers")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), app.debugDescription)
        result.tap()
        let destination = app.navigationBars["Caregivers"]
        XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription)
        destination.buttons.firstMatch.tap()
        XCTAssertTrue(profile.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["settings.search.open"].isHittable, app.debugDescription)
        XCTAssertFalse(app.buttons["settings.search.close"].isHittable, app.debugDescription)
    }
}
