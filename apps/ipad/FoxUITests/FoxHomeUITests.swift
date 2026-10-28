import XCTest

final class FoxHomeUITests: XCTestCase {
    func testSyncEntryCanCloseWithoutPairingOrChangingTraining() {
        let app = launch()
        XCTAssertTrue(app.buttons["journal-sync"].waitForExistence(timeout: 10))
        app.buttons["journal-sync"].tap()
        XCTAssertTrue(app.buttons["sync-import"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["尚未配对"].exists)
        XCTAssertFalse(app.buttons["sync-now"].exists)
        app.buttons["sync-close"].tap()
        XCTAssertTrue(app.buttons["home-prepare-curl"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-history"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "journal-note").firstMatch.exists)
    }
    private func launch(failSave: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_WEB_URL"] = "http://127.0.0.1:1/unreachable"
        if failSave { app.launchEnvironment["FOX_UI_FAIL_JOURNAL_SAVE_ONCE"] = "1" }
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        return app
    }

    func testHomeSavesToRealLocalRepositoryAndSurvivesRelaunch() {
        let app = launch()
        XCTAssertEqual(app.webViews.count, 0)
        XCTAssertTrue(app.buttons["home-history"].waitForExistence(timeout: 10))
        let field = app.descendants(matching: .any).matching(identifier: "journal-note").firstMatch
        field.tap(); field.typeText("Woke up with a headache.\nBreakfast at 08:10.")
        app.buttons["journal-save"].tap()
        XCTAssertTrue(app.staticTexts["journal-saved"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journal-record-")).count, 1)
        app.terminate(); app.launchArguments = []; app.launch()
        let record = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journal-record-")).firstMatch
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        XCTAssertTrue(app.staticTexts["Woke up with a headache.\nBreakfast at 08:10."].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "home-saved-detail"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testFailureKeepsDraftAndRetryCreatesOnlyOneRecord() {
        let app = launch(failSave: true)
        let field = app.descendants(matching: .any).matching(identifier: "journal-note").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Two lamb chops, 56 yuan.")
        app.buttons["journal-save"].tap()
        XCTAssertTrue(app.staticTexts["journal-save-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Two lamb chops, 56 yuan.")
        app.buttons["journal-save"].tap()
        XCTAssertTrue(app.staticTexts["journal-saved"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journal-record-")).count, 1)
    }

    func testTrainingCanReturnHomeWithoutStartingAWorkout() {
        let app = launch()
        app.openManualTrainingPlan()
        XCTAssertTrue(app.buttons["training-home"].waitForExistence(timeout: 5))
        app.buttons["training-home"].tap()
        XCTAssertTrue(app.buttons["home-history"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-resume-' OR identifier BEGINSWITH 'home-preparation-' ")).count, 0)
        XCTAssertEqual(app.webViews.count, 0)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "native-home-portrait"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCUIDevice.shared.orientation = .landscapeLeft
        let field = app.descendants(matching: .any).matching(identifier: "journal-note").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(field.frame.maxX, app.frame.maxX)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "native-home-landscape"; landscape.lifetime = .keepAlways; add(landscape)
    }

    func testActiveTrainingPausesWhenReturningHomeAndCanBeReopened() {
        let app = launch()
        app.openManualTrainingPlan()
        let start = app.buttons["start-training"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        for _ in 0..<8 {
            if start.isHittable { break }
            app.swipeUp()
        }
        start.tap()
        app.buttons["begin-set"].tap()
        XCTAssertTrue(app.buttons["pause-set"].waitForExistence(timeout: 5))
        app.buttons["training-home"].tap()
        XCTAssertTrue(app.buttons["home-history"].waitForExistence(timeout: 5))
        let resumed = app.resumeOnlyStartedTraining()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5))
        app.buttons["training-home"].tap()
        XCTAssertTrue(app.buttons[resumed].waitForExistence(timeout: 5))
    }
}
