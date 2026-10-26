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

    private func readyToTap(_ element: XCUIElement, in app: XCUIApplication, keyboardDismissed: Bool = false) {
        var previous: CGRect?, stableSince: TimeInterval?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists, element.isEnabled, element.isHittable,
                  app.frame.contains(element.frame), (!keyboardDismissed || !app.keyboards.firstMatch.exists) else {
                previous = nil; stableSince = nil; return false
            }
            let frame = element.frame, now = ProcessInfo.processInfo.systemUptime
            if previous != frame { previous = frame; stableSince = now; return false }
            return now - (stableSince ?? now) >= 0.25
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 5)
        if result != .completed { failureEvidence(app, phase: "target-not-ready-\(element.identifier)") }
        XCTAssertEqual(result, .completed)
    }

    private func failureEvidence(_ app: XCUIApplication, phase: String) {
        print("FOX_NATIVE_UI_FAILURE \(phase)\n\(app.debugDescription)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = phase; shot.lifetime = .keepAlways; add(shot)
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
            if index > 0 {
                let rest = app.buttons["rest-ready"]
                readyToTap(rest, in: app, keyboardDismissed: true)
                XCTAssertFalse(app.scrollViews["set-feedback"].exists)
                rest.tap()
                let transitioned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    !rest.exists && app.buttons["begin-set"].exists
                }, object: nil)
                let result = XCTWaiter.wait(for: [transitioned], timeout: 5)
                if result != .completed { failureEvidence(app, phase: "rest-did-not-become-ready-\(index)") }
                XCTAssertEqual(result, .completed)
            }
            if index == 0 {
                let confirm = app.buttons["confirm-set-weight"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 5))
                if !confirm.isHittable { app.swipeUp() }
                confirm.tap()
                XCTAssertFalse(confirm.isEnabled)
            }
            let begin = app.buttons["begin-set"]
            readyToTap(begin, in: app)
            begin.tap()
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
            app.dismissNumericKeyboardPopover()
            if index == 0 {
                readyToTap(app.buttons["feedback-dismiss-keyboard"], in: app)
                XCTAssertTrue(app.buttons["feedback-dismiss-keyboard"].isHittable)
                app.buttons["feedback-dismiss-keyboard"].tap()
                XCTAssertFalse(app.keyboards.firstMatch.exists)
                app.openOptionalTrainingFeedback()
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
                issue.tap()
                let inputStarted = ProcessInfo.processInfo.systemUptime
                issue.typeText("语音反馈测试")
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - inputStarted, 20, "Chinese input must not consume an animation-idle timeout")
                XCTAssertEqual(issue.value as? String, "语音反馈测试")
            }
            let submit = app.buttons["submit-feedback"]
            readyToTap(submit, in: app)
            // Use the current frame after keyboard movement, not a stale AX activation point.
            submit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        app.dismissNumericKeyboardPopover()
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

extension XCUIApplication {
    func dismissNumericKeyboardPopover(file: StaticString = #filePath, line: UInt = #line) {
        // iPad's Chinese numeric popover blocks other fields and commands.
        // Close only that overlay; keep the keyboard and input/layout assertions.
        guard keyboards.firstMatch.exists else { return }
        // Record editors can have an identically named dismissal region. Never
        // target an app sheet when only the keyboard's numeric overlay is intended.
        let keyboardWindow = windows.containing(.keyboard, identifier: nil).firstMatch
        let dismiss = keyboardWindow.otherElements["PopoverDismissRegion"]
        if dismiss.waitForExistence(timeout: 2) {
            dismiss.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dismiss)
            XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, file: file, line: line)
        }
    }
}
