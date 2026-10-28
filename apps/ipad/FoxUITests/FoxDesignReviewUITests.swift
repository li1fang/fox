import XCTest

final class FoxDesignReviewUITests: XCTestCase {
    override func setUp() {
        super.setUp()
    }
    func testColumnAffinitySurvivesComposerGrowth() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_DESIGN_SCENARIO"] = DesignScenario.mixed.id
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "design-scenario-ready").firstMatch.waitForExistence(timeout: 12))
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'journal-record-'"))
        let positions = Dictionary(uniqueKeysWithValues: cards.allElementsBoundByIndex.map { ($0.identifier, $0.frame.minX) })
        capture("home-column-affinity-before", app: app)
        let field = app.descendants(matching: .any).matching(identifier: "journal-note").firstMatch
        field.tap(); field.typeText(String(repeating: "A longer draft grows this card. ", count: 8))
        capture("home-column-affinity", app: app)
        for card in cards.allElementsBoundByIndex { XCTAssertEqual(card.frame.minX, positions[card.identifier]!, accuracy: 1) }
        app.terminate()
    }
    func testHomeScenarios() throws { captureScenes(DesignScenario.homeRemainingCases) }
    func testHomeSmokeScenarios() throws { captureScenes(DesignScenario.homeSmokeCases) }
    func testTrainingProjectionScenarios() { captureScenes(DesignScenario.projectionCases) }
    func testTrainingScenarios() { captureTrainingScenes(DesignScenario.trainingRemainingCases) }
    func testTrainingRotatedFeedbackInput() { captureTrainingScenes([.trainingFeedbackRotated]) }
    func testTrainingJourneyScenarios() {
        captureTrainingScenes(DesignScenario.trainingJourneyCases)
    }
    private func captureTrainingScenes(_ scenes: [DesignScenario]) {
        continueAfterFailure = false
        for scenario in scenes {
            let app = XCUIApplication()
            app.launchEnvironment["FOX_UI_TESTING"] = "1"
            app.launchEnvironment["FOX_DESIGN_SCENARIO"] = scenario.id
            app.launchEnvironment["FOX_POSE_FIXTURE"] = "no_person"
            XCUIDevice.shared.orientation = scenario.isLandscape ? .landscapeLeft : .portrait
            app.launch()
            let ready = app.descendants(matching: .any).matching(identifier: "design-scenario-ready").firstMatch
            let loaded = ready.waitForExistence(timeout: 12)
            if !loaded { capture("\(scenario.id)-unready", app: app) }
            XCTAssertTrue(loaded, scenario.id)
            if scenario == .trainingWaiting { XCTAssertTrue(app.buttons["begin-set"].waitForExistence(timeout: 5)) }
            capture(scenario.id, app: app)
            if scenario == .trainingRotated && app.frame.height < 500 {
                XCTAssertTrue(app.otherElements["training-stage-surface"].exists)
                let viewport = app.frame
                for id in ["set-elapsed", "tempo-phase", "phone-target-reps", "phone-target-weight"] {
                    let value = app.staticTexts[id]
                    XCTAssertTrue(value.exists, id)
                    XCTAssertGreaterThanOrEqual(value.frame.minY, viewport.minY, id)
                    XCTAssertLessThanOrEqual(value.frame.maxY, viewport.maxY, id)
                }
            }
            if scenario == .trainingFeedback {
                app.textFields["actual-reps"].tap(); app.textFields["actual-reps"].typeText("8")
                capture("training-feedback-keyboard", app: app)
                app.dismissNumericKeyboardPopover()
            } else if scenario == .trainingFeedbackRotated {
                let left = app.textFields["actual-left-reps"], right = app.textFields["actual-right-reps"]
                left.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                left.typeText("8")
                XCTAssertEqual(left.value as? String, "8")
                capture("training-feedback-rotated-left-input", app: app)
                app.dismissNumericKeyboardPopover()
                right.tap()
                right.typeText("7")
                XCTAssertEqual(left.value as? String, "8"); XCTAssertEqual(right.value as? String, "7")
                capture("training-feedback-rotated-keyboard", app: app)
                app.dismissNumericKeyboardPopover()
            }
            let primary: [String]
            switch scenario {
            case .trainingActive, .trainingRotated, .trainingLargeType: primary = ["complete-set", "pause-set"]
            case .trainingPaused: primary = ["begin-set", "complete-set"]
            case .trainingReady: primary = ["begin-set", "skip-set"]
            case .trainingWaiting: primary = ["begin-set", "skip-set"]
            case .trainingRest: primary = ["rest-ready"]
            case .trainingFeedback, .trainingFeedbackRotated: primary = ["submit-feedback"]
            case .trainingSummary: primary = ["confirm-summary"]
            case .trainingDiagnostic: primary = ["diagnostic-keep", "diagnostic-discard"]
            default: primary = []
            }
            for id in primary {
                let button = app.buttons[id]
                XCTAssertTrue(button.exists, id)
                XCTAssertGreaterThanOrEqual(button.frame.minY, app.frame.minY, id)
                XCTAssertLessThanOrEqual(button.frame.maxY, app.frame.maxY, id)
                if button.isEnabled { XCTAssertTrue(button.isHittable, id) }
            }
            app.terminate()
        }
    }
    func testReadOnlyTrainingCardCanOpenAndClose() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_DESIGN_SCENARIO"] = DesignScenario.homeCurrent.id
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let card = app.buttons["home-training-projection-current"]
        XCTAssertTrue(card.waitForExistence(timeout: 12))
        if !card.isHittable { app.swipeUp() }
        card.tap()
        XCTAssertTrue(app.scrollViews["home-training-detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本机档案 · 只读"].exists)
        XCTAssertFalse(app.buttons["begin-set"].exists)
        capture("projection-read-only-detail", app: app)
        app.navigationBars["训练档案"].buttons["完成"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }
    private func captureScenes(_ scenes: [DesignScenario]) {
        continueAfterFailure = false
        for scenario in scenes {
            let app = XCUIApplication()
            app.launchEnvironment["FOX_UI_TESTING"] = "1"
            app.launchEnvironment["FOX_DESIGN_SCENARIO"] = scenario.id
            XCUIDevice.shared.orientation = scenario.isLandscape ? .landscapeLeft : .portrait
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "design-scenario-ready").firstMatch.waitForExistence(timeout: 12), scenario.id)
            if [.homePlan, .homeCurrent, .homeConfirmed].contains(scenario) {
                XCTAssertTrue(app.buttons["home-training-projection-plan"].waitForExistence(timeout: 5))
                if scenario == .homeConfirmed {
                    let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-training-projection-' AND identifier != 'home-training-projection-plan'")).firstMatch
                    XCTAssertTrue(history.waitForExistence(timeout: 5))
                    XCTAssertTrue(history.label.contains("部分完成 1 组"))
                }
            } else if scenario == .homeNoTraining {
                XCTAssertTrue(app.staticTexts["本机暂无训练档案"].waitForExistence(timeout: 5))
            } else if scenario == .homeCorruptTraining {
                XCTAssertTrue(app.buttons["重试训练档案"].waitForExistence(timeout: 5))
            }
            if scenario == .keyboard {
                app.descendants(matching: .any).matching(identifier: "journal-note").firstMatch.tap()
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            }
            capture(scenario.id, app: app)
            app.terminate()
        }
    }

    func testRecordScenarios() {
        continueAfterFailure = false
        for scenario in DesignScenario.recordCases {
            let app = XCUIApplication()
            app.launchEnvironment["FOX_UI_TESTING"] = "1"
            app.launchEnvironment["FOX_DESIGN_SCENARIO"] = scenario.id
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "design-scenario-ready").firstMatch.waitForExistence(timeout: 12))
            if scenario == .recordConflict {
                app.buttons["journal-edit"].tap()
                let field = app.descendants(matching: .any).matching(identifier: "journal-edit-note").firstMatch
                field.tap(); field.typeText(" My correction.")
                app.buttons["journal-edit-save"].tap()
                XCTAssertTrue(app.staticTexts["journal-edit-error"].waitForExistence(timeout: 5))
            }
            capture(scenario.id, app: app)
            app.terminate()
        }
    }

    func testFullPhotoCanZoomAndReturnToUnchangedRecord() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_DESIGN_SCENARIO"] = DesignScenario.recordLongPhoto.id
        app.launch()
        let open = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'journal-open-photo-' ")).firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 12)); open.tap()
        let level = app.staticTexts["photo-zoom-level"]
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "journal-full-photo").firstMatch.waitForExistence(timeout: 8))
        let fitted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let number = Int(level.label.filter(\.isNumber)) ?? 0
            return number > 0 && number < 100
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fitted], timeout: 5), .completed)
        let old = Int(level.label.filter(\.isNumber))!
        app.buttons["放大"].tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Int(level.label.filter(\.isNumber)) ?? 0) > old
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        capture("record-full-photo-zoom", app: app)
        app.navigationBars["照片"].buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["journal-revision"].label, "修订 1")
    }

    private func capture(_ id: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "design-\(id)"; screenshot.lifetime = .keepAlways; add(screenshot)
        let targets = ["journal-note", "journal-save", "journal-camera", "home-prepare-curl", "home-capabilities", "home-plan", "home-history", "home-history-list", "journal-save-error",
                       "home-training-retry", "journal-retry-load", "journal-dismiss-notice", "journal-load-more",
                       "home-service-cards", "home-service-refresh", "home-service-apply-updates", "home-service-pending", "home-service-synthetic", "home-service-error", "home-service-empty",
                       "journal-edit", "journal-edit-note", "journal-edit-save", "journal-edit-error", "journal-reload-latest", "journal-export-backup",
                       "begin-set", "manual-count", "complete-set", "pause-set", "rest-ready",
                       "submit-feedback", "confirm-summary", "actual-reps", "actual-left-reps", "actual-right-reps", "set-elapsed", "tempo-phase", "training-stage-surface", "phone-target-reps", "phone-target-weight", "phone-training-details", "workout-automatic-count", "workout-tracking-status", "diagnostic-keep", "diagnostic-discard"]
        let recordIDs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'journal-record-' ")).allElementsBoundByIndex.prefix(8).map(\.identifier)
        let projectionIDs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-training-projection-' ")).allElementsBoundByIndex.map(\.identifier)
        let entryIDs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home-try-' OR identifier BEGINSWITH 'home-preparation-' OR identifier BEGINSWITH 'home-resume-' OR identifier BEGINSWITH 'home-review-' OR identifier BEGINSWITH 'home-open-' OR identifier BEGINSWITH 'home-history-' ")).allElementsBoundByIndex.map(\.identifier)
        let serviceIDs = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'home-card-' OR identifier BEGINSWITH 'home-submission-' ")).allElementsBoundByIndex.map(\.identifier)
        var seenIdentifiers: Set<String> = []
        let identifiers = (targets + entryIDs + recordIDs + projectionIDs + serviceIDs + ["journal-detail-note", "photo-zoom-level"])
            .filter { seenIdentifiers.insert($0).inserted }
        // Resolve present targets together; absent IDs must not each trigger a fresh AX tree search.
        let matches = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", identifiers)).allElementsBoundByIndex
        var firstByID: [String: XCUIElement] = [:]
        var queryIndexByID: [String: Int] = [:]
        for (index, element) in matches.enumerated() where firstByID[element.identifier] == nil {
            firstByID[element.identifier] = element
            queryIndexByID[element.identifier] = index
        }
        let values: [[String: Any]] = identifiers.compactMap { identifier in
            guard let element = firstByID[identifier] else { return nil }
            return ["id": identifier, "frame": frame(element.frame), "hittable": element.isHittable,
                    "label": element.label, "enabled": element.isEnabled, "axQueryIndex": queryIndexByID[identifier]!]
        }
        let scenario = DesignScenario(rawValue: app.launchEnvironment["FOX_DESIGN_SCENARIO"] ?? "")
        let report: [String: Any] = ["schema": "fox.design_observation.v1", "scenario": id,
            "source": "isolated-design-fixture", "viewport": frame(app.frame),
            "elementOrder": "requested-target-order", "axQueryScope": "matched-diagnostic-targets-not-voiceover-order",
            "hostRequestedTypography": scenario?.usesLargeType == true ? "accessibility2" : "large",
            "hostRequestedAppearance": scenario?.usesDarkAppearance == true ? "dark" : "light",
            "keyboard": app.keyboards.firstMatch.exists ? frame(app.keyboards.firstMatch.frame) : NSNull(),
            "orientation": XCUIDevice.shared.orientation.rawValue, "elements": values,
            "unknown": ["glyph-level truncation", "occlusion beyond AX visibility", "full safe-area mapping", "actual camera", "physical readability", "business correctness", "actual VoiceOver reading order"]]
        let json = XCTAttachment(data: try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
        json.name = "design-\(id)-geometry"; json.lifetime = .keepAlways; add(json)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "design-\(id)-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
    private func frame(_ rect: CGRect) -> [String: Double] {
        ["x": rect.minX, "y": rect.minY, "width": rect.width, "height": rect.height]
    }
}
