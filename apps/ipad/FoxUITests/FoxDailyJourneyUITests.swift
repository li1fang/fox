import XCTest

extension XCUIApplication {
    func openOptionalTrainingFeedback() {
        let toggle = buttons["补充反馈（可选）"]
        let form = scrollViews["set-feedback"]
        let footer = buttons["submit-feedback"]
        for _ in 0..<8 {
            if toggle.exists && toggle.isHittable && form.frame.intersection(windows.firstMatch.frame).contains(toggle.frame)
                && toggle.frame.maxY < footer.frame.minY - 8 { break }
            form.swipeUp()
        }
        XCTAssertTrue(toggle.exists)
        XCTAssertTrue(toggle.isHittable)
        XCTAssertLessThan(toggle.frame.maxY, footer.frame.minY - 8)
        toggle.tap()
        for _ in 0..<6 {
            if textFields["trial-information"].exists { break }
            form.swipeUp()
        }
        if !textFields["trial-information"].exists {
            print("FOX_OPTIONAL_FEEDBACK_AX\n\(debugDescription)")
        }
        XCTAssertTrue(textFields["trial-information"].exists)
    }
}

final class FoxDailyJourneyUITests: XCTestCase {
    private func launch(visual: Bool = false, failConfirm: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        if visual { app.launchEnvironment["FOX_POSE_FIXTURE"] = "normal" }
        if failConfirm { app.launchEnvironment["FOX_UI_FAIL_CONFIRM_ONCE"] = "1" }
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["home-training"].waitForExistence(timeout: 10))
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "daily-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func visible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
        XCTAssertFalse(element.frame.isEmpty)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(element.frame))
    }

    func testEntryAndFeedbackAudit() {
        let app = launch()
        shot("01-home")
        app.buttons["home-training"].tap()
        XCTAssertTrue(app.buttons["start-training"].waitForExistence(timeout: 5))
        shot("02-plan")
        for _ in 0..<6 { if app.buttons["start-training"].isHittable { break }; app.swipeUp() }
        app.buttons["start-training"].tap()
        app.buttons["begin-set"].tap()
        app.buttons["complete-set"].tap()
        XCTAssertTrue(app.textFields["actual-left-reps"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["submit-feedback"].isEnabled, "A target must never become an actual count automatically")
        shot("03-feedback")
        app.scrollViews["set-feedback"].swipeUp()
        shot("04-feedback-details")
    }

    func testPlanActionIsPinnedAndExperimentToolsAreSecondary() {
        let app = launch()
        app.buttons["home-training"].tap()
        visible(app.buttons["start-training"], in: app)
        XCTAssertFalse(app.buttons["准备 Day 1 草稿"].exists)
        visible(app.buttons["training-tools"], in: app)
        app.buttons["training-tools"].tap()
        XCTAssertTrue(app.buttons["准备 Day 1 草稿"].waitForExistence(timeout: 5))
        app.buttons["准备 Day 1 草稿"].tap()
        visible(app.buttons["start-training"], in: app)
        XCTAssertTrue(app.staticTexts["Real exercise · Day 1"].exists)
        shot("05-plan-visual")
    }

    func testManualCountConfirmationNeedsNoKeyboardAndRestAcknowledgesSave() {
        let app = launch()
        app.buttons["home-training"].tap(); app.buttons["start-training"].tap()
        app.buttons["begin-set"].tap(); app.buttons["complete-set"].tap()
        XCTAssertFalse(app.buttons["submit-feedback"].isEnabled)
        visible(app.buttons["actual-left-reps-plus"], in: app)
        app.buttons["actual-left-reps-plus"].tap(); app.buttons["actual-left-reps-plus"].tap()
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "2")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.textFields["trial-software-issue"].exists)
        app.buttons["submit-feedback"].tap()
        visible(app.staticTexts["training-set-saved"], in: app)
        visible(app.buttons["rest-ready"], in: app)
        app.buttons["extend-rest"].tap()
        shot("06-rest-saved")
        app.buttons["rest-ready"].tap()
        app.buttons["begin-set"].tap(); app.buttons["pause-set"].tap()
        app.buttons["training-home"].tap()
        app.buttons["home-training"].tap()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5))
        app.buttons["结束训练"].tap(); app.buttons["结束并核对记录"].tap()
        XCTAssertTrue(app.staticTexts["左 2 / 右 未确认 次"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["confirm-summary"].tap()
        visible(app.staticTexts["training-saved-receipt"], in: app)
        let historyTitle = app.staticTexts["training-history-title"].firstMatch
        XCTAssertTrue(historyTitle.exists)
        XCTAssertEqual(historyTitle.label, "我的哑铃训练")
        XCTAssertLessThanOrEqual(historyTitle.frame.height, 60)
        XCTAssertLessThanOrEqual(app.staticTexts["training-history-date"].firstMatch.frame.height, 45)
        XCTAssertLessThanOrEqual(app.buttons["record-confirmed"].frame.height, 180)
        shot("07-saved")
        app.buttons["training-saved-home"].tap()
        XCTAssertTrue(app.buttons["home-training"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["home-training"].tap(); app.buttons["记录"].tap()
        app.buttons["record-confirmed"].tap()
        XCTAssertTrue(app.staticTexts["左 2 / 右 未确认 次"].firstMatch.waitForExistence(timeout: 5))
    }

    func testFourVisualSetsConfirmAndReopenWithoutOptionalInput() {
        let app = launch(visual: true)
        app.buttons["home-training"].tap()
        app.buttons["training-tools"].tap(); app.buttons["准备 Day 1 草稿"].tap()
        app.buttons["start-training"].tap()
        for index in 0..<4 {
            if index > 0 {
                visible(app.staticTexts["training-set-saved"], in: app)
                app.buttons["rest-ready"].tap()
            }
            app.buttons["begin-set"].tap()
            let count = app.staticTexts["workout-automatic-count"]
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: count)], timeout: 20), .completed)
            app.buttons["complete-set"].tap()
            XCTAssertEqual(app.textFields[index < 2 ? "actual-left-reps" : "actual-right-reps"].value as? String, "2")
            XCTAssertFalse(app.textFields["trial-software-issue"].exists)
            visible(app.buttons["submit-feedback"], in: app)
            if index == 0 { shot("08-visual-confirmation") }
            app.buttons["submit-feedback"].tap()
        }
        visible(app.buttons["confirm-summary"], in: app)
        app.buttons["confirm-summary"].tap()
        visible(app.staticTexts["training-saved-receipt"], in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "record-confirmed").count, 1)
        app.buttons["view-saved-training"].tap()
        XCTAssertTrue(app.staticTexts["视觉观测：左臂 2 次"].firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["home-training"].tap(); app.buttons["记录"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "record-confirmed").count, 1)
    }

    func testFailedConfirmationKeepsSummaryAndRetrySavesOnlyOnce() {
        let app = launch(failConfirm: true)
        app.buttons["home-training"].tap(); app.buttons["start-training"].tap()
        app.buttons["begin-set"].tap(); app.buttons["pause-set"].tap()
        app.buttons["结束训练"].tap(); app.buttons["结束并核对记录"].tap()
        visible(app.buttons["confirm-summary"], in: app)
        app.buttons["confirm-summary"].tap()
        XCTAssertTrue(app.alerts["操作未完成"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["training-saved-receipt"].exists)
        app.alerts.buttons["知道了"].tap()
        visible(app.buttons["confirm-summary"], in: app)
        shot("09-save-failure-preserved")
        app.buttons["confirm-summary"].tap()
        visible(app.staticTexts["training-saved-receipt"], in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "record-confirmed").count, 1)
    }
}
