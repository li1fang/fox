import XCTest

final class FoxUnifiedTrainingUITests: XCTestCase {
    private func launch(_ fixture: String = "normal", category: String? = nil) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": fixture]
        app.launchArguments = ["--ui-testing-reset"]
        if let category { app.launchArguments += ["-UIPreferredContentSizeCategoryName", category] }
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
        visible(app.buttons["home-prepare-curl"], in: app)
        app.buttons["home-prepare-curl"].tap()
        visible(app.buttons["begin-set"], in: app)
    }

    private func shot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "p1-\(name)"; image.lifetime = .keepAlways; add(image)
    }

    func testWaitingPreparationOffersManualContinuationWithoutInventedCount() {
        let app = launch("no_person"); enter(app)
        app.buttons["begin-set"].tap()
        visible(app.buttons["training-manual-continue"], in: app)
        XCTAssertEqual(app.buttons["training-manual-continue"].label, "人工记录")
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "0")
        shot("waiting-manual-choice")
        app.buttons["training-manual-continue"].tap()
        visible(app.buttons["complete-set"], in: app)
        XCTAssertTrue(app.staticTexts["tempo-phase"].exists)
        XCTAssertFalse(app.buttons["training-manual-continue"].exists)
        app.buttons["complete-set"].tap()
        let count = app.textFields["actual-left-reps"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        let displayedValue = count.value as? String
        XCTAssertTrue(displayedValue == "" || displayedValue == count.placeholderValue,
                      "An unobserved count must stay blank, not become zero or the target")
        XCTAssertFalse(app.buttons["submit-feedback"].isEnabled)
    }

    func testLostObservationOffersManualContinuationAndPreservesObservedFacts() {
        let app = launch("subject_loss"); enter(app)
        app.buttons["begin-set"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["rebind-vision-set"].isEnabled
        }, object: nil)], timeout: 20), .completed)
        XCTAssertTrue(app.buttons["training-manual-continue"].waitForExistence(timeout: 20))
        visible(app.buttons["training-manual-continue"], in: app)
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "1")
        shot("lost-manual-choice")
        app.buttons["training-manual-continue"].tap()
        visible(app.buttons["pause-set"], in: app)
        XCTAssertTrue(app.staticTexts["tempo-phase"].exists)
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "1")
        app.buttons["pause-set"].tap()
        app.buttons["begin-set"].tap()
        app.buttons["complete-set"].tap()
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "1")
        XCTAssertTrue(app.staticTexts["观测 左臂 1 次，待你确认"].exists)
        app.buttons["submit-feedback"].tap()
        app.buttons["confirm-summary"].tap()
        visible(app.staticTexts["training-saved-receipt"], in: app)
    }

    func testAccessibleTextScalesConfirmationAndKeepsJourneyReachable() {
        let normal = launch("denied", category: "UICTContentSizeCategoryL"); enter(normal)
        let normalActionHeight = normal.buttons["begin-set"].frame.height
        normal.buttons["begin-set"].tap(); normal.buttons["complete-set"].tap()
        visible(normal.textFields["actual-left-reps"], in: normal)
        let normalCountHeight = normal.textFields["actual-left-reps"].frame.height
        let normalHeadingHeight = normal.staticTexts["确认本组"].frame.height
        normal.terminate()

        let app = launch("denied", category: "UICTContentSizeCategoryAccessibilityXL"); enter(app)
        visible(app.buttons["begin-set"], in: app)
        XCTAssertGreaterThan(app.buttons["begin-set"].frame.height, normalActionHeight)
        app.buttons["begin-set"].tap(); app.buttons["pause-set"].tap()
        app.terminate(); app.launchArguments.removeAll(where: { $0 == "--ui-testing-reset" }); app.launch()
        app.resumeOnlyStartedTraining()
        visible(app.buttons["begin-set"], in: app)
        app.buttons["begin-set"].tap(); app.buttons["complete-set"].tap()
        visible(app.textFields["actual-left-reps"], in: app)
        XCTAssertGreaterThan(app.textFields["actual-left-reps"].frame.height, normalCountHeight * 1.2)
        XCTAssertGreaterThan(app.staticTexts["确认本组"].frame.height, normalHeadingHeight * 1.2)
        XCTAssertEqual(app.textFields["actual-left-reps"].label, "左臂次数")
        visible(app.buttons["actual-left-reps-plus"], in: app)
        app.buttons["actual-left-reps-plus"].tap()
        visible(app.buttons["submit-feedback"], in: app)
        shot("accessible-confirmation")
        app.buttons["submit-feedback"].tap()
        visible(app.buttons["confirm-summary"], in: app)
        shot("accessible-summary")
        app.buttons["confirm-summary"].tap()
        visible(app.staticTexts["training-saved-receipt"], in: app)
        app.buttons["view-saved-training"].tap()
        XCTAssertTrue(app.otherElements["record-detail"].waitForExistence(timeout: 5) || app.scrollViews["record-detail"].exists)
        shot("accessible-saved-record")
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

    func testManualContinuationRemainsReachableInLandscapePreparationAndLoss() {
        for fixture in ["no_person", "subject_loss"] {
            let app = launch(fixture); enter(app)
            app.buttons["begin-set"].tap()
            if fixture == "subject_loss" {
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"), object: app.buttons["rebind-vision-set"])], timeout: 20), .completed)
            }
            for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
                XCUIDevice.shared.orientation = orientation
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    return !frame.isEmpty && frame.width > frame.height
                }, object: nil)], timeout: 8), .completed)
                let manual = app.buttons["training-manual-continue"]
                visible(manual, in: app)
                XCTAssertLessThanOrEqual(manual.frame.maxY, app.otherElements["training-actions"].frame.minY)
                shot("manual-\(fixture)-landscape-\(orientation.rawValue)")
            }
            app.buttons["training-manual-continue"].tap()
            visible(app.buttons["complete-set"], in: app)
            XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, fixture == "subject_loss" ? "1" : "0")
            XCTAssertTrue(app.staticTexts["tempo-phase"].exists)
            app.terminate()
        }
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
        let plan = app.buttons["home-training-projection-plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        for _ in 0..<6 { if plan.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(plan.isHittable); plan.tap()
        XCTAssertTrue(app.staticTexts["我的哑铃训练"].waitForExistence(timeout: 5), "Trial must preserve the original plan")
        app.navigationBars["训练档案"].buttons["完成"].tap()
        let history = app.openReadOnlyTrainingHistory()
        XCTAssertEqual(history.count, 1)
        visible(history.firstMatch, in: app)
        XCTAssertTrue(history.firstMatch.label.contains("已确认训练回顾"))
    }
}
