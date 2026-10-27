import XCTest

final class FoxTrainingStoryUITests: XCTestCase {
    private func launch(_ fixture: String = "normal", screen: String = "vision") -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_START_SCREEN"] = screen
        app.launchEnvironment["FOX_POSE_FIXTURE"] = fixture
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        return app
    }

    private func visible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertFalse(element.frame.isEmpty)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(element.frame), "Whole control must be on screen")
        XCTAssertTrue(element.isHittable)
    }

    private func count(_ expected: Int, id: String = "vision-count", in app: XCUIApplication) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", String(expected)), object: app.staticTexts[id])], timeout: 15), .completed)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "story-b-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testPreparationAndRecoveryKeepCountAndPrimaryActionsVisible() {
        let app = launch("subject_loss")
        visible(app.buttons["vision-start"], in: app)
        app.buttons["vision-start"].tap()
        visible(app.staticTexts["vision-task-detail"], in: app)
        XCTAssertTrue(app.buttons["vision-rebind"].waitForExistence(timeout: 15))
        count(1, in: app)
        XCTAssertTrue(app.staticTexts["vision-task-detail"].label.contains("已记 1 次保留"))
        visible(app.buttons["vision-rebind"], in: app)
        visible(app.buttons["vision-finish"], in: app)
        shot("recovery-portrait")
        app.buttons["vision-rebind"].tap()
        visible(app.buttons["vision-cancel-start"], in: app)
        XCTAssertTrue(app.staticTexts["vision-task-detail"].label.contains("已记 1 次保留"))
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 10))
        count(1, in: app)
        visible(app.buttons["vision-finish"], in: app)
    }

    func testResultsComeBeforeVideoAndSavedReceiptIsVisible() {
        let app = launch()
        visible(app.buttons["vision-start"], in: app); app.buttons["vision-start"].tap()
        count(2, in: app)
        visible(app.buttons["vision-finish"], in: app); app.buttons["vision-finish"].tap()
        visible(app.staticTexts["vision-review-counts"], in: app)
        visible(app.textFields["vision-reference-count"], in: app)
        XCTAssertEqual(app.staticTexts["vision-review-counts"].label, "自动 2 · 确认 2")
        app.buttons["vision-review-plus"].tap()
        XCTAssertEqual(app.staticTexts["vision-review-counts"].label, "自动 2 · 确认 3")
        app.buttons["vision-review-minus"].tap()
        XCTAssertEqual(app.staticTexts["vision-review-counts"].label, "自动 2 · 确认 2")
        let video = app.staticTexts["diagnostic-report-status"]
        XCTAssertTrue(video.exists)
        XCTAssertLessThan(app.staticTexts["vision-review-counts"].frame.maxY, video.frame.minY)
        shot("results-first")
        app.buttons["vision-save-report"].tap()
        visible(app.staticTexts["vision-saved-receipt"], in: app)
        XCTAssertTrue(app.staticTexts["vision-saved-receipt"].label.contains("记录已保存"))
        XCTAssertTrue(app.staticTexts["vision-saved-receipt"].label.contains("自动 2 · 确认 2"))
        shot("saved-receipt")
    }

    func testRealReferenceInputPersistsWithoutReplacingAutomaticCount() {
        let app = launch()
        visible(app.buttons["vision-start"], in: app); app.buttons["vision-start"].tap()
        count(2, in: app); app.buttons["vision-finish"].tap()
        let reference = app.textFields["vision-reference-count"]
        visible(reference, in: app)
        reference.tap(); reference.typeText("3")
        XCTAssertEqual(reference.value as? String, "3")
        app.dismissNumericKeyboardPopover()
        app.buttons["vision-save-report"].tap()
        visible(app.staticTexts["vision-saved-receipt"], in: app)
        app.terminate(); app.launchArguments = []; app.launch()
        visible(app.staticTexts["vision-saved-receipt"], in: app)
        XCTAssertTrue(app.staticTexts["vision-saved-receipt"].label.contains("自动 2 · 确认 2"))
        XCTAssertTrue(app.staticTexts["vision-saved-receipt"].label.contains("人工参考 3"))
    }

    func testRotationKeepsCameraCountAndPrimaryActions() {
        let app = launch()
        visible(app.buttons["vision-start"], in: app); app.buttons["vision-start"].tap()
        count(2, in: app)
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation != .portrait
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let f = app.windows.firstMatch.frame
                return f.width > 0 && (landscape ? f.width > f.height : f.height > f.width)
            }, object: nil)], timeout: 8), .completed)
            visible(app.buttons["vision-pause"], in: app)
            visible(app.buttons["vision-finish"], in: app)
            XCTAssertEqual(app.staticTexts["vision-count"].label, "2")
            shot("rotation-\(orientation.rawValue)")
        }
    }

    func testWorkoutRecoveryExplainsPreservedFacts() {
        let app = launch("subject_loss", screen: "training")
        app.buttons["training-tools"].tap()
        XCTAssertTrue(app.buttons["准备 Day 1 草稿"].waitForExistence(timeout: 5)); app.buttons["准备 Day 1 草稿"].tap()
        app.buttons["start-training"].tap()
        visible(app.buttons["begin-set"], in: app); app.buttons["begin-set"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["rebind-vision-set"])], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts["workout-task-detail"].label.contains("已记 1 次保留"))
        XCTAssertFalse(app.staticTexts["tempo-phase"].exists, "Lost observation must not present a current motion phase")
        visible(app.buttons["rebind-vision-set"], in: app)
        shot("workout-recovery")
        app.buttons["rebind-vision-set"].tap()
        count(2, id: "workout-automatic-count", in: app)
        visible(app.buttons["complete-set"], in: app); app.buttons["complete-set"].tap()
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "2")
        visible(app.buttons["submit-feedback"], in: app)
    }

    func testManualFallbackRestoresPlannedTempoWithoutDiscardingObservedCount() {
        let app = launch("normal", screen: "training")
        app.buttons["training-tools"].tap()
        XCTAssertTrue(app.buttons["准备 Day 1 草稿"].waitForExistence(timeout: 5)); app.buttons["准备 Day 1 草稿"].tap()
        app.buttons["start-training"].tap()
        app.buttons["begin-set"].tap()
        count(2, id: "workout-automatic-count", in: app)
        app.buttons["phone-training-details"].tap()
        app.buttons["manual-count"].tap()
        XCTAssertTrue(app.staticTexts["tempo-phase"].waitForExistence(timeout: 5), "Manual fallback must retain planned tempo guidance")
        XCTAssertFalse(app.staticTexts["等待有效观测"].exists)
        XCTAssertFalse(app.staticTexts["workout-task-detail"].exists, "Manual training must not ask for visual repositioning")
        shot("manual-fallback")
        app.buttons["complete-set"].tap()
        XCTAssertTrue(app.staticTexts["观测 左臂 2 次，待你确认"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "2")
    }
}
