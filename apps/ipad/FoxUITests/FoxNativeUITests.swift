import XCTest

final class FoxNativeUITests: XCTestCase {
    private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_START_SCREEN"] = "training"
        // An unreachable legacy URL must never affect the native Fox entry.
        app.launchEnvironment["FOX_WEB_URL"] = "http://127.0.0.1:1/unreachable"
        if reset { app.launchArguments = ["--ui-testing-reset"] }
        app.launch()
        return app
    }

    func testOfflineTrainingLoopAndConfirmedRecordSurviveRelaunch() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        let settledLayout = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.staticTexts["Fox"].frame.minY < 100
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settledLayout], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["start-training"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.count, 0)
        let planScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        planScreenshot.name = "offline-plan-landscape"
        planScreenshot.lifetime = .keepAlways
        add(planScreenshot)
        app.buttons["start-training"].tap()
        for index in 0..<4 {
            if index > 0 { app.buttons["rest-ready"].tap() }
            if index == 0 {
                let confirm = app.buttons["confirm-set-weight"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                if !confirm.isHittable { app.swipeUp() }
                confirm.tap()
                XCTAssertFalse(confirm.isEnabled)
            }
            app.buttons["begin-set"].tap()
            if index == 0 {
                let activeScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                activeScreenshot.name = "offline-training-landscape"
                activeScreenshot.lifetime = .keepAlways
                add(activeScreenshot)
                XCTAssertLessThanOrEqual(app.buttons["complete-set"].frame.maxY, app.frame.maxY)
            }
            app.buttons["complete-set"].tap()
            let count = app.textFields["actual-reps"]
            XCTAssertTrue(count.waitForExistence(timeout: 5))
            count.tap()
            count.typeText("10")
            if index == 0 {
                XCTAssertTrue(app.buttons["feedback-dismiss-keyboard"].isHittable)
                app.buttons["feedback-dismiss-keyboard"].tap()
                XCTAssertFalse(app.keyboards.firstMatch.exists)
                let issue = app.descendants(matching: .any).matching(identifier: "trial-software-issue").firstMatch
                let form = app.scrollViews["set-feedback"]
                XCTAssertTrue(form.exists)
                for _ in 0..<8 {
                    if issue.isHittable && app.frame.contains(issue.frame) { break }
                    form.swipeUp()
                }
                if !issue.isHittable {
                    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    screenshot.name = "feedback-field-unreachable"; screenshot.lifetime = .keepAlways; add(screenshot)
                    let tree = XCTAttachment(string: app.debugDescription)
                    tree.name = "feedback-field-accessibility"; tree.lifetime = .keepAlways; add(tree)
                }
                XCTAssertTrue(issue.isHittable)
                issue.tap(); issue.typeText("语音反馈测试")
            }
            app.buttons["submit-feedback"].tap()
            if index == 0 {
                XCTAssertTrue(app.buttons["extend-rest"].waitForExistence(timeout: 5))
                app.buttons["extend-rest"].tap()
            }
        }
        XCTAssertTrue(app.buttons["confirm-summary"].waitForExistence(timeout: 5))
        let edit = app.buttons["修改本组记录"].firstMatch
        let summary = app.scrollViews["training-summary"]
        for _ in 0..<6 {
            if edit.isHittable && edit.frame.maxY <= summary.frame.maxY && edit.frame.minY >= summary.frame.minY { break }
            summary.swipeUp()
        }
        XCTAssertTrue(edit.isHittable)
        XCTAssertLessThanOrEqual(edit.frame.maxY, summary.frame.maxY)
        edit.tap()
        let editorOpened = app.navigationBars["修改本组记录"].waitForExistence(timeout: 5)
        if !editorOpened {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "summary-editor-not-opened"; image.lifetime = .keepAlways; add(image)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "summary-editor-not-opened-accessibility"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(editorOpened)
        let correctedCount = app.textFields["summary-reps"]
        correctedCount.tap()
        correctedCount.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "12")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts["12 次"].firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "offline-summary"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["confirm-summary"].tap()
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = []
        app.launch()
        app.buttons["记录"].tap()
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
        app.buttons["record-confirmed"].tap()
        XCTAssertTrue(app.scrollViews["record-detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["12 次"].firstMatch.exists)
        let review = app.staticTexts["软件问题：语音反馈测试"]
        for _ in 0..<8 { if review.exists { break }; app.scrollViews["record-detail"].swipeUp() }
        XCTAssertTrue(review.exists)
        XCTAssertEqual(app.webViews.count, 0)
    }

    func testActiveSetRecoversPausedAndCanBeEndedWithoutInventedReps() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        XCTAssertTrue(app.buttons["start-training"].waitForExistence(timeout: 5))
        app.buttons["start-training"].tap()
        XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 5))
        app.buttons["begin-set"].tap()
        XCTAssertTrue(app.buttons["pause-set"].waitForExistence(timeout: 5))
        let activeScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        activeScreenshot.name = "offline-training-portrait"
        activeScreenshot.lifetime = .keepAlways
        add(activeScreenshot)
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["已暂停"].waitForExistence(timeout: 5))
        app.buttons["complete-set"].tap()
        XCTAssertEqual(app.textFields["actual-reps"].value as? String, "次数")
        app.buttons["结束训练"].tap()
        app.buttons["结束并核对记录"].tap()
        XCTAssertTrue(app.staticTexts["次数未确认"].waitForExistence(timeout: 5))
        app.buttons["confirm-summary"].tap()
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
    }

    func testPlanEditorOpensAndSavesLocally() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        app.buttons["编辑计划"].tap()
        XCTAssertTrue(app.navigationBars["编辑计划"].waitForExistence(timeout: 5))
        app.buttons["保存"].tap()
        XCTAssertTrue(app.buttons["start-training"].waitForExistence(timeout: 5))
    }
}
