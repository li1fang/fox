import XCTest

final class FoxActivityEntryUITests: XCTestCase {
    private func launch(fixture: String = "no_person") -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": fixture]
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        return app
    }

    func testFourActionsAreDirectlyDiscoverableOnHome() {
        let app = launch()
        for id in ["home-try-training", "home-try-lateralRaise", "home-try-latPulldown", "home-try-kegel"] {
            let button = app.buttons[id]
            XCTAssertTrue(button.waitForExistence(timeout: 5), id)
            if !button.isHittable { app.swipeUp() }
            XCTAssertTrue(button.isHittable, id)
        }
        shot("home-four-actions")
    }

    func testQueuedActivityDoesNotHidePreparationOrRecoveryGuidance() {
        for fixture in ["no_person", "subject_loss"] {
            let app = launch(fixture: fixture)
            app.buttons["home-try-training"].tap(); app.buttons["begin-set"].tap()
            if fixture == "subject_loss" {
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    app.buttons["rebind-vision-set"].isEnabled
                }, object: nil)], timeout: 20), .completed)
            }
            visible(app.buttons["training-manual-continue"], in: app)
            let detail = app.staticTexts["workout-task-detail"].label
            let count = app.staticTexts["workout-automatic-count"].label
            app.buttons["training-activity-picker"].tap(); app.buttons["choose-activity-kegel"].tap()
            XCTAssertEqual(app.staticTexts["workout-task-detail"].label, detail)
            XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, count)
            visible(app.buttons["training-manual-continue"], in: app)
            app.buttons["training-activity-picker"].tap()
            XCTAssertEqual(app.staticTexts["activity-next"].label, "下一动作：凯格尔运动")
            app.terminate()
        }
    }

    func testOptionalObservationCorrectionIsSecondaryAndKeepsExplicitSide() {
        let app = launch(); app.buttons["home-try-training"].tap()
        choose("lateralRaise", in: app)
        app.buttons["phone-training-details"].tap()
        XCTAssertFalse(app.buttons["training-other-arm"].exists)
        app.buttons["training-diagnostics"].tap()
        // DisclosureGroup propagates its identifier to child buttons on this runtime.
        let correction = app.buttons.matching(NSPredicate(format: "label == %@", "改为观察右侧")).firstMatch
        if !correction.isHittable { app.swipeUp() }
        visible(correction, in: app); correction.tap()
        app.buttons["phone-training-details-done"].tap()
        XCTAssertTrue(app.staticTexts["phone-target-reps"].label.contains("右臂"))
        app.buttons["training-vision-toggle"].tap()
        app.buttons["begin-set"].tap(); app.buttons["complete-set"].tap()
        XCTAssertFalse(app.textFields["actual-left-reps"].exists)
        XCTAssertTrue(app.textFields["actual-right-reps"].exists)
    }

    private func visible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertTrue(element.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(element.frame))
    }

    private func choose(_ name: String, in app: XCUIApplication) {
        app.buttons["training-activity-picker"].tap()
        let choice = app.buttons["choose-activity-\(name)"]
        visible(choice, in: app); choice.tap()
        XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 5) || app.buttons["complete-set"].exists)
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "activities-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testKegelSharesLayoutAndSavesManualRecordWithoutCameraAcrossRotation() {
        let app = launch()
        app.buttons["home-try-training"].tap()
        choose("kegel", in: app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let f = app.windows.firstMatch.frame
                return orientation == .portrait ? f.height > f.width : f.width > f.height
            }, object: nil)], timeout: 8), .completed)
            for id in ["training-activity-picker", "begin-set", "phone-training-details", "guidance-quick-mute"] {
                visible(app.buttons[id], in: app)
            }
            XCTAssertFalse(app.buttons["training-vision-toggle"].isEnabled)
            XCTAssertFalse(app.buttons["rebind-vision-set"].isEnabled)
            XCTAssertFalse(app.staticTexts["vision-countdown"].exists)
            XCTAssertTrue(app.staticTexts["tempo-phase"].exists)
            XCTAssertGreaterThan(app.otherElements["training-stage-surface"].frame.height, 80)
            shot("kegel-\(orientation.rawValue)")
        }
        app.buttons["phone-training-details"].tap()
        XCTAssertFalse(app.buttons["training-other-arm"].exists)
        XCTAssertFalse(app.otherElements["training-diagnostics"].exists)
        app.buttons["phone-training-details-done"].tap()
        app.buttons["begin-set"].tap()
        visible(app.buttons["pause-set"], in: app)
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "—")
        app.buttons["pause-set"].tap()
        XCTAssertEqual(app.staticTexts["tempo-phase"].label, "节奏已暂停")
        app.buttons["begin-set"].tap(); app.buttons["complete-set"].tap()
        XCTAssertFalse(app.buttons["submit-feedback"].isEnabled)
        app.buttons["actual-reps-plus"].tap()
        app.buttons["submit-feedback"].tap(); app.buttons["confirm-summary"].tap()
        visible(app.staticTexts["training-saved-receipt"], in: app)
        app.terminate(); app.launchArguments = []; app.launch()
        app.buttons["home-training"].tap(); app.buttons["记录"].tap()
        XCTAssertTrue(app.buttons["record-confirmed"].waitForExistence(timeout: 5))
    }

    func testSwitchDuringActiveSetWaitsForSaveAndCurlCanContinueOnRight() {
        let app = launch(); app.buttons["home-try-training"].tap()
        app.buttons["training-vision-toggle"].tap()
        app.buttons["begin-set"].tap()
        choose("kegel", in: app)
        XCTAssertTrue(app.buttons["training-activity-picker"].label.contains("哑铃弯举"))
        app.buttons["complete-set"].tap()
        XCTAssertFalse(app.textFields["actual-right-reps"].exists)
        for _ in 0..<5 { app.buttons["actual-left-reps-plus"].tap() }
        app.buttons["submit-feedback"].tap()
        XCTAssertTrue(app.buttons["confirm-summary"].label.contains("凯格尔"))
        app.buttons["confirm-summary"].tap()
        XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["training-activity-picker"].label.contains("凯格尔"))
        choose("curl", in: app)
        app.buttons["training-vision-toggle"].tap()
        app.buttons["begin-set"].tap(); app.buttons["complete-set"].tap()
        app.buttons["actual-left-reps-plus"].tap(); app.buttons["submit-feedback"].tap()
        app.buttons["save-and-switch-arm"].tap()
        XCTAssertTrue(app.staticTexts["phone-target-reps"].label.contains("右臂"))
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "0")
        app.buttons["training-vision-toggle"].tap()
        app.buttons["begin-set"].tap(); app.buttons["complete-set"].tap()
        XCTAssertFalse(app.textFields["actual-left-reps"].exists)
        visible(app.buttons["actual-right-reps-plus"], in: app)
        app.buttons["actual-right-reps-plus"].tap(); app.buttons["submit-feedback"].tap()
        app.buttons["confirm-summary"].tap()
        visible(app.staticTexts["training-saved-receipt"], in: app)
    }
}
