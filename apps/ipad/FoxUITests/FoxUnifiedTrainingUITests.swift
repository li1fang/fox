import XCTest

final class FoxUnifiedTrainingUITests: XCTestCase {
    private func launch(_ fixture: String = "normal") -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": fixture]
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        return app
    }

    private func visible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertFalse(element.frame.isEmpty)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(element.frame))
        XCTAssertTrue(element.isHittable)
    }

    private func enter(_ app: XCUIApplication) {
        visible(app.buttons["home-try-training"], in: app)
        app.buttons["home-try-training"].tap()
        visible(app.buttons["begin-set"], in: app)
    }

    private func shot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "p1-\(name)"; image.lifetime = .keepAlways; add(image)
    }

    func testDirectTrialShowsPreviewWithoutStartingTimerOrCounting() {
        let app = launch(); enter(app)
        XCTAssertFalse(app.buttons["start-training"].exists)
        XCTAssertTrue(app.staticTexts["workout-tracking-status"].label.contains("视觉"))
        XCTAssertEqual(app.staticTexts["set-elapsed"].label, "00:00")
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "0")
        XCTAssertFalse(app.staticTexts["vision-countdown"].exists)
        visible(app.buttons["training-vision-toggle"], in: app)
        shot("trial-ready")
    }

    private func pairedModes(_ app: XCUIApplication, orientations: [UIDeviceOrientation]) {
        enter(app)
        let controls = ["begin-set", "skip-set", "training-vision-toggle", "phone-training-details", "guidance-quick-mute"]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation != .portrait
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return !frame.isEmpty && (landscape ? frame.width > frame.height : frame.height > frame.width)
            }, object: nil)], timeout: 8), .completed)
            var frames: [String: CGRect] = [:]
            for id in controls { visible(app.buttons[id], in: app); frames[id] = app.buttons[id].frame }
            let stage = app.otherElements["training-stage-surface"].frame
            let square = app.otherElements["training-square-region"].frame
            XCTAssertGreaterThan(stage.width, 100); XCTAssertGreaterThan(square.width, 40)
            shot("visual-\(orientation.rawValue)")
            app.buttons["training-vision-toggle"].tap()
            XCTAssertTrue(app.staticTexts["workout-tracking-status"].label.contains("人工"))
            for id in controls {
                visible(app.buttons[id], in: app)
                XCTAssertEqual(app.buttons.matching(identifier: id).count, 1)
                XCTAssertEqual(app.buttons[id].frame, frames[id])
            }
            XCTAssertEqual(app.otherElements["training-stage-surface"].frame, stage)
            XCTAssertEqual(app.otherElements["training-square-region"].frame, square)
            XCTAssertTrue(app.staticTexts["tempo-phase"].exists)
            shot("manual-\(orientation.rawValue)")
            app.buttons["training-vision-toggle"].tap()
        }
    }

    func testPhoneModesKeepControlsAndStageGeometryAcrossRotation() {
        pairedModes(launch(), orientations: [.portrait, .landscapeLeft, .landscapeRight])
    }

    func testPadModesKeepControlsAndStageGeometryAcrossRotation() {
        pairedModes(launch(), orientations: [.portrait, .landscapeLeft])
    }

    func testDeniedCameraCanCompleteConfirmAndReopenTrial() {
        let app = launch("denied"); enter(app)
        XCTAssertTrue(app.staticTexts["workout-tracking-status"].label.contains("人工"))
        app.buttons["begin-set"].tap()
        visible(app.buttons["pause-set"], in: app)
        app.buttons["pause-set"].tap()
        XCTAssertTrue(app.staticTexts["workout-tracking-status"].label.contains("已暂停"))
        XCTAssertFalse(app.buttons["training-vision-toggle"].isEnabled)
        XCTAssertEqual(app.buttons["training-vision-toggle"].label, "开启视觉")
        app.buttons["begin-set"].tap()
        visible(app.buttons["pause-set"], in: app)
        XCTAssertTrue(app.staticTexts["workout-tracking-status"].label.contains("人工"))
        XCTAssertFalse(app.staticTexts["vision-countdown"].exists)
        app.buttons["complete-set"].tap()
        app.buttons["actual-left-reps-plus"].tap()
        app.buttons["submit-feedback"].tap()
        app.buttons["confirm-summary"].tap()
        visible(app.staticTexts["training-saved-receipt"], in: app)
        app.terminate(); app.launchArguments = []; app.launch()
        visible(app.buttons["home-training"], in: app)
        app.buttons["home-training"].tap()
        XCTAssertTrue(app.staticTexts["我的哑铃训练"].waitForExistence(timeout: 5), "Trial must preserve the original plan")
        app.buttons["记录"].tap()
        visible(app.buttons["record-confirmed"], in: app)
    }
}
