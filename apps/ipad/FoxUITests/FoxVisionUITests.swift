import XCTest

final class FoxVisionUITests: XCTestCase {
    func testGuidanceOverlayAndMuteRemainAvailableAcrossRotation() {
        continueAfterFailure = false
        let app = launch("normal", orientation: .portrait)
        if phone { options(app, showing: "guidance-overlay-toggle") }
        else { app.buttons["guidance-options"].tap() }
        let overlaySwitch = app.switches["guidance-overlay-toggle"]
        XCTAssertTrue(overlaySwitch.waitForExistence(timeout: 5))
        if overlaySwitch.value as? String == "0" { overlaySwitch.tap() }
        if phone { reveal("guidance-mode", app: app) }
        app.segmentedControls["guidance-mode"].buttons["观察跟随"].tap()
        if phone { closeOptions(app) } else { app.buttons["guidance-options-done"].tap() }
        begin(app)
        let overlay = app.descendants(matching: .any).matching(identifier: "guidance-camera-overlay").firstMatch
        XCTAssertTrue(overlay.waitForExistence(timeout: 10))
        let mute = app.buttons["guidance-quick-mute"]
        XCTAssertTrue(mute.isHittable)
        let label = mute.label
        mute.tap()
        XCTAssertNotEqual(mute.label, label)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "guidance-portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed, "A landscape filename is not rotation evidence")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["vision-finish"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(mute.isHittable)
        XCTAssertTrue(app.frame.contains(mute.frame))
        XCTAssertTrue(app.frame.contains(app.buttons["vision-finish"].frame))
        XCTAssertTrue(overlay.exists)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "guidance-landscape"; landscape.lifetime = .keepAlways; add(landscape)
    }

    func testPulldownUpperBodyPreparationPeakCountingAndReport() {
        continueAfterFailure = false
        let app = launch("normal", orientation: .portrait)
        options(app)
        app.segmentedControls["vision-exercise"].buttons["高位下拉"].tap()
        closeOptions(app)
        begin(app)
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 15), .completed)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "M3-pulldown-two-peaks"; shot.lifetime = .keepAlways; add(shot)
        finish(app)
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-report"].label, "自动 2 · 确认 2")
    }

    func testBatchRouteStartsAndReportsMissingInput() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FOX_POSE_BATCH_JOB"] = UUID().uuidString
        app.launch()
        let status = app.staticTexts["batch-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '失败'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["batch-cancel"].exists)
    }

    private var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private func reveal(_ id: String, app: XCUIApplication) {
        // Form rows are virtualized inside iPad sheets as well as phone pages.
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let item = app.descendants(matching: .any).matching(identifier: id).firstMatch
        func visible() -> Bool {
            guard item.exists else { return false }
            let frame = item.frame, bounds = app.windows.firstMatch.frame.intersection(list.frame)
            return frame.width > 0 && frame.height > 0 && bounds.contains(frame) && (!item.isEnabled || item.isHittable)
        }
        for _ in 0..<30 {
            if visible() { break }
            let upward = !item.exists || item.frame.minY >= list.frame.minY
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: upward ? 0.82 : 0.3))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: upward ? 0.3 : 0.82))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        if !visible() {
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "missing-option-\(id)"; state.lifetime = .keepAlways; add(state)
        }
        XCTAssertTrue(visible(), id)
    }
    private func options(_ app: XCUIApplication, showing id: String? = nil) {
        guard phone else { return }
        if !app.buttons["vision-options-done"].exists { app.buttons["vision-options"].tap() }
        XCTAssertTrue(app.buttons["vision-options-done"].waitForExistence(timeout: 5))
        if let id { reveal(id, app: app) }
    }
    private func closeOptions(_ app: XCUIApplication) {
        if phone && app.buttons["vision-options-done"].exists {
            app.buttons["vision-options-done"].tap()
            let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["vision-options"])
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        }
    }
    private func finish(_ app: XCUIApplication) {
        app.buttons["vision-finish"].tap()
        reveal("vision-reference-count", app: app)
    }
    private func begin(_ app: XCUIApplication) {
        let button = app.buttons["vision-start"]
        if phone {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        }
        button.tap()
    }
    private func requireTwoCounts(_ app: XCUIApplication, stage: String, file: StaticString = #filePath, line: UInt = #line) {
        let started = ProcessInfo.processInfo.systemUptime
        var observations: [[String: Any]] = [], afterFailure: [[String: Any]] = []
        func observe() -> [String: Any] {
            let queryStarted = ProcessInfo.processInfo.systemUptime
            let label = app.staticTexts["vision-count"].label
            let now = ProcessInfo.processInfo.systemUptime
            return ["label": label, "elapsedSeconds": now - started, "querySeconds": now - queryStarted]
        }
        let predicate = NSPredicate { _, _ in
            let observation = observe(); observations.append(observation)
            return observation["label"] as? String == "2"
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 12)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let synthetic = app.launchEnvironment["FOX_UI_TESTING"] == "1"
            && app.launchEnvironment["FOX_POSE_FIXTURE"] == "normal"
            && ProcessInfo.processInfo.environment["FOX_PRIVATE_INPUT_MANIFEST", default: ""].isEmpty
        if synthetic {
            if result != .completed {
                print("FOX_SYNTHETIC_COUNT_FAILURE_AX\n\(app.debugDescription)")
                // Read-only diagnosis after failure never changes the original twelve-second verdict.
                let later = NSPredicate { _, _ in
                    let observation = observe(); afterFailure.append(observation)
                    return observation["label"] as? String == "2"
                }
                _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: later, object: nil)], timeout: 8)
            }
            let diagnostic: [String: Any] = ["schema": "fox.ui_count_probe.v1", "stage": stage, "expected": "2",
                "completed": result == .completed, "deadlineSeconds": 12, "elapsedSeconds": elapsed,
                "observations": observations, "afterFailure": afterFailure]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print("FOX_UI_COUNT \(json)") }
        }
        XCTAssertEqual(result, .completed, "Two counts required: \(stage)", file: file, line: line)
    }
    private func saveReport(_ app: XCUIApplication) {
        app.buttons["vision-save-report"].tap()
        if phone { options(app, showing: "vision-last-body-view") }
    }
    private func page(_ name: String, app: XCUIApplication) {
        closeOptions(app)
        if phone && app.buttons["training-page-menu"].exists { app.buttons["training-page-menu"].tap() }
        app.buttons[name].tap()
    }
    private func screenAngle(_ app: XCUIApplication) -> String {
        if phone {
            return app.descendants(matching: .any).matching(identifier: "vision-screen-angle").firstMatch.value as? String ?? ""
        }
        return app.staticTexts["vision-screen-angle"].label
    }
    func testFreshOppositeTorsoReferenceCountsWhenSelectedHipIsMissing() {
        continueAfterFailure = false
        let app = launch("same_hip_missing")
        options(app)
        app.segmentedControls["vision-exercise"].buttons["哑铃侧平举"].tap()
        closeOptions(app)
        begin(app)
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 15), .completed)
        finish(app)
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-report"].label, "自动 2 · 确认 2")
    }

    func testLostSubjectRebindPreservesCountOnIndependentVisionPage() {
        continueAfterFailure = false
        let app = launch("subject_loss")
        begin(app)
        let rebind = app.buttons["vision-rebind"]
        XCTAssertTrue(rebind.waitForExistence(timeout: 15))
        XCTAssertTrue(rebind.isHittable)
        XCTAssertTrue(app.frame.contains(rebind.frame))
        XCTAssertEqual(app.staticTexts["vision-count"].label, "1")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "subject-loss-rebind-control"; shot.lifetime = .keepAlways; add(shot)
        rebind.tap()
        XCTAssertTrue(app.buttons["vision-cancel-start"].waitForExistence(timeout: 3))
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.buttons["vision-finish"])
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 8), .completed)
        XCTAssertEqual(app.staticTexts["vision-count"].label, "1")
    }

    func testPreparationSurvivesWalkingBackWithoutRebindButton() {
        continueAfterFailure = false
        let app = launch("preparation_retreat", orientation: .portrait)
        begin(app)
        let cancel = app.buttons["vision-cancel-start"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["等待入镜"].waitForExistence(timeout: 5))
        XCTAssertTrue(cancel.isHittable)
        XCTAssertTrue(app.frame.contains(cancel.frame))
        XCTAssertFalse(app.buttons["vision-rebind"].exists)
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
        let waiting = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        waiting.name = "M1-walking-back-waits-with-cancel"; waiting.lifetime = .keepAlways; add(waiting)
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["vision-rebind"].exists)
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 10), .completed)
        let active = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        active.name = "M1-started-without-another-tap"; active.lifetime = .keepAlways; add(active)
        app.buttons["vision-pause"].tap()
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["vision-start"].label, "就位后继续")
    }

    func testParametersApplyPersistResetAndLockDuringTrial() {
        print("FOX_POSE_UI_GENERATION: reliability-v2-scrolling")
        continueAfterFailure = false
        let app = launch("normal")
        options(app, showing: "vision-parameters")
        let parameters = app.buttons["vision-parameters"]
        XCTAssertTrue(parameters.waitForExistence(timeout: 5))
        parameters.tap()
        XCTAssertTrue(app.buttons["pose-apply-parameters"].waitForExistence(timeout: 5))
        let grace = app.steppers["pose-grace"]
        XCTAssertEqual(grace.buttons.count, 2)
        grace.buttons.element(boundBy: 1).tap()
        app.buttons["pose-apply-parameters"].tap()
        app.terminate()
        app.launchArguments = []
        app.launch()
        options(app, showing: "vision-parameters")
        XCTAssertTrue(parameters.waitForExistence(timeout: 5))
        parameters.tap()
        XCTAssertTrue(app.steppers["pose-grace"].label.contains("0.35"))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "D1-reliability-parameters"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let reset = app.buttons["pose-reset-defaults"]
        reveal("pose-reset-defaults", app: app)
        for _ in 0..<8 {
            if reset.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(reset.exists)
        reset.tap()
        app.buttons["pose-apply-parameters"].tap()
        begin(app)
        options(app, showing: "vision-parameters")
        XCTAssertFalse(parameters.isEnabled)
        closeOptions(app)
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 8))
        options(app, showing: "vision-parameters")
        XCTAssertFalse(parameters.isEnabled)
        closeOptions(app)
        finish(app)
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
        if phone { closeOptions(app); options(app, showing: "vision-parameters") }
        XCTAssertTrue(parameters.isEnabled)
    }

    func testFlickerLateralRaiseCountsAndPersistsDiagnostics() {
        continueAfterFailure = false
        let app = launch("flicker")
        options(app)
        XCTAssertTrue(app.segmentedControls["vision-exercise"].waitForExistence(timeout: 5))
        app.segmentedControls["vision-exercise"].buttons["哑铃侧平举"].tap()
        closeOptions(app)
        begin(app)
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 15), .completed)
        app.buttons["vision-pause"].tap()
        options(app, showing: "vision-tracking-diagnostics")
        XCTAssertTrue(app.staticTexts["vision-tracking-diagnostics"].label.contains("恢复"))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "D1-reliability-flicker-lateral"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        closeOptions(app)
        finish(app)
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-report"].label, "自动 2 · 确认 2")
    }

    private func launch(_ fixture: String, reset: Bool = true, orientation: UIDeviceOrientation = .landscapeLeft) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_START_SCREEN"] = "vision"
        app.launchEnvironment["FOX_POSE_FIXTURE"] = fixture
        app.launchEnvironment["FOX_WEB_URL"] = "http://127.0.0.1:1/unreachable"
        if reset { app.launchArguments = ["--ui-testing-reset"] }
        app.launch()
        return app
    }

    func testFixtureCountsCorrectionAndReportSurviveRelaunch() {
        continueAfterFailure = false
        let app = launch("normal")
        let start = app.buttons["vision-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        if phone { options(app, showing: "vision-tracking-diagnostics") }
        XCTAssertTrue(app.staticTexts["测试数据"].exists)
        closeOptions(app)
        XCTAssertEqual(app.webViews.count, 0)
        start.tap()
        let count = app.staticTexts["vision-count"]
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: count)
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 12), .completed)
        app.buttons["vision-pause"].tap()
        options(app, showing: "vision-original-count")
        app.buttons["次数加一"].tap()
        closeOptions(app)
        XCTAssertEqual(count.label, "3")
        options(app, showing: "vision-original-count")
        XCTAssertEqual(app.staticTexts["vision-original-count"].label, "自动 2 · 人工 +1")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "D1-fixture-count-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        closeOptions(app)
        finish(app)
        let reference = app.textFields["vision-reference-count"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        reference.tap(); reference.typeText("3")
        app.dismissNumericKeyboardPopover()
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-report"].label, "自动 2 · 确认 3")
        app.terminate()
        app.launchArguments = []
        app.launch()
        if phone { options(app, showing: "vision-last-report") }
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-report"].label, "自动 2 · 确认 3")
        XCTAssertTrue(app.buttons["导出验证报告"].exists)
        page("计划", app: app)
        XCTAssertTrue(app.buttons["start-training"].waitForExistence(timeout: 5))
    }

    func testCameraDeniedHasActionableStatusAndNeverStartsCounting() {
        let app = launch("denied")
        XCTAssertTrue(app.buttons["vision-open-settings"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-quality"].label, "相机权限未开启")
        XCTAssertFalse(app.buttons["vision-start"].isEnabled)
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
    }

    func testPortraitShowsPreviewCountAndPrimaryControls() {
        let app = launch("normal", orientation: .portrait)
        let start = app.buttons["vision-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertTrue(app.otherElements["pose-preview"].isHittable)
        XCTAssertTrue(app.staticTexts["vision-count"].isHittable)
        XCTAssertTrue(start.isHittable)
        start.tap()
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vision-pause"].isHittable)
        XCTAssertTrue(app.buttons["vision-finish"].isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "D1-fixture-count-portrait"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNoPersonAllowsArmingButDoesNotInventPointsOrCounts() {
        let app = launch("no_person")
        XCTAssertTrue(app.staticTexts["未检测到人"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vision-start"].isEnabled)
        begin(app)
        XCTAssertTrue(app.staticTexts["等待入镜"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vision-cancel-start"].exists)
        XCTAssertFalse(app.buttons["vision-pause"].exists)
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
        if phone { options(app, showing: "vision-tracking-diagnostics"); XCTAssertTrue(app.staticTexts["0 人 · 0 个关键点"].exists) }
        else { XCTAssertTrue(app.staticTexts["0 个关键点"].exists) }
    }

    func testAmbiguousPeoplePreventStartButHiddenWristDoesNotBlockCountdown() {
        continueAfterFailure = false
        let ambiguous = launch("multiple")
        XCTAssertTrue(ambiguous.staticTexts["画面中有多人"].waitForExistence(timeout: 5))
        ambiguous.buttons["vision-start"].tap()
        XCTAssertTrue(ambiguous.staticTexts["主体不明确"].waitForExistence(timeout: 5))
        XCTAssertFalse(ambiguous.buttons["vision-pause"].exists)
        XCTAssertEqual(ambiguous.staticTexts["vision-count"].label, "0")
        ambiguous.terminate()
        let app = launch("low_confidence")
        XCTAssertTrue(app.staticTexts["肩、肘、腕不清晰"].waitForExistence(timeout: 5))
        begin(app)
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
    }

    func testBackgroundPeopleAndReorderedObservationsDoNotPreventTwoCounts() {
        continueAfterFailure = false
        let app = launch("background")
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 5))
        begin(app)
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 12), .completed)
        finish(app)
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
    }

    func testTapBeforeWalkingIntoFrameThenCountdownStartsAutomatically() {
        continueAfterFailure = false
        let app = launch("walk_in")
        XCTAssertTrue(app.staticTexts["未检测到人"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["vision-start"].isEnabled)
        begin(app)
        XCTAssertTrue(app.staticTexts["等待入镜"].waitForExistence(timeout: 5))
        let countdown = app.staticTexts["vision-countdown"]
        XCTAssertTrue(countdown.waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
        XCTAssertFalse(app.buttons["vision-pause"].exists)
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 6))
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 12), .completed)
    }

    func testCancelCountdownAndLeavingVisionDisarmAutomaticStart() {
        continueAfterFailure = false
        let app = launch("normal")
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 5))
        begin(app)
        XCTAssertTrue(app.staticTexts["vision-countdown"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "D1-start-countdown"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["vision-cancel-start"].tap()
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["vision-countdown"].exists)
        XCTAssertFalse(app.buttons["vision-finish"].exists)
        begin(app)
        XCTAssertTrue(app.buttons["vision-cancel-start"].waitForExistence(timeout: 5))
        page("计划", app: app)
        page("视觉", app: app)
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["vision-pause"].exists)
        XCTAssertFalse(app.buttons["vision-cancel-start"].exists)
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
    }

    func testBodyViewCorrectionAndCaptureContextSurviveRelaunch() {
        continueAfterFailure = false
        let app = launch("normal")
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 5))
        options(app)
        app.buttons["vision-body-view"].tap()
        let side = app.buttons[phone ? "侧面" : "vision-body-view-side"]
        XCTAssertTrue(side.waitForExistence(timeout: 5))
        side.tap()
        closeOptions(app)
        begin(app)
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 6))
        options(app, showing: "vision-screen-angle")
        XCTAssertEqual(screenAngle(app), "90°")
        closeOptions(app)
        finish(app)
        XCTAssertTrue(app.buttons["vision-report-body-view"].waitForExistence(timeout: 5))
        app.buttons["vision-report-body-view"].tap()
        let mixed = app.buttons["混合机位"]
        XCTAssertTrue(mixed.waitForExistence(timeout: 5))
        mixed.tap()
        let samples = app.descendants(matching: .any)["vision-context-samples"]
        reveal("vision-context-samples", app: app)
        XCTAssertTrue(samples.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(Int(samples.value as? String ?? "") ?? 0, 0)
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-body-view"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-body-view"].label, "人工标注 · 混合机位")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "D1-capture-context-saved"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launchArguments = []
        app.launch()
        if phone { options(app, showing: "vision-last-body-view") }
        XCTAssertTrue(app.staticTexts["vision-last-body-view"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-body-view"].label, "人工标注 · 混合机位")
    }

    func testUnavailableMotionNeverShowsInventedAngleOrBlocksCounting() {
        continueAfterFailure = false
        let app = launch("motion_unavailable")
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 5))
        options(app, showing: "vision-screen-angle")
        XCTAssertEqual(screenAngle(app), "未测得")
        closeOptions(app)
        begin(app)
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 6))
        finish(app)
        XCTAssertTrue(app.buttons["vision-save-report"].waitForExistence(timeout: 5))
        let samples = app.descendants(matching: .any)["vision-context-samples"]
        XCTAssertTrue(samples.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(Int(samples.value as? String ?? "") ?? 0, 0)
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
    }

    func testLateralRaiseCountsSavesSeparateExerciseAndThenCurlStillWorks() {
        continueAfterFailure = false
        let app = launch("normal")
        options(app)
        let exercises = app.segmentedControls["vision-exercise"]
        XCTAssertTrue(exercises.waitForExistence(timeout: 5))
        exercises.buttons["哑铃侧平举"].tap()
        XCTAssertTrue(app.staticTexts["上臂外展角"].exists)
        XCTAssertEqual(app.staticTexts["vision-guidance"].label, "正面面向镜头 · 肩、肘、髋保持入镜")
        closeOptions(app)
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
        begin(app)
        options(app)
        XCTAssertFalse(exercises.buttons["哑铃弯举"].isEnabled)
        closeOptions(app)
        requireTwoCounts(app, stage: "lateral-raise")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "D1-lateral-raise-fixture-landscape"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        finish(app)
        let reference = app.textFields["vision-reference-count"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        reference.tap(); reference.typeText("2")
        app.dismissNumericKeyboardPopover()
        XCTAssertTrue(app.buttons["vision-dismiss-keyboard"].waitForExistence(timeout: 5))
        app.buttons["vision-dismiss-keyboard"].tap()
        app.buttons["vision-report-body-view"].tap()
        XCTAssertTrue(app.buttons["正面"].waitForExistence(timeout: 5))
        app.buttons["正面"].tap()
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-exercise"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-exercise"].label, "哑铃侧平举 · 左臂")
        XCTAssertEqual(app.staticTexts["vision-last-body-view"].label, "人工标注 · 正面")
        app.terminate(); app.launchArguments = []; app.launch()
        if phone { options(app, showing: "vision-last-exercise") }
        XCTAssertTrue(app.staticTexts["vision-last-exercise"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-exercise"].label, "哑铃侧平举 · 左臂")
        // A new trial never inherits the previous exercise's count or body-view declaration.
        if phone { closeOptions(app); options(app) }
        app.segmentedControls["vision-exercise"].buttons["哑铃侧平举"].tap()
        app.segmentedControls["vision-exercise"].buttons["哑铃弯举"].tap()
        if phone { options(app, showing: "vision-original-count") }
        XCTAssertTrue(app.staticTexts["肘角度"].exists)
        closeOptions(app)
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
        begin(app)
        requireTwoCounts(app, stage: "curl-after-relaunch")
        finish(app)
        XCTAssertTrue(app.buttons["vision-save-report"].waitForExistence(timeout: 5))
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-exercise"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-exercise"].label, "哑铃弯举 · 左臂")
    }

    func testMissingHipAllowsStartButNeverInventsLateralRaiseCounts() {
        continueAfterFailure = false
        let app = launch("missing_hip")
        options(app)
        let exercises = app.segmentedControls["vision-exercise"]
        XCTAssertTrue(exercises.waitForExistence(timeout: 5))
        exercises.buttons["哑铃侧平举"].tap()
        closeOptions(app)
        XCTAssertTrue(app.staticTexts["所选侧肩、肘、髋不清晰"].waitForExistence(timeout: 5))
        begin(app)
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 6))
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
        finish(app)
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 5))
        if phone { closeOptions(app); options(app) }
        exercises.buttons["哑铃弯举"].tap()
        closeOptions(app)
        begin(app)
        XCTAssertTrue(app.buttons["vision-pause"].waitForExistence(timeout: 6))
    }

    func testLateralRaisePortraitRightArmControlsAndReport() {
        continueAfterFailure = false
        let app = launch("normal", orientation: .portrait)
        options(app)
        let exercises = app.segmentedControls["vision-exercise"]
        XCTAssertTrue(exercises.waitForExistence(timeout: 5))
        XCTAssertTrue(exercises.buttons["哑铃侧平举"].isHittable)
        exercises.buttons["哑铃侧平举"].tap()
        app.segmentedControls["vision-arm"].buttons["右臂"].tap()
        closeOptions(app)
        XCTAssertTrue(app.otherElements["pose-preview"].isHittable)
        XCTAssertTrue(app.buttons["vision-start"].isHittable)
        begin(app)
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 12), .completed)
        XCTAssertTrue(app.buttons["vision-finish"].isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "D1-lateral-raise-fixture-portrait-right"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        finish(app)
        XCTAssertTrue(app.buttons["vision-save-report"].waitForExistence(timeout: 5))
        saveReport(app)
        XCTAssertTrue(app.staticTexts["vision-last-exercise"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-last-exercise"].label, "哑铃侧平举 · 右臂")
    }
}
