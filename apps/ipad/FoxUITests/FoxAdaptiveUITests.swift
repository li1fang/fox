import XCTest

final class FoxAdaptiveUITests: XCTestCase {
    private func launch(_ screen: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_START_SCREEN": screen,
                                 "FOX_POSE_FIXTURE": "normal", "FOX_POSE_IMAGE_FIXTURE": "1"]
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        return app
    }

    private func visible(_ element: XCUIElement, in app: XCUIApplication) {
        var observation = "not evaluated"
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let exists = element.exists
            guard exists else { observation = "missing"; return false }
            let enabled = element.isEnabled
            let frame = element.frame
            let window = app.windows.firstMatch.frame
            observation = "enabled=\(enabled), frame=\(frame), window=\(window)"
            return enabled && !frame.isEmpty && window.contains(frame)
        }, object: nil)
        // A fresh Duo can spend several seconds on each AX snapshot. Read each
        // property once per poll; retain full containment and real-touch assertions.
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, "\(element.identifier): \(observation)")
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        visible(element, in: app)
        // Duo's AX activation point can be invalid for a visibly contained control.
        // Use a real center touch; subsequent state assertions must still prove the action worked.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }

    override func tearDown() {
        snapshot(XCUIApplication(), "adaptive-final")
        super.tearDown()
    }

    func testManualTrainingFeedbackRestAndSummaryInAdaptiveWindow() {
        let app = launch("training")
        let start = app.buttons["start-training"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if !start.frame.isEmpty && app.windows.firstMatch.frame.contains(start.frame) { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        tap(start, in: app)
        for index in 0..<4 {
            XCUIDevice.shared.orientation = index % 2 == 0 ? .portrait : .landscapeLeft
            if index > 0 { tap(app.buttons["rest-ready"], in: app) }
            for id in ["phone-target-reps", "phone-target-weight", "set-elapsed"] { visible(app.staticTexts[id], in: app) }
            tap(app.buttons["begin-set"], in: app)
            if index == 0 {
                tap(app.buttons["pause-set"], in: app)
                tap(app.buttons["begin-set"], in: app)
                snapshot(app, "adaptive-manual-active")
            }
            tap(app.buttons["complete-set"], in: app)
            let count = app.textFields["actual-reps"]
            XCTAssertTrue(count.waitForExistence(timeout: 5)); tap(count, in: app); count.typeText("8")
            tap(app.buttons["feedback-dismiss-keyboard"], in: app)
            let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 5), .completed)
            snapshot(app, "adaptive-feedback-\(index)")
            XCTAssertEqual(count.value as? String, "8")
            tap(app.buttons["submit-feedback"], in: app)
        }
        visible(app.buttons["confirm-summary"], in: app); snapshot(app, "adaptive-summary")
        tap(app.buttons["confirm-summary"], in: app)
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["记录"].waitForExistence(timeout: 5)); app.buttons["记录"].tap()
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
    }

    func testVisualCounterAndReportSurviveAdaptiveRotation() {
        let app = launch("vision")
        tap(app.buttons["vision-start"], in: app)
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 20), .completed)
        let preview = app.otherElements["pose-preview"]
        let identity = preview.value as? String
        XCTAssertTrue(identity?.contains("preview=") == true)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            visible(preview, in: app); visible(app.buttons["vision-pause"], in: app)
            XCTAssertEqual(preview.value as? String, identity)
            XCTAssertEqual(app.staticTexts["vision-count"].label, "2")
            snapshot(app, "adaptive-vision-\(orientation.rawValue)")
        }
        tap(app.buttons["vision-pause"], in: app)
        tap(app.buttons["vision-finish"], in: app)
        tap(app.buttons["vision-save-report"], in: app)
        tap(app.buttons["vision-options"], in: app)
        let report = app.staticTexts["vision-last-report"]
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        for _ in 0..<10 {
            if report.exists && !report.frame.isEmpty && form.frame.contains(report.frame) { break }
            form.swipeUp()
        }
        visible(report, in: app)
        XCTAssertEqual(report.label, "自动 2 · 确认 2")
    }
}
