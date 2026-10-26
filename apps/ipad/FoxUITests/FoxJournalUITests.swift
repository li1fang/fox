import XCTest
import UIKit

final class FoxJournalUITests: XCTestCase {
    private func launch(photo: Bool = false, denied: Bool = false, invalid: Bool = false,
                        failSave: Bool = false, conflict: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["FOX_UI_TESTING"] = "1"
        app.launchEnvironment["FOX_WEB_URL"] = "http://127.0.0.1:1/unreachable"
        if photo || invalid {
            let data = invalid ? Data("not an image".utf8) : UIGraphicsImageRenderer(size: CGSize(width: 48, height: 36)).pngData { context in
                UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 36))
            }
            app.launchEnvironment["FOX_UI_JOURNAL_PHOTO_DATA"] = data.base64EncodedString()
        }
        if denied { app.launchEnvironment["FOX_UI_JOURNAL_CAMERA"] = "denied" }
        if failSave { app.launchEnvironment["FOX_UI_FAIL_JOURNAL_SAVE_ONCE"] = "1" }
        if conflict { app.launchEnvironment["FOX_UI_JOURNAL_CONFLICT_ONCE"] = "1" }
        app.launchArguments = ["--ui-testing-reset"]
        app.launch()
        XCTAssertTrue(app.buttons["journal-camera"].waitForExistence(timeout: 10))
        return app
    }

    private func note(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "journal-note").firstMatch
    }
    private func record(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journal-record-")).firstMatch
    }
    private func waitSaved(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["journal-saved"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "journal-record-")).count, 1)
    }

    func testPhotoOnlySaveEditAndRelaunchKeepPhoto() {
        let app = launch(photo: true)
        app.buttons["journal-camera"].tap()
        XCTAssertTrue(app.images["journal-draft-photo"].waitForExistence(timeout: 5))
        app.buttons["journal-save"].tap(); waitSaved(app)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(record(app).waitForExistence(timeout: 5))
        record(app).tap()
        XCTAssertTrue(app.images["journal-saved-photo"].waitForExistence(timeout: 5))
        app.buttons["journal-edit"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "journal-edit-note").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Lunch photo, not yet analysed.")
        app.buttons["journal-edit-save"].tap()
        XCTAssertTrue(app.staticTexts["Lunch photo, not yet analysed."].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["journal-revision"].label, "修订 2")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "journal-test-photo-corrected"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.staticTexts["Lunch photo, not yet analysed."].waitForExistence(timeout: 5))
    }

    func testPhotoAndTextSurviveSaveFailureThenRetry() {
        let app = launch(photo: true, failSave: true)
        app.buttons["journal-camera"].tap()
        XCTAssertTrue(app.images["journal-draft-photo"].waitForExistence(timeout: 5))
        note(app).tap(); note(app).typeText("Bought two lamb chops.")
        app.buttons["journal-save"].tap()
        XCTAssertTrue(app.staticTexts["journal-save-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(note(app).value as? String, "Bought two lamb chops.")
        XCTAssertTrue(app.images["journal-draft-photo"].exists)
        app.buttons["journal-save"].tap(); waitSaved(app)
    }

    func testDeniedCameraStillAllowsTextSave() {
        let app = launch(denied: true)
        note(app).tap(); note(app).typeText("A real text-only entry.")
        app.buttons["journal-camera"].tap()
        XCTAssertTrue(app.staticTexts["journal-photo-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(note(app).value as? String, "A real text-only entry.")
        app.buttons["journal-save"].tap(); waitSaved(app)
    }

    func testInvalidPhotoDoesNotDiscardTextOrEnableBlankRecord() {
        let app = launch(invalid: true)
        app.buttons["journal-camera"].tap()
        XCTAssertTrue(app.staticTexts["journal-photo-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["journal-save"].isEnabled)
        note(app).tap(); note(app).typeText("Image failed, text remains.")
        app.buttons["journal-save"].tap(); waitSaved(app)
    }

    func testRevisionConflictRetainsUnsubmittedCorrection() {
        let app = launch(conflict: true)
        note(app).tap(); note(app).typeText("Original entry")
        app.buttons["journal-save"].tap(); waitSaved(app)
        record(app).tap(); app.buttons["journal-edit"].tap()
        let field = app.descendants(matching: .any).matching(identifier: "journal-edit-note").firstMatch
        field.tap(); field.typeText(" - my unsaved correction")
        let entered = field.value as? String
        XCTAssertTrue(entered?.contains("Original entry") == true)
        XCTAssertTrue(entered?.contains(" - my unsaved correction") == true)
        app.buttons["journal-edit-save"].tap()
        XCTAssertTrue(app.staticTexts["journal-edit-error"].waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, entered)
        XCTAssertTrue(app.buttons["journal-reload-latest"].exists)
        app.buttons["journal-reload-latest"].tap()
        let confirmation = app.alerts["放弃当前更正并载入最新版本？"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["取消"].tap()
        XCTAssertEqual(field.value as? String, entered)
        app.buttons["journal-reload-latest"].tap()
        confirmation.buttons["载入最新版本"].tap()
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "另一处已更正"), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["journal-edit-save"].isEnabled)
    }

    func testBackupExportCancellationPreservesUnsubmittedNote() {
        let app = launch()
        note(app).tap(); note(app).typeText("Do not clear this draft.")
        app.buttons["journal-backup"].tap()
        XCTAssertTrue(app.navigationBars["备份与恢复"].waitForExistence(timeout: 5))
        app.buttons["journal-export-backup"].tap()
        let save = app.navigationBars.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["保存", "Save"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertTrue(save.isEnabled)
        let cancel = app.buttons["file-export-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "journal-native-files-export"; screenshot.lifetime = .keepAlways; add(screenshot)
        cancel.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)], timeout: 5), .completed)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: save)], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["备份与恢复"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["备份与恢复"].buttons["完成"].isHittable)
        XCTAssertFalse(app.staticTexts["journal-backup-status"].exists)
        app.navigationBars["备份与恢复"].buttons["完成"].tap()
        XCTAssertTrue(note(app).isHittable)
        XCTAssertEqual(note(app).value as? String, "Do not clear this draft.")
    }

    func testBackupImportCancellationPreservesUnsubmittedNote() {
        let app = launch()
        note(app).tap()
        let inputStarted = ProcessInfo.processInfo.systemUptime
        note(app).typeText("Keep input when import is cancelled.")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - inputStarted, 20, "Text input must not consume an animation-idle timeout")
        app.buttons["journal-backup"].tap()
        app.buttons["journal-import-backup"].tap()
        let cancel = app.buttons["file-import-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cancel)], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["备份与恢复"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["备份与恢复"].buttons["完成"].isHittable)
        XCTAssertFalse(app.staticTexts["journal-backup-status"].exists)
        app.navigationBars["备份与恢复"].buttons["完成"].tap()
        XCTAssertTrue(note(app).isHittable)
        XCTAssertEqual(note(app).value as? String, "Keep input when import is cancelled.")
    }

    func testDeleteRequiresConfirmationAndReturnsToEmptyHome() {
        let app = launch()
        note(app).tap(); note(app).typeText("Disposable test record.")
        app.buttons["journal-save"].tap(); waitSaved(app)
        record(app).tap()
        app.buttons["更多操作"].tap(); app.buttons["删除记录"].tap()
        XCTAssertTrue(app.staticTexts["删除这条记录及全部修订？"].waitForExistence(timeout: 5))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["Disposable test record."].exists)
        app.buttons["更多操作"].tap(); app.buttons["删除记录"].tap()
        app.buttons["删除记录"].tap()
        XCTAssertTrue(app.staticTexts["还没有生活记录"].waitForExistence(timeout: 5))
        XCTAssertFalse(record(app).exists)
    }
}
