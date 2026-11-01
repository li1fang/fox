import XCTest
import UIKit

final class FoxCountOnlyUITests: XCTestCase {
    func testPhoneSquatCountOnlyUnknownAndZeroSurviveReopenAcrossRotation() { story(isPad: false) }
    func testPadSquatCountOnlyUnknownAndZeroSurviveReopenAcrossRotation() { story(isPad: true) }

    private func visible(_ element: XCUIElement, in app: XCUIApplication, scroll: XCUIElement? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout:5),file:file,line:line)
        let owner=app.scrollViews.containing(.any,identifier:element.identifier).firstMatch
        let scoped=scroll != nil || owner.exists
        let target=scroll ?? (owner.exists ? owner:app)
        func viewport() -> CGRect {
            var bounds=app.windows.firstMatch.frame
            if scoped {
                bounds=bounds.intersection(target.frame)
                let bar=app.navigationBars.firstMatch
                if bar.exists && bar.isHittable && bar.frame.intersects(bounds) {
                    let top=max(bounds.minY,bar.frame.maxY)
                    bounds=CGRect(x:bounds.minX,y:top,width:bounds.width,height:max(0,bounds.maxY-top))
                }
            }
            return bounds
        }
        for _ in 0..<10 {
            if element.isHittable && !element.frame.isEmpty && viewport().contains(element.frame) {break}
            let bounds=viewport()
            XCTAssertGreaterThan(bounds.height,0,"An actual scrolling viewport is required",file:file,line:line)
            let x=bounds.midX,distance=min(100,bounds.height*0.25)
            let down=element.frame.midY<bounds.midY
            let y=bounds.midY+(down ? -distance/2:distance/2)
            let start=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:y))
            let end=app.coordinate(withNormalizedOffset:.zero).withOffset(CGVector(dx:x,dy:y+(down ? distance:-distance)))
            start.press(forDuration:0.05,thenDragTo:end)
        }
        if !element.isHittable || element.frame.isEmpty || !viewport().contains(element.frame) {
            print("FOX_COUNT_ONLY_VISIBILITY_FAILURE \(element.identifier) frame=\(element.frame) viewport=\(viewport())\n\(app.debugDescription)")
            let failure=XCTAttachment(screenshot:XCUIScreen.main.screenshot());failure.name="count-only-visibility-failure";failure.lifetime = .keepAlways;add(failure)
        }
        XCTAssertTrue(element.isHittable,"\(element.identifier) must be reachable",file:file,line:line)
        XCTAssertFalse(element.frame.isEmpty,file:file,line:line)
        XCTAssertTrue(viewport().contains(element.frame),"\(element.identifier) frame \(element.frame) must fit in actual viewport \(viewport())",file:file,line:line)
    }
    private func rotate(_ orientation: UIDeviceOrientation, app: XCUIApplication) {
        XCUIDevice.shared.orientation=orientation
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in
            let frame=app.windows.firstMatch.frame
            return orientation == .portrait ? frame.height>frame.width : frame.width>frame.height
        },object:nil)],timeout:8),.completed)
    }
    private func story(isPad: Bool) {
        continueAfterFailure=false
        let app=XCUIApplication()
        app.launchEnvironment=["FOX_UI_TESTING":"1","FOX_POSE_FIXTURE":"no_person"]
        app.launchArguments=["--ui-testing-reset"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let trialSwitch=app.switches["home-squat-trial-toggle"]
        visible(trialSwitch,in:app)
        XCTAssertEqual(trialSwitch.value as? String,"0")
        XCTAssertFalse(app.buttons["home-prepare-squat-assisted"].exists)
        trialSwitch.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in trialSwitch.value as? String == "1"},object:nil)],timeout:5),.completed)
        for zero in [false,true] {
            visible(app.buttons["home-prepare-squat-assisted"],in:app)
            app.buttons["home-prepare-squat-assisted"].tap()
            visible(app.buttons["begin-set"],in:app)
            XCTAssertFalse(app.switches["training-assisted-curl-mode"].exists)
            app.buttons["phone-training-details"].tap()
            let side=app.segmentedControls["squat-near-side"].buttons["右侧"]
            visible(side,in:app);side.tap()
            XCTAssertTrue(side.isEnabled,"The fixed near-side selector must be available before the set")
            let selected=XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in side.isSelected},object:nil)],timeout:5)
            if selected != .completed {
                print("FOX_COUNT_ONLY_SELECTION_FAILURE \(app.debugDescription)")
                let failure=XCTAttachment(screenshot:XCUIScreen.main.screenshot());failure.name="count-only-selection-failure";failure.lifetime = .keepAlways;add(failure)
            }
            XCTAssertEqual(selected,.completed,"Right near-side choice must actually be selected")
            XCTAssertFalse(app.buttons["计划节奏"].exists)
            app.buttons["phone-training-details-done"].tap()
            for orientation in [UIDeviceOrientation.portrait,.landscapeLeft] {
                rotate(orientation,app:app)
                visible(app.buttons["begin-set"],in:app);visible(app.buttons["phone-training-details"],in:app)
                XCTAssertTrue(app.staticTexts["workout-task-detail"].label.contains("侧面较宽画面"))
            }
            app.buttons["begin-set"].tap()
            for orientation in [UIDeviceOrientation.portrait,.landscapeLeft] {
                rotate(orientation,app:app)
                visible(app.buttons["pause-set"],in:app);visible(app.buttons["complete-set"],in:app)
                XCTAssertEqual(app.staticTexts["workout-automatic-count"].label,"—")
                XCTAssertTrue(app.staticTexts["workout-task-detail"].label.contains("阶段与节奏未提供"))
                XCTAssertFalse(app.buttons["training-manual-continue"].exists)
                let phase=app.staticTexts["observed-tempo-phase"]
                if phase.exists {XCTAssertFalse(phase.label.contains("计划"));XCTAssertFalse(phase.label.contains("0秒"))}
            }
            let time=app.staticTexts["set-elapsed"].label
            XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in
                app.buttons["pause-set"].exists && app.staticTexts["set-elapsed"].label != time
            },object:nil)],timeout:5),.completed,"Missing observation must not pause the training clock")
            app.buttons["complete-set"].tap()
            rotate(zero ? .portrait:.landscapeLeft,app:app)
            let count=app.textFields["actual-reps"]
            XCTAssertTrue(count.waitForExistence(timeout:5))
            XCTAssertTrue((count.value as? String) == "" || (count.value as? String) == count.placeholderValue)
            XCTAssertFalse(app.buttons["submit-feedback"].isEnabled)
            XCTAssertTrue(app.staticTexts["feedback-assisted-observation"].label.contains("暂无有效观察"))
            XCTAssertFalse(app.buttons["trial-confirm-observation"].isEnabled)
            let observation=app.staticTexts["feedback-assisted-observation"].label
            if !observation.contains("近侧：右侧") {
                print("FOX_COUNT_ONLY_SIDE_FAILURE \(observation)\n\(app.debugDescription)")
                let failure=XCTAttachment(screenshot:XCUIScreen.main.screenshot());failure.name="count-only-side-failure";failure.lifetime = .keepAlways;add(failure)
            }
            XCTAssertTrue(observation.contains("近侧：右侧"),"Actual feedback: \(observation)")
            if zero {
                visible(app.buttons["trial-correct-count"],in:app);app.buttons["trial-correct-count"].tap()
                visible(count,in:app);count.tap();let start=ProcessInfo.processInfo.systemUptime;count.typeText("0")
                XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,20)
                if isPad {
                    let dismiss=app.buttons["feedback-dismiss-keyboard"]
                    visible(dismiss,in:app);dismiss.tap()
                    let keyboardGone=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.keyboards.firstMatch)
                    XCTAssertEqual(XCTWaiter.wait(for:[keyboardGone],timeout:5),.completed)
                    XCTAssertEqual(count.value as? String,"0")
                } else {
                    app.dismissNumericKeyboardPopover()
                    if app.buttons["feedback-dismiss-keyboard"].exists {app.buttons["feedback-dismiss-keyboard"].tap()}
                }
                visible(app.buttons["submit-feedback"],in:app);XCTAssertTrue(app.buttons["submit-feedback"].isEnabled)
                app.buttons["submit-feedback"].tap()
            } else {
                visible(app.buttons["trial-leave-unconfirmed"],in:app);app.buttons["trial-leave-unconfirmed"].tap()
                visible(app.buttons["submit-feedback"],in:app);XCTAssertTrue(app.buttons["submit-feedback"].isEnabled)
                app.buttons["submit-feedback"].tap()
            }
            visible(app.buttons["confirm-summary"],in:app);app.buttons["confirm-summary"].tap()
            visible(app.staticTexts["training-saved-receipt"],in:app)
            app.buttons["view-saved-training"].tap()
            verifyRecord(app,zero:zero)
            app.buttons["关闭"].tap();app.buttons["training-saved-home"].tap()
            app.terminate();app.launchArguments=[];app.launch()
            let latest=app.openReadOnlyTrainingHistory().firstMatch
            visible(latest,in:app);latest.tap()
            rotate(.portrait,app:app);verifyRecord(app,zero:zero)
            app.navigationBars["训练档案"].buttons["完成"].tap()
            app.navigationBars["训练记录"].buttons["完成"].tap()
            visible(app.buttons["home-prepare-curl"],in:app);app.buttons["home-prepare-curl"].tap()
            visible(app.buttons["begin-set"],in:app)
            XCTAssertFalse(app.switches["training-assisted-curl-mode"].exists)
            XCTAssertTrue(app.buttons["training-activity-picker"].label.contains("弯举"))
            app.buttons["training-home"].tap()
        }
        visible(trialSwitch,in:app);trialSwitch.coordinate(withNormalizedOffset:CGVector(dx:0.95,dy:0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:NSPredicate {_,_ in trialSwitch.value as? String == "0"},object:nil)],timeout:5),.completed)
        XCTAssertFalse(app.buttons["home-prepare-squat-assisted"].exists)
    }
    private func verifyRecord(_ app: XCUIApplication,zero:Bool) {
        let detail=app.scrollViews["record-detail"].exists ? app.scrollViews["record-detail"] : app.scrollViews["home-training-detail"]
        XCTAssertTrue(detail.waitForExistence(timeout:5))
        visible(detail.staticTexts[zero ? "0 次":"次数未确认"],in:app,scroll:detail)
        visible(detail.staticTexts["saved-assisted-observation"],in:app,scroll:detail)
        XCTAssertTrue(app.staticTexts["saved-assisted-observation"].label.contains("近侧：右侧"))
        visible(detail.staticTexts["阶段、节奏与动作质量：未提供"],in:app,scroll:detail)
        XCTAssertTrue(app.staticTexts[zero ? "0 次":"次数未确认"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@","下放阈值段：")).firstMatch.exists)
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name=zero ? "count-only-manual-zero":"count-only-manual-unknown";shot.lifetime = .keepAlways;add(shot)
    }
}
