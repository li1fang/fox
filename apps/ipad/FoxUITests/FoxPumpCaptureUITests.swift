import XCTest

final class FoxPumpCaptureUITests: XCTestCase {
    private func wait(_ predicate: @escaping () -> Bool) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)], timeout: 15), .completed)
    }
    private func launch() -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_FREE_CAPTURE_FIXTURE": "no_people", "FOX_PUMP_FIXTURE": "connected"]
        app.launchArguments = ["--ui-testing-reset"]; app.launch()
        let entry = app.buttons["home-capture-lab"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        let toggle = app.switches["free-capture-pump"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); toggle.tap()
        app.buttons["free-capture-select-pump"].tap()
        app.buttons["free-capture-pump-device-00000000-0000-0000-0000-000000000001"].tap()
        app.buttons["free-capture-pump-device-00000000-0000-0000-0000-000000000002"].tap()
        app.navigationBars["选择 PUMP"].buttons["完成"].tap()
        wait { app.buttons["pump-apply-pair"].isEnabled }
        return app
    }
    private func show(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 { if element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ name: String, app: XCUIApplication) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-hierarchy"; tree.lifetime = .keepAlways; add(tree)
    }
    func testMaximumAndAllModeDraftsDoNotSendUntilConfirmed() {
        let app = launch()
        for name in ["标准", "恒力", "离心", "向心"] {
            app.segmentedControls["pump-mode"].buttons[name].tap()
            app.buttons["pump-maximum"].tap()
            XCTAssertEqual(app.textFields["pump-kg"].value as? String, "20.0")
            XCTAssertFalse(app.staticTexts["pump-result-A"].exists)
        }
        let apply = app.buttons["pump-apply-pair"]; show(apply, in: app); apply.tap()
        XCTAssertTrue(app.buttons["pump-confirm-send"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["pump-confirm-parameters"].label.contains("20"))
        app.buttons["取消"].tap()
        XCTAssertFalse(app.staticTexts["pump-result-A"].exists)
        apply.tap(); app.buttons["pump-confirm-send"].tap()
        wait { app.staticTexts["pump-result-A"].exists && app.staticTexts["pump-result-B"].exists }
        XCTAssertTrue(app.staticTexts["pump-result-A"].label.contains("写入有回执"))
    }
    func testTypedWeightReachesTheSameConfirmationWithoutStepperClicks() {
        let app = launch(), field = app.textFields["pump-kg"]
        show(field, in: app); field.tap()
        let current = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + "7.5")
        app.buttons["pump-keyboard-done"].tap()
        let apply = app.buttons["pump-apply-pair"]; show(apply, in: app); apply.tap()
        XCTAssertTrue(app.staticTexts["pump-confirm-parameters"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["pump-confirm-parameters"].label.contains("7.5"))
        app.buttons["取消"].tap(); XCTAssertFalse(app.staticTexts["pump-result-A"].exists)
    }
    func testConfigureRecordStopAndConfigureAgainPreservesOneSavedExperiment() {
        let app = launch()
        let apply = app.buttons["pump-apply-pair"]; show(apply, in: app); apply.tap()
        app.buttons["pump-confirm-send"].tap()
        capture("after-standard-confirmation", app: app)
        wait { app.staticTexts["pump-result-B"].exists }
        let start = app.buttons["free-capture-start"]; show(start, in: app); start.tap()
        wait { app.staticTexts["free-capture-status"].label == "录像中" }
        XCTAssertFalse(app.buttons["pump-apply-pair"].isEnabled)
        XCTAssertTrue(app.buttons["free-capture-stop"].isEnabled)
        app.buttons["free-capture-stop"].tap()
        wait { app.staticTexts["free-capture-status"].label == "已保存实验原件" }
        show(apply, in: app); wait { apply.isEnabled }
        apply.tap(); app.buttons["pump-confirm-send"].tap()
        wait { app.staticTexts["pump-result-B"].exists }
        let library = app.buttons["free-capture-library"]; show(library, in: app); library.tap()
        let packages = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "free-capture-package-"))
        wait { packages.count == 1 }
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["home-capture-lab"].tap(); show(app.buttons["free-capture-library"], in: app)
        app.buttons["free-capture-library"].tap(); wait { packages.count == 1 }
    }
}
