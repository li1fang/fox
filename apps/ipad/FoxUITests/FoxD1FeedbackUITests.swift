import XCTest

final class FoxD1FeedbackUITests: XCTestCase {
    private func launch(fixture: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": fixture]
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        return app
    }

    private func waitFor(_ predicate: @escaping () -> Bool, timeout: TimeInterval = 20) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed {
            let app = XCUIApplication()
            print("D1_WAIT_FAILURE_AX\n\(app.debugDescription)")
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "d1-original-wait-failure"; image.lifetime = .keepAlways; add(image)
        }
        XCTAssertEqual(result, .completed)
    }

    private func reopen(_ app: XCUIApplication) {
        app.buttons["confirm-summary"].tap()
        XCTAssertTrue(app.staticTexts["training-saved-receipt"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch()
        let rows = app.openReadOnlyTrainingHistory()
        XCTAssertEqual(rows.count, 1)
        let row = rows.firstMatch, id = row.identifier
        XCTAssertNotNil(UUID(uuidString: String(id.dropFirst("home-history-".count))))
        XCTAssertTrue(row.label.contains("已确认训练回顾"))
        app.buttons[id].tap()
        XCTAssertTrue(app.scrollViews["home-training-detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本机档案 · 只读"].exists)
        XCTAssertFalse(app.buttons["begin-set"].exists)
    }

    private func assertUnknownTerminalReturn(_ app: XCUIApplication) {
        let summary = app.descendants(matching: .any).matching(identifier: "return-interval-summary").firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        let terminal = summary.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "第 2 次", "本观察段末次 · 不统计返回"))
        XCTAssertEqual(terminal.count, 1)
    }

    func testCountingWithoutUsableObservationRequiresExplicitZeroAndPreservesIt() {
        let app = launch(fixture: "low_confidence")
        app.buttons["home-prepare-curl"].tap()
        app.buttons["begin-set"].tap()
        waitFor { app.buttons["pause-set"].exists && app.staticTexts["workout-automatic-count"].label == "0" }
        app.buttons["complete-set"].tap()
        let count = app.textFields["actual-left-reps"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.value as? String, "次数")
        XCTAssertTrue(app.staticTexts["feedback-visual-count-unconfirmed"].exists)
        XCTAssertFalse(app.buttons["submit-feedback"].isEnabled)
        app.buttons["actual-left-reps-plus"].tap(); app.buttons["actual-left-reps-minus"].tap()
        XCTAssertEqual(count.value as? String, "0")
        XCTAssertTrue(app.buttons["submit-feedback"].isEnabled)
        app.buttons["submit-feedback"].tap()
        reopen(app)
        XCTAssertTrue(app.staticTexts["左臂 0 次 · 单侧"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["视觉观测：左臂 0 次"].firstMatch.exists)
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testAcceptedNonzeroAndManualOverrideKeepUnknownTerminalReturn() {
        let app = launch(fixture: "normal")
        app.openTrainingCapability("home-try-latPulldown")
        app.buttons["begin-set"].tap()
        waitFor { app.staticTexts["workout-automatic-count"].label == "2" }
        app.buttons["complete-set"].tap()
        let count = app.textFields["actual-reps"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); XCTAssertEqual(count.value as? String, "2")
        XCTAssertFalse(app.staticTexts["feedback-visual-count-unconfirmed"].exists)
        assertUnknownTerminalReturn(app)
        app.buttons["actual-reps-plus"].tap(); XCTAssertEqual(count.value as? String, "3")
        app.buttons["submit-feedback"].tap()
        reopen(app)
        XCTAssertTrue(app.staticTexts["3 次"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["视觉观测：左臂 2 次"].firstMatch.exists)
        assertUnknownTerminalReturn(app)
        XCTAssertTrue(app.staticTexts["完整离心节奏：未评估"].firstMatch.exists)
        XCTAssertEqual(app.webViews.count, 0)
    }
}
