import XCTest

final class FoxFreeCaptureUITests: XCTestCase {
    func testPhoneSavedLibraryKeepsTrainingNavigationAfterRotation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": "no_person"]
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        let entry = app.buttons["home-prepare-curl"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8)); entry.tap()
        XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 5))
        app.buttons["training-page-menu"].tap()
        app.sheets["训练页面"].buttons["已保存实验"].tap()
        XCTAssertTrue(app.navigationBars["已保存实验"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 8), .completed)
        let menu = app.buttons["training-page-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(app.frame.contains(menu.frame))
        XCTAssertFalse(app.buttons["free-capture-start"].exists)
        XCTAssertFalse(app.buttons["vision-start"].exists)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "saved-library-landscape-navigation"; image.lifetime = .keepAlways; add(image)
        menu.tap(); app.sheets["训练页面"].buttons["训练"].tap()
        XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["workout-automatic-count"].label, "0")
    }
    func testPhoneLaunchKeepsSavedExperimentsAccessibleWithoutCapture() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": "no_person"]
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        let entry = app.buttons["home-capture-lab"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        XCTAssertEqual(entry.label, "已保存实验")
        entry.tap()
        XCTAssertTrue(app.navigationBars["已保存实验"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["验证报告"].exists)
        XCTAssertTrue(app.buttons["诊断录像"].exists)
        XCTAssertFalse(app.buttons["free-capture-start"].exists)
        XCTAssertFalse(app.buttons["vision-start"].exists)
        XCTAssertFalse(app.segmentedControls["capture-lab-mode"].exists)
        app.navigationBars["已保存实验"].buttons["完成"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }
    private func launch(_ fixture: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_START_SCREEN": "vision",
                                 "FOX_POSE_FIXTURE": "no_person", "FOX_FREE_CAPTURE_FIXTURE": fixture]
        app.launchArguments = ["--ui-testing-reset"]; app.launch()
        chooseFree(app)
        return app
    }
    private func chooseFree(_ app: XCUIApplication) {
        let mode = app.segmentedControls["capture-lab-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 8)); mode.buttons["自由采集"].tap()
        XCTAssertTrue(app.buttons["free-capture-start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["vision-start"].exists)
    }
    private func wait(_ predicate: @escaping () -> Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in predicate() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed)
    }
    private func start(_ app: XCUIApplication) {
        app.buttons["free-capture-start"].tap()
        wait { app.staticTexts["free-capture-status"].label == "录像中" &&
            (Int(app.staticTexts["free-capture-frame-status"].label.split(separator: " ").first ?? "") ?? 0) >= 2 }
        XCTAssertEqual(app.staticTexts["free-capture-not-evaluated"].label, "动作与次数：未评测")
        XCTAssertTrue(app.staticTexts["free-capture-source"].label.contains("合成测试样本"))
    }
    private func stop(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["free-capture-stop"].isEnabled); app.buttons["free-capture-stop"].tap()
        wait { app.staticTexts["free-capture-status"].label == "已保存实验原件" }
    }
    func testNoPersonCanRecordSaveCancelExportAndReopenOriginal() {
        let app = launch("no_people"); start(app); stop(app)
        app.buttons["free-capture-library"].tap()
        let packages = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "free-capture-package-"))
        wait { packages.count == 1 }
        let id = packages.firstMatch.identifier
        let raw = String(id.dropFirst("free-capture-package-".count))
        XCTAssertNotNil(UUID(uuidString: raw))
        app.buttons["free-capture-export-\(raw)"].tap()
        XCTAssertTrue(app.buttons["file-export-cancel"].waitForExistence(timeout: 8))
        app.buttons["file-export-cancel"].tap()
        wait { app.buttons[id].exists }
        XCTAssertTrue(app.staticTexts["free-capture-export-status"].label.contains("本机原件保留"))
        app.terminate(); app.launchArguments = []; app.launch(); chooseFree(app)
        app.buttons["free-capture-library"].tap()
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 8)); XCTAssertEqual(packages.count, 1)
        app.buttons[id].tap()
        XCTAssertTrue(app.staticTexts["free-capture-playback-status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["free-capture-playback-status"].label, "实验原片 · 动作与次数未评测")
        XCTAssertEqual(app.webViews.count, 0)
    }
    func testAnalysisFailureStillAllowsStopAndSavesVideo() {
        let app = launch("analysis_error"); start(app)
        wait { app.staticTexts["free-capture-analysis-status"].label.contains("2D 分析失败") }
        stop(app)
        app.buttons["free-capture-library"].tap()
        let package = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "free-capture-package-")).firstMatch
        XCTAssertTrue(package.waitForExistence(timeout: 5))
        XCTAssertTrue(package.label.contains("视频与实验资料已保存"))
    }

    func testPadModeLocksDuringRecordingAndUnlocksAfterSave() {
        let app = launch("no_people")
        let mode = app.segmentedControls["capture-lab-mode"]
        start(app)
        XCTAssertFalse(mode.isEnabled)
        XCTAssertTrue(app.buttons["free-capture-stop"].isHittable)
        stop(app)
        XCTAssertTrue(mode.isEnabled)
        mode.buttons["动作评测"].tap()
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 5))
        mode.buttons["自由采集"].tap()
        XCTAssertTrue(app.buttons["free-capture-start"].waitForExistence(timeout: 5))
        app.buttons["free-capture-library"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "free-capture-package-")).count, 1)
    }
    func testLandscapeKeepsPageNavigationDuringFreeRecording() {
        let app = launch("no_people")
        XCUIDevice.shared.orientation = .landscapeLeft
        let menu = app.buttons["training-page-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); XCTAssertTrue(menu.isHittable)
        start(app)
        XCTAssertTrue(menu.isHittable); menu.tap()
        XCTAssertTrue(app.buttons["视觉实验"].waitForExistence(timeout: 5))
        // Landscape popovers may omit Cancel; selecting this page must keep recording.
        app.buttons["视觉实验"].tap()
        XCTAssertEqual(app.staticTexts["free-capture-status"].label, "录像中")
        XCTAssertTrue(app.buttons["free-capture-stop"].isHittable)
        XCTAssertTrue(app.buttons["free-capture-stop"].isEnabled)
        stop(app)
    }
    func testHomeOpensFreeCaptureWithoutChoosingOrStartingATraining() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_FREE_CAPTURE_FIXTURE": "no_people"]
        app.launchArguments = ["--ui-testing-reset"]; app.launch()
        let entry = app.buttons["home-capture-lab"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8)); entry.tap()
        XCTAssertTrue(app.buttons["free-capture-start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["begin-set"].exists); XCTAssertFalse(app.buttons["vision-start"].exists)
        start(app); stop(app)
        app.buttons["capture-lab-close"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["未结束训练"].exists)
    }
}
