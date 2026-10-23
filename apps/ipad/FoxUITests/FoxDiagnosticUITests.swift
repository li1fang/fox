import XCTest

final class FoxDiagnosticUITests: XCTestCase {
    private func launch(_ fixture: String) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_START_SCREEN"] = "vision"
        app.launchEnvironment["FOX_POSE_FIXTURE"] = fixture
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["diagnostic-toggle"].exists)
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.isHittable { return }
            let x = app.navigationBars["核对视觉验证"].exists ? 0.5 : 0.86
            app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.8)).press(forDuration: 0.02,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.35)))
        }
        if !element.isHittable {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Diagnostic-control-not-hittable"; screenshot.lifetime = .keepAlways; add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Diagnostic-control-accessibility"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertTrue(element.isHittable)
    }
    private func review(_ app: XCUIApplication) {
        let identifier = app.navigationBars["核对视觉验证"].exists ? "diagnostic-report-review-latest" : "diagnostic-review-latest"
        let review = app.buttons[identifier]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        reveal(review, in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.tap()
        XCTAssertTrue(app.staticTexts["diagnostic-pending-retention"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["diagnostic-keep"].exists)
        XCTAssertTrue(app.buttons["diagnostic-discard"].exists)
    }

    func testFailedPreparationCanBeKeptAfterReviewAndCancelledExportPreservesIt() {
        let app = launch("no_person")
        app.buttons["vision-start"].tap()
        XCTAssertTrue(app.staticTexts["等待入镜"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["vision-count"].label, "0")
        app.buttons["vision-cancel-start"].tap()
        review(app)
        app.buttons["diagnostic-keep"].tap()
        let library = app.buttons["diagnostic-library"]; reveal(library, in: app); library.tap()
        XCTAssertTrue(app.staticTexts["diagnostic-package-status"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["测试样本 · 非真实相机"].firstMatch.exists)
        let filters = app.segmentedControls["diagnostic-filter"]
        XCTAssertTrue(filters.exists)
        let pending = filters.buttons.matching(NSPredicate(format: "label BEGINSWITH '待核对' ")).firstMatch
        let retained = filters.buttons.matching(NSPredicate(format: "label BEGINSWITH '已保留' ")).firstMatch
        // Exercise both directions repeatedly, with one tap per transition, not retry-to-green.
        for _ in 0..<4 {
            selectFilter(pending, in: app)
            if (Int(pending.label.filter(\.isNumber)) ?? 0) > 0 {
                XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'diagnostic-draft-' ")).firstMatch.waitForExistence(timeout: 5))
            } else { XCTAssertTrue(app.staticTexts["暂无待核对片段"].waitForExistence(timeout: 5)) }
            selectFilter(retained, in: app)
            XCTAssertTrue(app.staticTexts["diagnostic-package-status"].firstMatch.waitForExistence(timeout: 5))
        }
        let export = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'diagnostic-export-' ")).firstMatch
        XCTAssertTrue(export.waitForExistence(timeout: 5)); reveal(export, in: app); export.tap()
        let save = app.navigationBars.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["保存", "Save"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        let picker = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picker.name = "Diagnostic-native-files-before-cancel"; picker.lifetime = .keepAlways; add(picker)
        let pickerTree = XCTAttachment(string: app.debugDescription)
        pickerTree.name = "Diagnostic-native-files-accessibility"; pickerTree.lifetime = .keepAlways; add(pickerTree)
        let cancel = app.buttons["file-export-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); XCTAssertTrue(cancel.isHittable); cancel.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)], timeout: 5), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["已关闭导出面板，本机原件保留。"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["已关闭导出面板，本机原件保留。"].isHittable)
        XCTAssertTrue(app.staticTexts["diagnostic-package-status"].firstMatch.exists)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Diagnostic-post-review-retention-export-cancel"; image.lifetime = .keepAlways; add(image)
    }

    private func selectFilter(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.isHittable)
        let before = XCTAttachment(string: app.debugDescription)
        before.name = "Diagnostic-filter-before-\(element.label)"; before.lifetime = .keepAlways; add(before)
        element.tap()
        let selection = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: element)], timeout: 5)
        if selection != .completed {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Diagnostic-filter-selection-failed"; screenshot.lifetime = .keepAlways; add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Diagnostic-filter-after"; tree.lifetime = .keepAlways; add(tree)
        }
        XCTAssertEqual(selection, .completed, "A single tap must switch the filter before rows are asserted")
    }

    func testNormalCountCanReviewThenDiscardVideoWithoutChangingTrainingReport() {
        let app = launch("normal")
        app.buttons["vision-start"].tap()
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 15), .completed)
        app.buttons["vision-finish"].tap()
        XCTAssertTrue(app.buttons["vision-save-report"].waitForExistence(timeout: 8))
        review(app)
        app.buttons["diagnostic-discard"].tap()
        let save = app.buttons["vision-save-report"]
        XCTAssertTrue(save.waitForExistence(timeout: 8)); save.tap()
        XCTAssertTrue(app.staticTexts["vision-last-report"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["vision-last-report"].label, "自动 2 · 确认 2")
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Diagnostic-discard-keeps-normal-count-report"; image.lifetime = .keepAlways; add(image)
    }
}
