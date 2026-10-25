import XCTest

final class FoxWorkoutVisionUITests: XCTestCase {
    private func launch(fixture: String, failEarlyEndOnce: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_START_SCREEN"] = "training"
        app.launchEnvironment["FOX_POSE_FIXTURE"] = fixture
        if failEarlyEndOnce { app.launchEnvironment["FOX_UI_FAIL_EARLY_END_ONCE"] = "1" }
        app.launchEnvironment["FOX_WEB_URL"] = "http://127.0.0.1:1/unreachable"
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["prepare-day1"].waitForExistence(timeout: 5))
        app.buttons["prepare-day1"].tap()
        XCTAssertTrue(app.staticTexts["Real exercise · Day 1"].waitForExistence(timeout: 5))
        app.buttons["start-training"].tap()
        return app
    }
    private func fill(_ field: XCUIElement, with value: String) {
        field.tap()
        let old = field.value as? String ?? ""
        let digits = old.filter(\.isNumber)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: digits.count) + value)
        XCUIApplication().dismissNumericKeyboardPopover()
    }

    private func waitForCount(_ expected: Int, in app: XCUIApplication) {
        let count = app.staticTexts["workout-automatic-count"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            count.exists && count.label == String(expected)
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 20)
        if result != .completed {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "failed-count-\(expected)"; screenshot.lifetime = .keepAlways; add(screenshot)
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "failed-count-ui-state"; state.lifetime = .keepAlways; add(state)
        }
        XCTAssertEqual(result, .completed)
    }

    func testFourVisualSetsCorrectionAndRelaunchWithoutServer() {
        let app = launch(fixture: "walk_in")
        for index in 0..<4 {
            if index > 0 { app.buttons["rest-ready"].tap() }
            if index == 1 {
                if UIDevice.current.userInterfaceIdiom == .phone { app.buttons["phone-training-details"].tap() }
                app.segmentedControls["workout-observation-arm"].buttons["右臂"].tap()
                if UIDevice.current.userInterfaceIdiom == .phone { app.buttons["phone-training-details-done"].tap() }
            }
            app.buttons["begin-vision-set"].tap()
            waitForCount(2, in: app)
            XCTAssertLessThanOrEqual(app.buttons["complete-set"].frame.maxY, app.frame.maxY)
            if index == 0 {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "workout-visual-landscape"; shot.lifetime = .keepAlways; add(shot)
            }
            app.buttons["complete-set"].tap()
            let left = app.textFields["actual-left-reps"], right = app.textFields["actual-right-reps"]
            XCTAssertTrue(left.waitForExistence(timeout: 5))
            if index == 0 { XCTAssertEqual(left.value as? String, "2") }
            fill(left, with: index == 0 ? "3" : "2")
            fill(right, with: "2")
            app.buttons["submit-feedback"].tap()
        }
        XCTAssertTrue(app.buttons["confirm-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["左 3 / 右 2 次"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["视觉观测：左臂 2 次"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["动作质量：未评估"].firstMatch.exists)
        app.buttons["confirm-summary"].tap()
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["记录"].tap(); app.buttons["record-confirmed"].tap()
        XCTAssertTrue(app.staticTexts["左 3 / 右 2 次"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testDeniedCameraCanSwitchToManualWithoutInventedCount() {
        let app = launch(fixture: "denied")
        app.buttons["begin-vision-set"].tap()
        XCTAssertTrue(app.buttons["manual-count"].waitForExistence(timeout: 5))
        app.buttons["manual-count"].tap()
        app.buttons["complete-set"].tap()
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "次数")
        XCTAssertEqual(app.textFields["actual-right-reps"].value as? String, "次数")
        fill(app.textFields["actual-left-reps"], with: "3")
        fill(app.textFields["actual-right-reps"], with: "2")
        app.buttons["submit-feedback"].tap()
        app.buttons["结束训练"].tap(); app.buttons["结束并核对记录"].tap()
        XCTAssertTrue(app.buttons["confirm-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["左 3 / 右 2 次"].firstMatch.exists)
        app.buttons["confirm-summary"].tap()
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
    }

    func testLostSubjectCanRebindInSameSetAndKeepPreviousCount() {
        let app = launch(fixture: "subject_loss")
        app.buttons["begin-vision-set"].tap()
        let rebind = app.buttons["rebind-vision-set"]
        XCTAssertTrue(rebind.waitForExistence(timeout: 15))
        XCTAssertTrue(rebind.isHittable)
        XCTAssertTrue(app.frame.contains(rebind.frame))
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "1")
        rebind.tap()
        waitForCount(2, in: app)
        app.buttons["complete-set"].tap()
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "2")
    }

    func testFailedEarlyEndKeepsCameraAndObservationForRetry() {
        let app = launch(fixture: "walk_in", failEarlyEndOnce: true)
        app.buttons["begin-vision-set"].tap()
        waitForCount(2, in: app)
        app.buttons["结束训练"].tap()
        app.buttons["结束并核对记录"].tap()
        let error = app.alerts["操作未完成"]
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        let disappears = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: error)
        XCTAssertEqual(XCTWaiter.wait(for: [disappears], timeout: 3), .timedOut)
        error.buttons["知道了"].tap()
        XCTAssertTrue(app.buttons["pause-set"].exists)
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "2")
        XCTAssertNotEqual(app.staticTexts["workout-tracking-status"].label, "相机已停止")
        XCTAssertFalse(app.buttons["confirm-summary"].exists)
        app.buttons["结束训练"].tap()
        app.buttons["结束并核对记录"].tap()
        XCTAssertTrue(app.buttons["confirm-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["视觉观测：左臂 2 次"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["次数未确认"].firstMatch.exists)
        app.buttons["confirm-summary"].tap()
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launchEnvironment["FOX_UI_FAIL_EARLY_END_ONCE"] = nil; app.launch()
        app.buttons["记录"].tap(); app.buttons["record-confirmed"].tap()
        XCTAssertTrue(app.staticTexts["视觉观测：左臂 2 次"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["次数未确认"].firstMatch.exists)
    }

    func testPortraitPauseBackgroundResumePreservesFinishedCyclesAndActualSides() {
        let app = launch(fixture: "walk_in")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["begin-vision-set"].tap()
        let count = app.staticTexts["workout-automatic-count"]
        waitForCount(2, in: app)
        XCTAssertLessThanOrEqual(app.buttons["complete-set"].frame.maxY, app.frame.maxY)
        app.buttons["pause-set"].tap()
        XCTAssertEqual(count.label, "2")
        XCTAssertTrue(app.buttons["complete-set"].isHittable)
        XCTAssertLessThanOrEqual(app.buttons["complete-set"].frame.maxY, app.frame.maxY)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "workout-visual-portrait-paused"; shot.lifetime = .keepAlways; add(shot)
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertEqual(count.label, "2")
        let resume = app.buttons["begin-vision-set"]
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: resume)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 5), .completed)
        resume.press(forDuration: 0.2)
        XCTAssertTrue(app.buttons["cancel-vision-preparation"].waitForExistence(timeout: 3))
        waitForCount(4, in: app)
        app.buttons["complete-set"].tap()
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "4")
        fill(app.textFields["actual-right-reps"], with: "3")
        XCTAssertLessThanOrEqual(app.textFields["actual-left-reps"].frame.maxX, app.frame.maxX)
        app.buttons["submit-feedback"].tap()
        app.buttons["结束训练"].tap(); app.buttons["结束并核对记录"].tap()
        XCTAssertTrue(app.staticTexts["左 4 / 右 3 次"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["视觉观测：左臂 4 次"].firstMatch.exists)
    }
}
