import Foundation
import XCTest

final class FoxClientFoundationUITests: XCTestCase {
    private func launch(serviceCards: Bool = false, failSwitch: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        // The existing denied fixture bypasses the real camera and exercises the manual path.
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": "denied"]
        if serviceCards { app.launchEnvironment["FOX_UI_SERVICE_CARDS"] = "foundation" }
        if failSwitch { app.launchEnvironment["FOX_UI_FAIL_SWITCH_ONCE"] = "1" }
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["home-prepare-curl"].waitForExistence(timeout: 10))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        func visible() -> Bool {
            element.exists && element.isHittable && !element.frame.isEmpty &&
                app.windows.firstMatch.frame.intersection(element.frame).height >= min(40, element.frame.height)
        }
        for _ in 0..<10 { if visible() { break }; app.swipeUp() }
        for _ in 0..<18 { if visible() { break }; app.swipeDown() }
        XCTAssertTrue(visible(), "Expected visible target: \(element.identifier)", file: file, line: line)
    }
    private func tap(_ id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.buttons[id]
        XCTAssertTrue(element.waitForExistence(timeout: 5), id, file: file, line: line)
        reveal(element, in: app, file: file, line: line)
        element.tap()
    }
    private func tapHomeCard(_ id: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.buttons[id], scroll = app.scrollViews.firstMatch, bar = app.navigationBars["Fox"]
        XCTAssertTrue(element.waitForExistence(timeout: 5), id, file: file, line: line)
        XCTAssertTrue(scroll.exists && bar.exists, "Home content required", file: file, line: line)
        func viewport() -> CGRect {
            let bounds = app.windows.firstMatch.frame.intersection(scroll.frame)
            let top = max(bounds.minY, bar.frame.maxY)
            return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
        }
        func visible() -> Bool {
            element.exists && element.isEnabled && element.isHittable && !element.frame.isEmpty && viewport().contains(element.frame)
        }
        // Home scrolls beneath its navigation bar. A window intersection can
        // accept a covered label, so reveal it inside the actual content area.
        for _ in 0..<18 {
            if visible() { break }
            let bounds = viewport(), distance = min(100, bounds.height * 0.25)
            let down = element.frame.midY < bounds.midY
            let startY = bounds.midY + (down ? -distance / 2 : distance / 2)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: bounds.minX + min(40, bounds.width * 0.15), dy: startY))
            let end = origin.withOffset(CGVector(dx: bounds.minX + min(40, bounds.width * 0.15), dy: startY + (down ? distance : -distance)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        let ready = visible()
        if !ready { print("FOX_HOME_CARD_TARGET_NOT_READY \(id)\n\(app.debugDescription)") }
        XCTAssertTrue(ready, id, file: file, line: line)
        element.tap()
    }
    private func ids(_ prefix: String, in app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).allElementsBoundByIndex.map(\.identifier)
    }
    private func waitCount(_ prefix: String, _ count: Int, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let matching = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in matching.count == count }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, prefix, file: file, line: line)
    }
    private func sessionID(_ selector: String, prefix: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        let value = String(selector.dropFirst(prefix.count))
        XCTAssertNotNil(UUID(uuidString: value), "A route must carry a stable session UUID", file: file, line: line)
        return value
    }
    private func home(_ app: XCUIApplication) {
        tap("training-home", in: app)
        XCTAssertTrue(app.buttons["home-history"].waitForExistence(timeout: 5))
    }
    private func prepareKegel(_ app: XCUIApplication) {
        tap("home-capabilities", in: app)
        XCTAssertTrue(app.navigationBars["训练动作"].waitForExistence(timeout: 5))
        tap("home-try-kegel", in: app)
        XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["training-activity-picker"].label.contains("凯格尔"))
    }
    private func assertPreparation(_ app: XCUIApplication, activity: String) {
        XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["begin-set"].label.contains("开始本组"))
        XCTAssertTrue(app.buttons["training-activity-picker"].label.contains(activity))
        XCTAssertEqual(app.staticTexts["set-elapsed"].label, "00:00")
        XCTAssertFalse(app.buttons["pause-set"].exists)
    }

    func testDismissedSwitchErrorKeepsVisibleRetryAndCreatesOnlyOnePreparation() {
        let app = launch(failSwitch: true)
        tap("home-prepare-curl", in: app)
        XCTAssertTrue(app.alerts["操作未完成"].waitForExistence(timeout: 5))
        app.alerts["操作未完成"].buttons["知道了"].tap()
        XCTAssertTrue(app.buttons["training-retry-switch"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["begin-set"].exists)
        tap("training-retry-switch", in: app)
        assertPreparation(app, activity: "弯举")
        home(app)
        waitCount("home-preparation-", 1, in: app)
        XCTAssertTrue(ids("home-resume-", in: app).isEmpty)
    }

    func testPreparationsSurviveRelaunchRemainDistinctAndHistoryIsReadOnly() {
        let app = launch()
        tap("home-prepare-curl", in: app); assertPreparation(app, activity: "弯举"); home(app)
        waitCount("home-preparation-", 1, in: app)
        let a = ids("home-preparation-", in: app)[0]
        let aID = sessionID(a, prefix: "home-preparation-")
        XCTAssertTrue(ids("home-resume-", in: app).isEmpty)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons[a].waitForExistence(timeout: 10))
        XCTAssertTrue(ids("home-resume-", in: app).isEmpty, "Opening preparation is not actual training start")
        prepareKegel(app); assertPreparation(app, activity: "凯格尔"); home(app)
        waitCount("home-preparation-", 2, in: app)
        let both = Set(ids("home-preparation-", in: app))
        XCTAssertEqual(both.count, 2, "Each preparation must expose a distinct ID")
        XCTAssertTrue(both.contains(a))
        guard let b = both.subtracting([a]).first else { XCTFail("The second preparation is missing"); return }
        let bID = sessionID(b, prefix: "home-preparation-")
        XCTAssertNotEqual(aID, bID)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons[a].waitForExistence(timeout: 10))
        waitCount("home-preparation-", 2, in: app)
        XCTAssertEqual(Set(ids("home-preparation-", in: app)), both)
        XCTAssertTrue(ids("home-resume-", in: app).isEmpty)
        tap(a, in: app); assertPreparation(app, activity: "弯举"); home(app)
        waitCount("home-preparation-", 2, in: app)
        XCTAssertEqual(Set(ids("home-preparation-", in: app)), both)
        tap("home-history", in: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home-history-list").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-history-\(aID)"].exists)
        XCTAssertTrue(app.buttons["home-history-\(bID)"].exists)
        tap("home-history-\(aID)", in: app)
        XCTAssertTrue(app.staticTexts["本机档案 · 只读"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["begin-set"].exists)
        app.navigationBars["训练档案"].buttons["完成"].tap()
        app.navigationBars["训练记录"].buttons["完成"].tap()
        waitCount("home-preparation-", 2, in: app)
        XCTAssertEqual(Set(ids("home-preparation-", in: app)), both)
        XCTAssertTrue(ids("home-resume-", in: app).isEmpty)
    }

    func testStartedSessionResumesExactPausedTargetAndKeepsItsFeedbackDraft() {
        let app = launch()
        tap("home-prepare-curl", in: app)
        XCTAssertTrue(app.staticTexts["workout-tracking-status"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["workout-tracking-status"].label.contains("人工"))
        tap("begin-set", in: app)
        XCTAssertTrue(app.buttons["pause-set"].waitForExistence(timeout: 5)); home(app)
        waitCount("home-resume-", 1, in: app)
        let a = ids("home-resume-", in: app)[0], aID = sessionID(a, prefix: "home-resume-")
        prepareKegel(app); home(app)
        waitCount("home-preparation-", 1, in: app)
        let b = ids("home-preparation-", in: app)[0]
        tap(a, in: app)
        XCTAssertEqual(app.staticTexts["workout-tracking-status"].label, "已暂停")
        XCTAssertTrue(app.buttons["training-activity-picker"].label.contains("弯举"))
        XCTAssertTrue(app.buttons["begin-set"].label.contains("继续本组"))
        XCTAssertFalse(app.buttons["pause-set"].exists)
        let pausedElapsed = app.staticTexts["set-elapsed"].label
        home(app); tap(b, in: app); assertPreparation(app, activity: "凯格尔"); home(app); tap(a, in: app)
        XCTAssertEqual(app.staticTexts["set-elapsed"].label, pausedElapsed, "Time away from A must not accumulate")
        tap("begin-set", in: app); tap("complete-set", in: app)
        XCTAssertTrue(app.textFields["actual-left-reps"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["submit-feedback"].isEnabled, "No observed or entered count exists yet")
        tap("actual-left-reps-plus", in: app); tap("actual-left-reps-plus", in: app)
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "2")
        home(app)
        let review = "home-review-\(aID)"
        XCTAssertTrue(app.buttons[review].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[a].exists)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons[review].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[b].exists)
        tap(b, in: app); assertPreparation(app, activity: "凯格尔"); home(app); tap(review, in: app)
        XCTAssertTrue(app.textFields["actual-left-reps"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "2")
        XCTAssertTrue(app.buttons["submit-feedback"].isEnabled)
        XCTAssertFalse(app.buttons["begin-set"].exists, "Review must not start a new attempt")
    }

    func testSyntheticQuestionReceiptsAndConcreteKegelSuggestionStayIndependent() {
        let app = launch(serviceCards: true)
        let synthetic = app.staticTexts["home-service-synthetic"]
        XCTAssertTrue(synthetic.waitForExistence(timeout: 5))
        let accepted = app.staticTexts.matching(NSPredicate(format: "label == %@", "已接收"))
        XCTAssertEqual(accepted.count, 0, "Silence is not an answer")
        XCTAssertFalse(app.buttons["home-try-kegel"].exists, "The capability chooser has not been opened")
        tapHomeCard("home-card-foundation-skip-action-skip", in: app)
        let skipped = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in accepted.count == 1 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [skipped], timeout: 5), .completed)
        tapHomeCard("home-card-foundation-answer-choice-begin", in: app)
        tapHomeCard("只看文字", in: app)
        tapHomeCard("home-card-foundation-answer-choice-done", in: app)
        tapHomeCard("home-card-foundation-answer-action-answer", in: app)
        let answered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in accepted.count == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [answered], timeout: 5), .completed)
        let expired = app.buttons["home-card-foundation-expired-action-prepare"]
        reveal(expired, in: app); XCTAssertFalse(expired.isEnabled)
        tapHomeCard("home-card-foundation-kegel-action-prepare", in: app)
        assertPreparation(app, activity: "凯格尔")
        XCTAssertFalse(app.buttons["training-vision-toggle"].isEnabled)
        XCTAssertFalse(app.buttons["rebind-vision-set"].isEnabled)
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "—")
        XCTAssertFalse(app.staticTexts["vision-countdown"].exists)
        home(app); waitCount("home-preparation-", 1, in: app)
        let original = ids("home-preparation-", in: app)[0]
        tap("home-prepare-curl", in: app); assertPreparation(app, activity: "弯举"); home(app)
        waitCount("home-preparation-", 2, in: app)
        tapHomeCard("home-card-foundation-kegel-action-prepare", in: app)
        assertPreparation(app, activity: "凯格尔"); home(app)
        waitCount("home-preparation-", 2, in: app)
        XCTAssertTrue(app.buttons[original].exists, "Reusing the same suggestion must select its original preparation")
        XCTAssertEqual(accepted.count, 2, "A local training action must not claim a service acceptance receipt")
    }
}
