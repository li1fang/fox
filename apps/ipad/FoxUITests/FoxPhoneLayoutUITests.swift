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
        visible(app.buttons["feedback-dismiss-keyboard"], in: app, diagnosticID: "feedback-dismiss-keyboard")
        app.buttons["feedback-dismiss-keyboard"].tap()
        for (index, id) in ["trial-information", "trial-software-issue", "trial-training-feeling"].enumerated() {
            let orientation: UIDeviceOrientation = index == 1 ? .landscapeLeft : .portrait
            XCUIDevice.shared.orientation = orientation
            waitForOrientation(orientation, in: app)
            let field = app.textFields[id], form = app.scrollViews["set-feedback"]
            let footer = app.buttons["submit-feedback"]
            for _ in 0..<12 {
                if fullyVisible(field, in: app, viewport: form, above: footer) { break }
                scrollFeedback(form, target: field, above: footer, in: app)
            }
            stableTarget(field, in: app, viewport: form, above: footer)
            field.tap()
            XCTAssertTrue(form.exists, "Tapping a feedback field must not submit the set")
            XCTAssertFalse(app.buttons["rest-ready"].exists)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 4))
            field.typeText("test \(index)")
            let immediateValue = field.value as? String
            observeInputFailure(field, id: id, expected: "test \(index)", immediateValue: immediateValue, in: app)
            XCTAssertEqual(immediateValue, "test \(index)")
            visible(app.buttons["feedback-dismiss-keyboard"], in: app, diagnosticID: "feedback-dismiss-keyboard")
            app.buttons["feedback-dismiss-keyboard"].tap()
            visible(app.buttons["submit-feedback"], in: app)
            screenshot("phone-feedback-\(index)", app: app)
        }
        app.buttons["submit-feedback"].tap()
        XCTAssertTrue(app.buttons["rest-ready"].waitForExistence(timeout: 5))
    }

    private func observeInputFailure(_ field: XCUIElement, id: String, expected: String,
                                     immediateValue: String?, in app: XCUIApplication) {
        guard app.launchEnvironment["FOX_UI_TESTING"] == "1",
              app.launchArguments.contains("--ui-testing-reset"),
              ProcessInfo.processInfo.environment["FOX_PRIVATE_INPUT_MANIFEST", default: ""].isEmpty else { return }
        var observations: [[String: Any]] = []
        if immediateValue != expected {
            let start = ProcessInfo.processInfo.systemUptime
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let value = field.exists ? field.value as? String : nil
                observations.append(["value": value.map { $0 as Any } ?? NSNull(),
                                     "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start])
                return value == expected
            }, object: nil)
            // Observe only: the original immediate assertion below must still fail.
            _ = XCTWaiter.wait(for: [settled], timeout: 4)
        }
        let diagnostic: [String: Any] = ["schema": "fox.ui_input_probe.v1", "id": id, "expected": expected,
            "immediateValue": immediateValue.map { $0 as Any } ?? NSNull(), "immediateMatched": immediateValue == expected,
            "deadlineSeconds": 4, "observations": observations]
        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) { print("FOX_UI_INPUT \(json)") }
        if immediateValue != expected { print("FOX_SYNTHETIC_UI_INPUT_FAILURE_AX\n\(app.debugDescription)") }
    }

    private func scrollFeedback(_ form: XCUIElement, target: XCUIElement, above footer: XCUIElement,
                                in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch.frame
        let bounds = form.frame.intersection(window)
        let bottom = min(bounds.maxY, footer.frame.minY - 8)
        let gutter = target.frame.minX - bounds.minX
        XCTAssertGreaterThan(gutter, 0, "Need a visible form gutter outside the multiline field", file: file, line: line)
        XCTAssertGreaterThan(bottom - bounds.minY, 60, file: file, line: line)
        guard gutter > 0, bottom - bounds.minY > 60 else { return }
        // A centered swipe can be consumed by a multiline field's own scroll view.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let x = bounds.minX - window.minX + gutter / 2
        let top = bounds.minY - window.minY, height = bottom - bounds.minY
        let start = origin.withOffset(CGVector(dx: x, dy: top + height * 0.8))
        let end = origin.withOffset(CGVector(dx: x, dy: top + height * 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func waitForOrientation(_ orientation: UIDeviceOrientation, in app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let window = app.windows.firstMatch.frame
            return window.width > 0 && window.height > 0
                && (orientation.isLandscape ? window.width > window.height : window.height > window.width)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 4), .completed)
    }

    private func fullyVisible(_ element: XCUIElement, in app: XCUIApplication, viewport: XCUIElement? = nil,
                              above footer: XCUIElement? = nil) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let frame = element.frame, window = app.windows.firstMatch.frame
        let bounds = window.intersection(viewport?.frame ?? window)
        return frame.width > 0 && frame.height > 0 && bounds.contains(frame)
            && (footer == nil || frame.maxY < footer!.frame.minY - 4)
    }

    private func stableTarget(_ element: XCUIElement, in app: XCUIApplication, viewport: XCUIElement? = nil,
                              above footer: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
        var previous: CGRect?, stableSince: TimeInterval?
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard self.fullyVisible(element, in: app, viewport: viewport, above: footer) else {
                previous = nil; stableSince = nil; return false
            }
            let frame = element.frame, now = ProcessInfo.processInfo.systemUptime
            if previous != frame { previous = frame; stableSince = now; return false }
            return now - (stableSince ?? now) >= 0.25
        }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 4)
        if result != .completed { screenshot("unstable-target-\(element.identifier)", app: app) }
        XCTAssertEqual(result, .completed, element.identifier, file: file, line: line)
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
            "viewport": rectangle(app.windows.firstMatch.frame), "elements": elements, "requestedScenario": app.launchEnvironment["FOX_DESIGN_SCENARIO"] ?? "isolated-native-flow"]
        if let json = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]), let value = String(data: json, encoding: .utf8) {
            let geometry = XCTAttachment(string: value)
            geometry.name = "design-\(name)-geometry"; geometry.lifetime = .keepAlways; add(geometry)
        }
    }

    private func visible(_ element: XCUIElement, in app: XCUIApplication, diagnosticID: String? = nil,
                         file: StaticString = #filePath, line: UInt = #line) {
        var observations: [[String: Any]] = []
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var acceptedFrame: CGRect?, acceptedWindow: CGRect?
        let predicate = NSPredicate { _, _ in
            let start = ProcessInfo.processInfo.systemUptime
            var row: [String: Any] = [:]
            defer {
                row["elapsedSeconds"] = ProcessInfo.processInfo.systemUptime - start
                observations.append(row)
            }
            let exists = element.exists
            row["exists"] = exists
            row["existsQuerySeconds"] = ProcessInfo.processInfo.systemUptime - start
            guard exists else { return false }
            let hittableStart = ProcessInfo.processInfo.systemUptime
            let hittable = element.isHittable
            row["hittable"] = hittable
            row["hittableQuerySeconds"] = ProcessInfo.processInfo.systemUptime - hittableStart
            guard hittable else { return false }
            // The application AX root can have no frame even when its main window is visible.
            let window = app.windows.firstMatch.frame, frame = element.frame
            row["window"] = [window.minX, window.minY, window.width, window.height]
            row["frame"] = [frame.minX, frame.minY, frame.width, frame.height]
            let contained = window.width > 0 && window.height > 0 && frame.width > 0 && frame.height > 0
                && window.insetBy(dx: -0.5, dy: -0.5).contains(frame)
            row["contained"] = contained
            if contained { acceptedFrame = frame; acceptedWindow = window }
            return contained
        }
        // Evaluate now; XCTest's first scheduled poll otherwise spends part of this same deadline idle.
        let immediate = predicate.evaluate(with: nil)
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        let waited: XCTWaiter.Result = immediate ? .completed : remaining > 0
            ? XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: remaining) : .timedOut
        let result: XCTWaiter.Result = ProcessInfo.processInfo.systemUptime <= deadline ? waited : .timedOut
        let synthetic = app.launchEnvironment["FOX_UI_TESTING"] == "1"
            && app.launchArguments.contains("--ui-testing-reset")
            && ProcessInfo.processInfo.environment["FOX_PRIVATE_INPUT_MANIFEST", default: ""].isEmpty
        if let diagnosticID, synthetic {
            let diagnostic: [String: Any] = ["schema": "fox.ui_visibility_probe.v2", "id": diagnosticID,
                "viewportSource": "main-window",
                "completed": result == .completed, "deadlineSeconds": 4, "observations": observations]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print("FOX_UI_VISIBILITY \(json)") }
            if result != .completed { print("FOX_SYNTHETIC_UI_FAILURE_AX\n\(app.debugDescription)") }
        }
        if result != .completed { screenshot("not-visible-\(element.identifier)", app: app) }
        XCTAssertEqual(result, .completed, element.identifier, file: file, line: line)
        // Assert the accepted observation, not a new set of unrelated AX queries after the deadline.
        guard result == .completed, let rect = acceptedFrame, let window = acceptedWindow else { return }
        XCTAssertGreaterThan(rect.width, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minX, window.minX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(rect.minY, window.minY, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxX, window.maxX, file: file, line: line)
        XCTAssertLessThanOrEqual(rect.maxY, window.maxY, file: file, line: line)
    }

    private let framingColors: [[UInt8]] = [[0, 255, 0], [255, 0, 0], [255, 255, 0], [0, 0, 255]]

    private func wholeFramingMatches(_ colors: [[UInt8]]) -> Bool {
        colors.count == 4 && zip(colors, framingColors).allSatisfy { actual, expected in
            actual.count == 3 && zip(actual, expected).allSatisfy { abs(Int($0) - Int($1)) < 20 }
        }
    }

    func testFramingValidationRequiresEveryCorner() throws {
        try requirePhone()
        XCTAssertTrue(wholeFramingMatches(framingColors))
        XCTAssertFalse(wholeFramingMatches(Array(framingColors.prefix(3))))
        XCTAssertFalse(wholeFramingMatches(framingColors + [framingColors[0]]))
        for corner in framingColors.indices {
            var colors = framingColors
            colors[corner] = [70, 70, 70]
            XCTAssertFalse(wholeFramingMatches(colors))
        }
        var boundary = framingColors
        boundary[0][1] = 236; XCTAssertTrue(wholeFramingMatches(boundary))
        boundary[0][1] = 235; XCTAssertFalse(wholeFramingMatches(boundary))
        boundary[0] = [0, 255]; XCTAssertFalse(wholeFramingMatches(boundary))
    }

    private struct FramingSample: Equatable {
        let colors: [[UInt8]]
        let window: CGRect
        let preview: CGRect
    }

    private func framingPixels(in app: XCUIApplication) -> FramingSample? {
        let preview = app.otherElements["pose-preview"].frame
        let window = app.windows.firstMatch.frame
        guard preview.width > 0, preview.height > 0, window.width > 0, window.height > 0 else { return nil }
        let scale = min(preview.width / 720, preview.height / 1280)
        let imageRect = CGRect(x: preview.midX - 360 * scale, y: preview.midY - 640 * scale,
                               width: 720 * scale, height: 1280 * scale)
        let captured = XCUIScreen.main.screenshot().image
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let upright = UIGraphicsImageRenderer(size: captured.size, format: format).image { _ in
            captured.draw(in: CGRect(origin: .zero, size: captured.size))
        }
        guard let screenshot = upright.cgImage,
              app.windows.firstMatch.frame == window, app.otherElements["pose-preview"].frame == preview else { return nil }
        let pixelScale = CGFloat(screenshot.width) / window.width
        guard abs(pixelScale - CGFloat(screenshot.height) / window.height) < 0.01 else { return nil }
        let inset = 36 * scale
        let samples = [
            CGPoint(x: imageRect.minX + inset, y: imageRect.minY + inset),
            CGPoint(x: imageRect.maxX - inset, y: imageRect.minY + inset),
            CGPoint(x: imageRect.minX + inset, y: imageRect.maxY - inset),
            CGPoint(x: imageRect.maxX - inset, y: imageRect.maxY - inset)
        ]
        var colors: [[UInt8]] = []
        for point in samples {
            guard let crop = screenshot.cropping(to: CGRect(x: (point.x - window.minX) * pixelScale,
                y: (point.y - window.minY) * pixelScale, width: 1, height: 1)) else { return nil }
            var rgba = [UInt8](repeating: 0, count: 4)
            guard let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            colors.append(Array(rgba.prefix(3)))
        }
        return FramingSample(colors: colors, window: window, preview: preview)
    }

    private func assertWholeFramingImage(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let start = ProcessInfo.processInfo.systemUptime, deadline = start + 4
        var colors: [[UInt8]] = [], observations: [[String: Any]] = []
        var previous: FramingSample?, stableSince: TimeInterval?, stableSeconds: TimeInterval = 0
        let predicate = NSPredicate { _, _ in
            let sample = self.framingPixels(in: app), now = ProcessInfo.processInfo.systemUptime
            colors = sample?.colors ?? []
            if self.wholeFramingMatches(colors) {
                if sample != previous { previous = sample; stableSince = now }
                stableSeconds = now - (stableSince ?? now)
            } else { previous = nil; stableSince = nil; stableSeconds = 0 }
            var observation: [String: Any] = ["elapsedSeconds": now - start, "stableSeconds": stableSeconds, "cornerRGB": colors]
            if let sample {
                observation["window"] = [sample.window.minX, sample.window.minY, sample.window.width, sample.window.height]
                observation["preview"] = [sample.preview.minX, sample.preview.minY, sample.preview.width, sample.preview.height]
            }
            observations.append(observation)
            return self.wholeFramingMatches(colors) && stableSeconds >= 0.25
        }
        // A hittable view may still be in the system rotation animation. Wait for rendered pixels, not a fixed sleep.
        let immediate = predicate.evaluate(with: nil), remaining = deadline - ProcessInfo.processInfo.systemUptime
        let result: XCTWaiter.Result = immediate ? .completed : remaining > 0
            ? XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: remaining) : .timedOut
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let complete = result == .completed && elapsed <= 4
        if app.launchEnvironment["FOX_UI_TESTING"] == "1",
           ProcessInfo.processInfo.environment["FOX_PRIVATE_INPUT_MANIFEST", default: ""].isEmpty {
            let diagnostic: [String: Any] = ["schema": "fox.ui_framing_probe.v1", "orientation": XCUIDevice.shared.orientation.rawValue,
                "completed": complete, "deadlineSeconds": 4, "elapsedSeconds": elapsed, "stableSeconds": stableSeconds,
                "cornerRGB": colors, "observations": observations]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print("FOX_UI_FRAMING \(json)") }
        }
        XCTAssertTrue(complete, "Whole preview did not finish rendering within four seconds", file: file, line: line)
        XCTAssertGreaterThanOrEqual(stableSeconds, 0.25, file: file, line: line)
        XCTAssertTrue(wholeFramingMatches(colors), "All four image corners must match the original RGB tolerance: \(colors)", file: file, line: line)
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
        waitForOrientation(.landscapeLeft, in: app)
        let exercise = app.segmentedControls["vision-quick-exercise"], arm = app.segmentedControls["vision-quick-arm"]
        visible(exercise, in: app); visible(arm, in: app)
        for choice in [exercise.buttons["哑铃侧平举"], arm.buttons["右臂"]] {
            stableTarget(choice, in: app)
            choice.tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: choice)
            let result = XCTWaiter.wait(for: [selected], timeout: 4)
            if result != .completed { screenshot("quick-selection-not-applied", app: app) }
            XCTAssertEqual(result, .completed, choice.label)
        }
        XCTAssertTrue(app.staticTexts["哑铃侧平举 · 右臂"].waitForExistence(timeout: 4))
        let preview = app.otherElements["pose-preview"].frame
        XCTAssertLessThan(exercise.frame.maxX, preview.minX)
        XCTAssertLessThan(arm.frame.maxX, preview.minX)
        screenshot("phone-landscape-quick-selections", app: app)
        app.buttons["vision-start"].tap()
        XCTAssertTrue(app.buttons["vision-cancel-start"].waitForExistence(timeout: 4))
        XCTAssertFalse(exercise.isEnabled); XCTAssertFalse(arm.isEnabled)
        app.buttons["vision-cancel-start"].tap()
        // Cancel stops preparation immediately; controls unlock after the recording is sealed asynchronously.
        let unlocked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["vision-start"].exists && !app.buttons["vision-cancel-start"].exists
                && exercise.isEnabled && arm.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: 4), .completed)
        XCTAssertTrue(exercise.isEnabled); XCTAssertTrue(arm.isEnabled)
        XCTAssertTrue(exercise.buttons["哑铃侧平举"].isSelected); XCTAssertTrue(arm.buttons["右臂"].isSelected)
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
        XCTAssertGreaterThan(preview.frame.height, app.windows.firstMatch.frame.height * 0.4)
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
        XCTAssertGreaterThan(preview.frame.height, app.windows.firstMatch.frame.height * 0.75)
        XCTAssertGreaterThan(preview.frame.width, app.windows.firstMatch.frame.width * 0.4)
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
                XCTAssertGreaterThan(preview.height, app.windows.firstMatch.frame.height * 0.7)
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
