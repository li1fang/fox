import XCTest
import FoxTrainingCore
@testable import Fox

@MainActor
final class ClientSessionTests: XCTestCase {
    func store(writer: ((Data, URL) throws -> Void)? = nil) -> TrainingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClientSessions-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return TrainingStore(archiveURL: root.appendingPathComponent("training.json"), diagnosticRoot: root.appendingPathComponent("diagnostics"), writer: writer)
    }
    func testExplicitPreparationAndAtoBtoARejectOldActionsAndKeepModesDrafts() throws {
        let store = store(), clock = VisionReplayClock()
        store.workoutVision.controller.enableReplay(clock: clock)
        XCTAssertTrue(store.preparePractice(.curl, requestID: UUID()))
        let a = try XCTUnwrap(store.session), oldToken = try XCTUnwrap(store.executionToken)
        XCTAssertEqual(a.executionStart, .notStarted)
        store.setVisionEnabled(false)
        var inputs = TrainingClientState(); inputs.manual = true; inputs.summary = "A summary"
        var feedback = TrainingFeedbackDraft(); feedback.reps = "未确认"; feedback.note = "15kg是愿望"
        inputs.feedback[a.currentSetAttemptId!.uuidString] = feedback
        store.setClientState(inputs, token: oldToken)
        XCTAssertTrue(store.updateSession(token: oldToken) { try $0.startSet(at: Date()) })
        XCTAssertTrue(store.preparePractice(.kegel, requestID: UUID()))
        let b = try XCTUnwrap(store.session), bToken = try XCTUnwrap(store.executionToken)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertFalse(store.updateSession(token: oldToken) { try $0.endEarly(at: Date()) })
        store.stopPresentation(token: oldToken)
        XCTAssertTrue(store.accepts(bToken))
        XCTAssertEqual(store.archive.sessions.first { $0.id == a.id }?.stage, .paused)
        XCTAssertNil(store.archive.sessions.first { $0.id == a.id }?.endedAt)
        XCTAssertTrue(store.activateSession(a.id, requestID: UUID()))
        XCTAssertFalse(store.accepts(oldToken))
        XCTAssertFalse(store.visionRequested)
        XCTAssertEqual(store.clientState.summary, "A summary")
        XCTAssertEqual(store.clientState.feedback[a.currentSetAttemptId!.uuidString]?.reps, "未确认")
        XCTAssertFalse(store.updateSession(token: bToken) { try $0.endEarly(at: Date()) })
        XCTAssertEqual(store.archive.sessions.count, 2)
        let bytes = try Data(contentsOf: store.fileURL)
        let history = try HomeTrainingSnapshot.read(from: store.fileURL)
        XCTAssertEqual(history.sessions.count, 2)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        let reopened = TrainingStore(archiveURL: store.fileURL, diagnosticRoot: store.fileURL.deletingLastPathComponent().appendingPathComponent("other"))
        XCTAssertEqual(reopened.session?.id, a.id)
        XCTAssertFalse(reopened.visionRequested)
        XCTAssertEqual(reopened.clientState.summary, "A summary")
    }
    func testSwitchFailureFreezesAAndRetryKeepsOriginalCutoff() throws {
        var fail = false
        let store = store { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        store.workoutVision.controller.enableReplay(clock: VisionReplayClock())
        XCTAssertTrue(store.preparePractice(.kegel, requestID: UUID()))
        let a = try XCTUnwrap(store.session), token = try XCTUnwrap(store.executionToken)
        XCTAssertTrue(store.updateSession(token: token) { try $0.startSet(at: Date().addingTimeInterval(-10)) })
        let before = try Data(contentsOf: store.fileURL), command = UUID()
        fail = true
        XCTAssertFalse(store.preparePractice(.curl, requestID: command))
        XCTAssertTrue(store.executionBlocked)
        XCTAssertEqual(store.session?.id, a.id)
        XCTAssertEqual(store.session?.stage, .paused)
        let frozen = try XCTUnwrap(store.session?.elapsed(at: Date()))
        XCTAssertEqual(store.session?.elapsed(at: Date().addingTimeInterval(500)), frozen)
        store.checkpoint(token: token)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        XCTAssertEqual(store.archive.sessions.count, 1)
        fail = false
        XCTAssertTrue(store.preparePractice(.curl, requestID: command))
        XCTAssertFalse(store.executionBlocked)
        XCTAssertEqual(store.archive.sessions.first?.accumulatedSeconds, frozen)
        XCTAssertTrue(store.preparePractice(.curl, requestID: command))
        XCTAssertEqual(store.archive.sessions.count, 2)
    }
    func testReenteringSameSuggestionSelectsItsOriginalSession() throws {
        let store = store(), request = UUID()
        store.workoutVision.controller.enableReplay(clock: VisionReplayClock())
        XCTAssertTrue(store.preparePractice(.curl, requestID: request))
        let a = try XCTUnwrap(store.session?.id)
        XCTAssertTrue(store.preparePractice(.kegel, requestID: UUID()))
        XCTAssertNotEqual(store.session?.id, a)
        XCTAssertTrue(store.preparePractice(.curl, requestID: request))
        XCTAssertEqual(store.session?.id, a)
        XCTAssertEqual(store.archive.sessions.count, 2)
    }

    func testFailedSwitchRejectsOtherArchiveWritesUntilOriginalRetry() throws {
        var fail = true
        let store = store { data, url in
            if fail { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        }
        store.workoutVision.controller.enableReplay(clock: VisionReplayClock())
        XCTAssertFalse(store.preparePractice(.kegel, requestID: UUID()))
        let frozen = store.archive
        fail = false
        store.errorMessage = nil // Dismissing an alert must not release the transaction barrier.
        store.savePlan(TrainingCapabilities.trial(.curl))
        store.start()
        XCTAssertEqual(store.archive, frozen)
        XCTAssertTrue(store.executionBlocked)
        XCTAssertTrue(store.retrySwitch())
        XCTAssertEqual(store.session?.exercise.exerciseId, "kegel")
        XCTAssertEqual(store.archive.sessions.count, 1)
    }

    func testQuiesceFailureKeepsBarrierAndRejectsTheOldCameraGeneration() throws {
        let store = store(), clock = VisionReplayClock()
        let controller = store.workoutVision.controller
        controller.enableReplay(clock: clock)
        XCTAssertTrue(store.preparePractice(.curl, requestID: UUID()))
        store.workoutVision.prepare(arm: .left)
        let oldToken = try XCTUnwrap(store.executionToken)
        let began = try XCTUnwrap(controller.onCountingBegan)
        let paused = try XCTUnwrap(controller.onCountingPaused)
        XCTAssertTrue(began())
        clock.uptime += 5
        XCTAssertTrue(store.workoutVision.flush())
        let a = try XCTUnwrap(store.session?.id)
        clock.uptime -= 10 // A non-monotonic final camera snapshot cannot be accepted.
        XCTAssertFalse(store.preparePractice(.kegel, requestID: UUID()))
        XCTAssertTrue(store.executionBlocked)
        XCTAssertFalse(store.accepts(oldToken))
        XCTAssertEqual(store.session?.stage, .paused)
        let frozen = store.session?.elapsed(at: Date())
        XCTAssertEqual(store.session?.elapsed(at: Date().addingTimeInterval(500)), frozen)
        XCTAssertFalse(began()); paused()
        XCTAssertTrue(store.retrySwitch())
        XCTAssertTrue(store.activateSession(a, requestID: UUID()))
        let before = store.archive
        XCTAssertFalse(began()); paused()
        XCTAssertEqual(store.archive, before)
    }

    func testReviewEntryRejectsAnotherAttemptWithoutChangingForeground() throws {
        let store = store()
        store.workoutVision.controller.enableReplay(clock: VisionReplayClock())
        store.start()
        store.setVisionEnabled(false)
        let a = try XCTUnwrap(store.session), first = try XCTUnwrap(a.currentSetAttemptId)
        XCTAssertTrue(store.updateSession { try $0.startSet(at: Date()); try $0.finishSet(at: Date()); try $0.submit(reps: 1, feedback: [], notes: "", at: Date()) })
        XCTAssertTrue(store.updateSession { try $0.readyAfterRest(at: Date()); try $0.startSet(at: Date()); try $0.finishSet(at: Date()) })
        XCTAssertNotEqual(store.session?.currentSetAttemptId, first)
        XCTAssertTrue(store.preparePractice(.kegel, requestID: UUID()))
        let before = store.archive
        XCTAssertFalse(store.enter(.session(a.id, .review, UUID(), expectedAttemptID: first)))
        XCTAssertEqual(store.archive, before)
    }
}
