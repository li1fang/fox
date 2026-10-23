import XCTest

final class FoxPhoneLayoutUITests: XCTestCase {
    private func requirePhone() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "iPhone-specific layout")
        continueAfterFailure = false
    }

    func testFeedbackKeyboardAndThreeCategoriesRemainReachableAfterRotation() throws {
        try requirePhone()
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_START_SCREEN": "training"]
        app.launchArguments = ["--ui-testing-reset"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.buttons["start-training"].waitForExistence(timeout: 10))
        app.buttons["start-training"].tap(); app.buttons["begin-set"].tap(); app.buttons["complete-set"].tap()
        let count = app.textFields["actual-reps"]
        XCTAssertTrue(count.waitForExistence(timeout: 5)); count.tap(); count.typeText("2")
        visible(app.buttons["feedback-dismiss-keyboard"], in: app)
        app.buttons["feedback-dismiss-keyboard"].tap()
        for (index, id) in ["trial-information", "trial-software-issue", "trial-training-feeling"].enumerated() {
            XCUIDevice.shared.orientation = index == 1 ? .landscapeLeft : .portrait
            let field = app.textFields[id], form = app.scrollViews["set-feedback"]
            for _ in 0..<12 { if field.isHittable { break }; form.swipeUp() }
            XCTAssertTrue(field.isHittable, id)
            field.tap(); field.typeText("test \(index)")
            visible(app.buttons["feedback-dismiss-keyboard"], in: app)
            app.buttons["feedback-dismiss-keyboard"].tap()
            visible(app.buttons["submit-feedback"], in: app)
            screenshot("phone-feedback-\(index)", app: app)
        }
        app.buttons["submit-feedback"].tap()
        XCTAssertTrue(app.buttons["rest-ready"].waitForExistence(timeout: 5))
    }

    private func screenshot(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "design-\(name)"; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-accessibility"; tree.lifetime = .keepAlways; add(tree)
        func rectangle(_ frame: CGRect) -> [String: Double] {
            ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
        }
        let ids = ["pose-preview", "vision-count", "vision-options", "vision-start", "vision-finish", "vision-exercise", "vision-arm", "vision-quick-exercise", "vision-quick-arm", "workout-quick-arm",
                   "phone-target-reps", "phone-target-weight", "phone-training-progress", "phone-training-details", "training-home", "training-page-menu",
                   "set-elapsed", "tempo-phase", "workout-automatic-count", "workout-tracking-status", "begin-set", "complete-set", "pause-set", "rest-ready", "rest-remaining"]
        let elements: [[String: Any]] = ids.compactMap { id in
            let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
            guard element.exists else { return nil }
            return ["id": id, "frame": rectangle(element.frame), "hittable": element.isHittable]
        }
        let observation: [String: Any] = ["schema": "fox.design_observation.v1", "source": "isolated-design-fixture", "scenario": name,
            "viewport": rectangle(app.frame), "elements": elements, "requestedScenario": app.launchEnvironment["FOX_DESIGN_SCENARIO"] ?? "isolated-native-flow"]
        if let json = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), let value = String(data: json, encoding: .utf8) {
            let geometry = XCTAttachment(string: value)
            geometry.name = "design-\(name)-geometry"; geometry.lifetime = .keepAlways; add(geometry)
        }
    }

    private func visible(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists && element.isHittable else { return false }
            return app.frame.insetBy(dx: -0.5, dy: -0.5).contains(element.frame)
        }, object: nil)
        let result = XCTWaiter.wait(for: [settled], timeout: 4)
        if result != .completed { screenshot("not-visible-\(element.identifier)", app: app) }
        XCTAssertEqual(result, .completed, element.identifier, file: file, line: line)
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        let rect = element.frame, window = app.frame
        XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, window.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, window.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, window.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, window.maxY, file: file, line: line)
    }

    private func assertWholeFramingImage(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let preview = app.otherElements["pose-preview"].frame
        let scale = min(preview.width / 720, preview.height / 1280)
        let imageRect = CGRect(x: preview.midX - 360 * scale, y: preview.midY - 640 * scale,
                               width: 720 * scale, height: 1280 * scale)
        let captured = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let upright = UIGraphicsImageRenderer(size: captured.size, format: format).image { _ in
            captured.draw(in: CGRect(origin: .zero, size: captured.size))
        }
        let screenshot = try XCTUnwrap(upright.cgImage)
        let pixelScale = CGFloat(screenshot.width) / app.frame.width
        let inset = 36 * scale
        let samples: [(CGPoint, [UInt8])] = [
            (CGPoint(x: imageRect.minX + inset, y: imageRect.minY + inset), [0, 255, 0]),
            (CGPoint(x: imageRect.maxX - inset, y: imageRect.minY + inset), [255, 0, 0]),
            (CGPoint(x: imageRect.minX + inset, y: imageRect.maxY - inset), [255, 255, 0]),
            (CGPoint(x: imageRect.maxX - inset, y: imageRect.maxY - inset), [0, 0, 255])
        ]
        for (point, expected) in samples {
            let crop = try XCTUnwrap(screenshot.cropping(to: CGRect(x: point.x * pixelScale, y: point.y * pixelScale, width: 1, height: 1)))
            var rgba = [UInt8](repeating: 0, count: 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            for index in 0..<3 { XCTAssertLessThan(abs(Int(rgba[index]) - Int(expected[index])), 20, "Image corner cropped/covered at \(point)", file: file, line: line) }
        }
    }

    private func previewIdentity(in app: XCUIApplication) throws -> String {
        let value = try XCTUnwrap(app.otherElements["pose-preview"].value as? String)
        let identity = try XCTUnwrap(value.components(separatedBy: ";preview=").last)
        XCTAssertNotNil(UUID(uuidString: identity))
        return identity
    }

    func testLandscapeQuickSelectionsApplyAndLockWithoutOpeningSettings() throws {
        try requirePhone()
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_START_SCREEN": "vision", "FOX_POSE_FIXTURE": "no_person", "FOX_POSE_IMAGE_FIXTURE": "1"]
        app.launchArguments = ["--ui-testing-reset"]; app.launch()
        XCTAssertTrue(app.segmentedControls["vision-quick-exercise"].waitForExistence(timeout: 10))
        let exercise = app.segmentedControls["vision-quick-exercise"], arm = app.segmentedControls["vision-quick-arm"]
        visible(exercise, in: app); visible(arm, in: app)
        exercise.buttons["哑铃侧平举"].tap(); arm.buttons["右臂"].tap()
        XCTAssertTrue(app.staticTexts["哑铃侧平举 · 右臂"].waitForExistence(timeout: 4))
        let preview = app.otherElements["pose-preview"].frame
        XCTAssertLessThan(exercise.frame.maxX, preview.minX)
        XCTAssertLessThan(arm.frame.maxX, preview.minX)
        screenshot("phone-landscape-quick-selections", app: app)
        app.buttons["vision-start"].tap()
        XCTAssertTrue(app.buttons["vision-cancel-start"].waitForExistence(timeout: 4))
        XCTAssertFalse(exercise.isEnabled); XCTAssertFalse(arm.isEnabled)
        app.buttons["vision-cancel-start"].tap()
        XCTAssertTrue(exercise.isEnabled); XCTAssertTrue(arm.isEnabled)
    }

    func testVisionPortraitUsesCameraFirstAndAccessibleOptions() throws {
        try requirePhone()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": "no_person", "FOX_POSE_IMAGE_FIXTURE": "1"]
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["home-training"].waitForExistence(timeout: 10))
        app.buttons["home-training"].tap()
        app.buttons["视觉"].tap()
        XCTAssertTrue(app.otherElements["pose-preview"].waitForExistence(timeout: 8))
        screenshot("phone-vision-portrait", app: app)
        visible(app.buttons["vision-options"], in: app)
        visible(app.buttons["vision-start"], in: app)
        let preview = app.otherElements["pose-preview"]
        visible(preview, in: app)
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.4)
        try assertWholeFramingImage(in: app)
        app.buttons["vision-options"].tap()
        XCTAssertTrue(app.segmentedControls["vision-exercise"].waitForExistence(timeout: 5))
        visible(app.segmentedControls["vision-exercise"], in: app)
        visible(app.segmentedControls["vision-arm"], in: app)
        screenshot("phone-vision-options", app: app)
        let armPosition = app.segmentedControls["vision-arm"].frame.minY
        app.segmentedControls["vision-exercise"].buttons["哑铃侧平举"].tap()
        let exerciseSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"),
            object: app.segmentedControls["vision-exercise"].buttons["哑铃侧平举"])
        XCTAssertEqual(XCTWaiter.wait(for: [exerciseSelected], timeout: 4), .completed)
        XCTAssertEqual(app.segmentedControls["vision-arm"].frame.minY, armPosition, accuracy: 1, "Guidance text must not move the next selection target")
        let right = app.segmentedControls["vision-arm"].buttons["右臂"]
        right.tap()
        let armSelected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: right)
        XCTAssertEqual(XCTWaiter.wait(for: [armSelected], timeout: 4), .completed)
        let camera = app.segmentedControls["vision-camera"]
        for label in ["后置", "前置"] {
            let choice = camera.buttons[label]
            choice.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: choice)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 4), .completed)
        }
        app.buttons["vision-options-done"].tap()
        visible(app.buttons["vision-options"], in: app)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: app.buttons["vision-start"])
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed)
        let selection = app.staticTexts["哑铃侧平举 · 右臂"]
        let selected = selection.waitForExistence(timeout: 5)
        if !selected { screenshot("phone-vision-selection-not-applied", app: app) }
        XCTAssertTrue(selected)
        XCUIDevice.shared.orientation = .landscapeLeft
        visible(app.buttons["vision-start"], in: app)
        visible(preview, in: app)
        XCTAssertGreaterThan(preview.frame.height, app.frame.height * 0.75)
        XCTAssertGreaterThan(preview.frame.width, app.frame.width * 0.4)
        for id in ["vision-options", "vision-start", "training-page-menu", "training-home"] {
            XCTAssertLessThan(app.buttons[id].frame.maxX, preview.frame.minX, id)
        }
        try assertWholeFramingImage(in: app)
        screenshot("phone-vision-landscape", app: app)
        app.buttons["training-page-menu"].tap()
        app.buttons["计划"].tap()
        XCTAssertTrue(app.buttons["start-training"].waitForExistence(timeout: 5))
    }

    func testManualPortraitShowsAllCoreFactsWithoutScrolling() throws {
        try requirePhone()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_DESIGN_SCENARIO": "training-active", "FOX_POSE_FIXTURE": "no_person"]
        app.launch()
        XCTAssertTrue(app.buttons["complete-set"].waitForExistence(timeout: 10))
        screenshot("phone-manual-portrait", app: app)
        for id in ["phone-target-reps", "phone-target-weight", "set-elapsed", "tempo-phase"] {
            visible(app.staticTexts[id], in: app)
        }
        visible(app.buttons["complete-set"], in: app)
        visible(app.buttons["pause-set"], in: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        for id in ["phone-target-reps", "phone-target-weight", "set-elapsed", "tempo-phase"] { visible(app.staticTexts[id], in: app) }
        visible(app.buttons["complete-set"], in: app)
        screenshot("phone-manual-landscape", app: app)
        app.buttons["pause-set"].tap()
        visible(app.buttons["begin-set"], in: app)
        visible(app.buttons["complete-set"], in: app)
        screenshot("phone-manual-paused-landscape", app: app)
    }

    func testReadyWeightChangesPropagateAndRestTargetsStayVisible() throws {
        try requirePhone()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_DESIGN_SCENARIO": "training-ready", "FOX_POSE_FIXTURE": "no_person"]
        app.launch()
        XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 10))
        for id in ["phone-target-reps", "phone-target-weight", "set-elapsed", "tempo-phase"] { visible(app.staticTexts[id], in: app) }
        app.buttons["phone-training-details"].tap()
        XCTAssertTrue(app.textFields["actual-weight"].waitForExistence(timeout: 5))
        app.buttons["选择哑铃重量"].tap()
        app.buttons["5 kg"].tap()
        app.buttons["phone-training-details-done"].tap()
        XCTAssertEqual(app.staticTexts["phone-target-weight"].label, "5 kg")
        screenshot("phone-manual-ready", app: app)
        app.buttons["begin-set"].tap()
        app.buttons["complete-set"].tap()
        app.textFields["actual-reps"].tap(); app.textFields["actual-reps"].typeText("8")
        app.buttons["submit-feedback"].tap()
        XCTAssertTrue(app.buttons["rest-ready"].waitForExistence(timeout: 5))
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for id in ["phone-target-reps", "phone-target-weight", "rest-remaining"] { visible(app.staticTexts[id], in: app) }
            visible(app.buttons["rest-ready"], in: app)
            visible(app.buttons["extend-rest"], in: app)
            screenshot("phone-rest-\(orientation == .portrait ? "portrait" : "landscape")", app: app)
        }
    }

    func testVisionOptionsLockCorrectionAndSavedReportRemainUsable() throws {
        try requirePhone()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_START_SCREEN": "vision", "FOX_POSE_FIXTURE": "normal", "FOX_POSE_IMAGE_FIXTURE": "1"]
        app.launchArguments = ["--ui-testing-reset"]; app.launch()
        XCTAssertTrue(app.buttons["vision-start"].waitForExistence(timeout: 10))
        app.buttons["vision-options"].tap()
        app.buttons["vision-parameters"].tap()
        XCTAssertTrue(app.buttons["pose-apply-parameters"].waitForExistence(timeout: 5))
        app.buttons["pose-apply-parameters"].tap()
        app.buttons["vision-start"].tap()
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["vision-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 18), .completed)
        let identity = try previewIdentity(in: app)
        for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight, .portrait] {
            let started = ProcessInfo.processInfo.systemUptime
            XCUIDevice.shared.orientation = orientation
            visible(app.buttons["vision-pause"], in: app)
            visible(app.otherElements["pose-preview"], in: app)
            XCTAssertEqual(try previewIdentity(in: app), identity)
            XCTAssertEqual(app.staticTexts["vision-count"].label, "2")
            if orientation != .portrait {
                XCTAssertFalse(app.segmentedControls["vision-quick-exercise"].isEnabled)
                XCTAssertFalse(app.segmentedControls["vision-quick-arm"].isEnabled)
            }
            let timing = XCTAttachment(string: "orientation=\(orientation.rawValue), automationRoundTripSeconds=\(ProcessInfo.processInfo.systemUptime - started); not device frame latency")
            timing.name = "rotation-automation-observation"; timing.lifetime = .keepAlways; add(timing)
            try assertWholeFramingImage(in: app)
            screenshot("phone-counting-rotation-\(orientation.rawValue)", app: app)
        }
        app.buttons["vision-pause"].tap()
        visible(app.buttons["vision-finish"], in: app)
        app.buttons["vision-options"].tap()
        XCTAssertFalse(app.segmentedControls["vision-exercise"].isEnabled)
        XCTAssertFalse(app.buttons["vision-parameters"].isEnabled)
        let add = app.buttons["次数加一"]
        for _ in 0..<4 { if add.isHittable { break }; app.swipeUp() }
        add.tap()
        app.buttons["vision-options-done"].tap()
        XCTAssertEqual(app.staticTexts["vision-count"].label, "3")
        app.buttons["vision-finish"].tap()
        app.buttons["vision-save-report"].tap()
        app.buttons["vision-options"].tap()
        let report = app.staticTexts["vision-last-report"]
        for _ in 0..<8 { if report.isHittable { break }; app.swipeUp() }
        XCTAssertEqual(report.label, "自动 2 · 确认 3")
        screenshot("phone-vision-saved-report", app: app)
    }

    func testVisualWorkoutShowsLargePreviewAndCoreFactsAfterRotation() throws {
        try requirePhone()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_POSE_FIXTURE": "walk_in", "FOX_POSE_IMAGE_FIXTURE": "1"]
        app.launchArguments = ["--ui-testing-reset"]; app.launch()
        XCTAssertTrue(app.buttons["home-training"].waitForExistence(timeout: 10))
        app.buttons["home-training"].tap()
        app.buttons["prepare-day1"].tap(); app.buttons["start-training"].tap()
        visible(app.buttons["begin-vision-set"], in: app)
        app.buttons["begin-vision-set"].tap()
        let counted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '2'"), object: app.staticTexts["workout-automatic-count"])
        XCTAssertEqual(XCTWaiter.wait(for: [counted], timeout: 20), .completed)
        let identity = try previewIdentity(in: app)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            visible(app.otherElements["pose-preview"], in: app)
            XCTAssertEqual(try previewIdentity(in: app), identity)
            for id in ["phone-target-reps", "phone-target-weight", "set-elapsed", "workout-automatic-count"] { visible(app.staticTexts[id], in: app) }
            visible(app.buttons["complete-set"], in: app)
            visible(app.buttons["pause-set"], in: app)
            if orientation != .portrait {
                let preview = app.otherElements["pose-preview"].frame
                XCTAssertGreaterThan(preview.height, app.frame.height * 0.7)
                for id in ["complete-set", "pause-set", "phone-training-details", "training-page-menu", "training-home"] {
                    XCTAssertLessThan(app.buttons[id].frame.maxX, preview.minX, id)
                }
                for id in ["phone-target-reps", "phone-target-weight", "set-elapsed", "workout-automatic-count"] {
                    XCTAssertLessThan(app.staticTexts[id].frame.maxX, preview.minX, id)
                }
            }
            try assertWholeFramingImage(in: app)
            screenshot("phone-workout-visual-\(orientation.rawValue)", app: app)
        }
        app.buttons["pause-set"].tap()
        visible(app.buttons["complete-set"], in: app)
        app.buttons["complete-set"].tap()
        XCTAssertEqual(app.textFields["actual-left-reps"].value as? String, "2")
    }

    func testLargerTextPortraitKeepsCoreFactsAndPrimaryActions() throws {
        try requirePhone()
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_DESIGN_SCENARIO": "training-large-type", "FOX_POSE_FIXTURE": "no_person"]
        app.launch()
        XCTAssertTrue(app.buttons["complete-set"].waitForExistence(timeout: 10))
        for id in ["phone-training-progress", "phone-target-reps", "phone-target-weight", "set-elapsed", "tempo-phase"] { visible(app.staticTexts[id], in: app) }
        visible(app.buttons["complete-set"], in: app)
        visible(app.buttons["pause-set"], in: app)
        visible(app.buttons["phone-training-details"], in: app)
        screenshot("phone-manual-larger-text", app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        visible(app.buttons["complete-set"], in: app)
        visible(app.buttons["pause-set"], in: app)
        visible(app.buttons["training-page-menu"], in: app)
        visible(app.staticTexts["set-elapsed"], in: app)
        visible(app.staticTexts["tempo-phase"], in: app)
        screenshot("phone-manual-larger-text-landscape", app: app)
    }
}
