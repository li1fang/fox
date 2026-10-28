import FoxTrainingCore
import XCTest
@testable import Fox

@MainActor
final class ActivityEntryTests: XCTestCase {
    private func store() -> TrainingStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = TrainingStore(archiveURL: root.appendingPathComponent("training.json"), diagnosticRoot: root.appendingPathComponent("diagnostics"))
        store.workoutVision.controller.enableReplay(clock: VisionReplayClock())
        addTeardownBlock { await MainActor.run { store.workoutVision.stop() } }
        return store
    }

    func testQuickCurlLeftOnlyCompletesWithoutInventingRight() throws {
        var session = try TrainingSession(plan: TrainingCapabilities.trial(.curl), now: Date())
        try session.startSet(at: Date())
        try session.finishSet(at: Date())
        try session.submit(reps: nil, sideRepetitions: SideRepetitions(left: 11), feedback: [], notes: "", at: Date())
        XCTAssertEqual(session.records.first?.status, "completed")
        XCTAssertEqual(session.records.first?.sideRepetitions?.left, 11)
        XCTAssertNil(session.records.first?.sideRepetitions?.right)
    }

    func testFourActivitiesHaveExplicitCapabilitiesAndKegelNeverStartsCameraOrCapture() throws {
        XCTAssertEqual(TrainingActivity.allCases.count, 4)
        let store = store()
        store.startTrial(.kegel)
        let session = try XCTUnwrap(store.session)
        try session.plan.validate()
        XCTAssertNil(session.exercise.visualObservation)
        XCTAssertEqual(session.exercise.tempo.map(\.phase), ["contract", "relax"])
        XCTAssertFalse(store.usesVision)
        XCTAssertFalse(store.canEnableVision)
        let controller = store.workoutVision.controller
        controller.enableReplay(clock: VisionReplayClock())
        defer { controller.stopCamera() }
        store.workoutVision.preview()
        store.workoutVision.prepare(arm: .left)
        store.setVisionEnabled(true)
        XCTAssertEqual(controller.cameraState, .stopped)
        XCTAssertNil(controller.replayCaptureID)
        XCTAssertFalse(controller.diagnosticCapture.isActive)
        XCTAssertEqual(store.session, session)
        XCTAssertTrue(store.updateSession { try $0.startSet(at: Date()) })
        XCTAssertTrue(store.workoutVision.pause())
        XCTAssertTrue(store.updateSession { try $0.startSet(at: Date()) })
        store.workoutVision.finish()
        XCTAssertEqual(controller.cameraState, .stopped)
        XCTAssertFalse(controller.diagnosticCapture.isActive)
        XCTAssertTrue(store.updateSession { try $0.submit(reps: 3, feedback: [], notes: "", at: Date()) })
        XCTAssertTrue(store.confirmSummary(note: ""))
        let saved = try XCTUnwrap(try LocalTrainingRepository(fileURL: store.fileURL).archive.sessions.last)
        XCTAssertEqual(saved.records.first?.countingMethod, "manual")
        XCTAssertEqual(saved.records.first?.reps, 3)
        XCTAssertNil(saved.records.first?.visualEvidence)
        XCTAssertNil(saved.records.first?.rhythmAssessment)
    }

    func testPristineSwitchStopsPreviewButStartedPracticeQueuesWithoutReplacingFacts() throws {
        let store = store()
        store.startTrial(.curl)
        let controller = store.workoutVision.controller
        controller.enableReplay(clock: VisionReplayClock())
        defer { controller.stopCamera() }
        store.workoutVision.preview()
        let oldCapture = try XCTUnwrap(controller.replayCaptureID)
        let oldID = store.session?.id
        XCTAssertTrue(store.selectActivity(.kegel))
        XCTAssertEqual(store.session?.id, oldID)
        XCTAssertEqual(store.session?.exercise.exerciseId, "kegel")
        XCTAssertEqual(controller.cameraState, .stopped)
        controller.camera.onState?(oldCapture, .running)
        XCTAssertEqual(controller.cameraState, .stopped)
        XCTAssertTrue(store.updateSession { try $0.startSet(at: Date()) })
        let bytes = try Data(contentsOf: store.fileURL), before = store.session
        XCTAssertTrue(store.selectActivity(.latPulldown))
        XCTAssertEqual(store.nextPractice, .latPulldown)
        XCTAssertEqual(store.session, before)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
    }

    func testFormalPlanRemainsUntouchedWhenSelectingAnotherActivity() throws {
        let store = store()
        store.start()
        let before = store.archive, bytes = try Data(contentsOf: store.fileURL)
        XCTAssertTrue(store.selectActivity(.kegel))
        XCTAssertEqual(store.archive, before)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), bytes)
        XCTAssertEqual(store.nextPractice, .kegel)
    }

    func testRightTrialSaveContinueAndSummaryRevisionKeepSidesSeparate() throws {
        let store = store()
        store.startTrial(.curl)
        XCTAssertTrue(store.selectActivity(.curl, arm: .right))
        store.workoutVision.stop()
        XCTAssertEqual(store.session?.exercise.targetSide, .right)
        XCTAssertTrue(store.updateSession {
            try $0.startSet(at: Date()); try $0.finishSet(at: Date())
            try $0.submit(reps: 6, feedback: [], notes: "", at: Date())
            try $0.reviseRecord(id: $0.records[0].id, reps: 7, weight: nil, notes: "corrected")
        })
        XCTAssertTrue(store.confirmSummary(note: "", nextActivity: .curl, arm: .left))
        let archive = try LocalTrainingRepository(fileURL: store.fileURL).archive
        XCTAssertEqual(archive.sessions.count, 2)
        XCTAssertEqual(archive.sessions[0].stage, .confirmed)
        XCTAssertEqual(archive.sessions[0].records[0].status, "completed")
        XCTAssertEqual(archive.sessions[0].records[0].sideRepetitions?.right, 7)
        XCTAssertNil(archive.sessions[0].records[0].sideRepetitions?.left)
        XCTAssertEqual(archive.currentSession?.exercise.targetSide, .left)
        XCTAssertEqual(archive.currentSession?.stage, .ready)
        XCTAssertNil(archive.currentSession?.currentVisualEvidence)
    }

    func testLegacyBilateralRuleAndWrongObservationSideRemainProtected() throws {
        var session = try TrainingSession(plan: TrainingCapabilities.prepared(.starter), now: Date())
        XCTAssertNil(session.exercise.targetSide)
        try session.startSet(at: Date()); try session.finishSet(at: Date())
        try session.submit(reps: nil, sideRepetitions: .init(left: 11), feedback: [], notes: "", at: Date())
        XCTAssertEqual(session.records[0].status, "partial")
        var trial = try TrainingSession(plan: TrainingCapabilities.trial(.curl), now: Date())
        var settings = try XCTUnwrap(trial.exercise.visualObservation)
        settings.arm = .right
        XCTAssertThrowsError(try trial.prepareVisual(settings: settings, configuration: .standard, runtimePolicy: .standard, source: .camera, at: Date()))
        XCTAssertNil(trial.currentVisualEvidence)
        let rightRaise = TrainingCapabilities.trial(.lateralRaise, arm: .right)
        try rightRaise.validate()
        XCTAssertEqual(rightRaise.exercises[0].visualObservation?.arm, .right)
        XCTAssertEqual(rightRaise.exercises[0].targetSide, .right)
        let plan = try TrainingSession(plan: TrainingCapabilities.prepared(.starter), now: Date())
        XCTAssertEqual(TrainingArmChoice.current(.init(attemptID: plan.currentSetAttemptId, arm: .right), session: plan), .right)
    }

    func testImportedSingleSidePlanKeepsItsSideWhenCapabilitiesAreAdded() throws {
        for activity in [TrainingActivity.curl, .lateralRaise] {
            let store = store()
            var plan = TrainingCapabilities.trial(activity, arm: .right)
            plan.isQuickPractice = nil
            plan.exercises[0].visualObservation = nil
            try plan.validate()
            store.savePlan(plan); store.start()
            let session = try XCTUnwrap(store.session, store.errorMessage ?? "")
            XCTAssertEqual(session.exercise.targetSide, .right)
            XCTAssertEqual(session.exercise.visualObservation?.arm, .right)
            XCTAssertEqual(store.archive.plan, plan)
        }
    }

    func testSideCorrectionIsUnavailableWhenAFormalPlanFixesTheSide() throws {
        var plan = TrainingCapabilities.trial(.curl, arm: .right)
        var trial = try TrainingSession(plan: plan, now: Date())
        XCTAssertTrue(TrainingArmChoice.canChange(session: trial))
        try trial.startSet(at: Date())
        XCTAssertFalse(TrainingArmChoice.canChange(session: trial))
        plan.isQuickPractice = nil
        let fixed = try TrainingSession(plan: plan, now: Date())
        XCTAssertFalse(TrainingArmChoice.canChange(session: fixed))
        plan.exercises[0].targetSide = nil
        let bilateral = try TrainingSession(plan: plan, now: Date())
        XCTAssertTrue(TrainingArmChoice.canChange(session: bilateral))
    }

    func testFailedSwitchAndSaveContinueKeepOriginalStateForRetry() throws {
        let store = store(); store.startTrial(.curl)
        let before = store.archive, bytes = try Data(contentsOf: store.fileURL)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        XCTAssertFalse(store.selectActivity(.kegel))
        XCTAssertEqual(store.archive, before)
        try FileManager.default.removeItem(at: store.fileURL)
        try bytes.write(to: store.fileURL)
        XCTAssertTrue(store.updateSession {
            try $0.startSet(at: Date()); try $0.finishSet(at: Date())
            try $0.submit(reps: 5, feedback: [], notes: "", at: Date())
        })
        let summary = store.archive, summaryBytes = try Data(contentsOf: store.fileURL)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
        XCTAssertFalse(store.confirmSummary(note: "", nextActivity: .kegel))
        XCTAssertEqual(store.archive, summary)
        try FileManager.default.removeItem(at: store.fileURL)
        try summaryBytes.write(to: store.fileURL)
        XCTAssertTrue(store.confirmSummary(note: "", nextActivity: .kegel))
        XCTAssertEqual(store.archive.sessions.count, 2)
        XCTAssertEqual(store.archive.sessions.first?.stage, .confirmed)
        XCTAssertEqual(store.session?.exercise.exerciseId, "kegel")
    }

    private final class Driver: SpeechOutputDriver {
        var onEvent: ((String, SpeechPlaybackEvent) -> Void)?
        var cues: [GuidanceCue] = []
        func speak(_ cue: GuidanceCue) -> Bool {
            cues.append(cue); onEvent?(cue.id, .started); onEvent?(cue.id, .finished); return true
        }
        func stop() {}
    }

    func testKegelSpeechAndSquareFollowPlanThenStopWithoutGeneratingActualReps() throws {
        let store = store(); store.startTrial(.kegel)
        let clock = VisionReplayClock(), c = store.workoutVision.controller, driver = Driver()
        c.enableReplay(clock: clock)
        let guidance = GuidanceSession(vision: c, store: store, driver: driver, defaults: nil)
        guidance.setSpeech(true); guidance.setMode(.planned)
        XCTAssertTrue(store.updateSession { try $0.startSet(at: c.wallTime) })
        clock.uptime += 0.01
        guidance.sample()
        XCTAssertEqual(guidance.output.presentation.label, "轻轻收缩")
        let small = guidance.output.presentation.scale
        clock.uptime += 2; guidance.sample()
        XCTAssertGreaterThan(guidance.output.presentation.scale, small)
        clock.uptime += 1.1; guidance.sample()
        XCTAssertEqual(guidance.output.presentation.label, "完全放松")
        XCTAssertTrue(store.workoutVision.pause()); guidance.sample()
        XCTAssertFalse(guidance.output.presentation.isMoving)
        clock.uptime += 10; guidance.sample()
        XCTAssertTrue(store.updateSession { try $0.startSet(at: c.wallTime) })
        clock.uptime += 42; guidance.sample()
        XCTAssertEqual(guidance.output.presentation.label, "计划节奏结束")
        XCTAssertFalse(guidance.output.presentation.isMoving)
        XCTAssertTrue(driver.cues.contains { $0.text == "轻轻收缩" })
        XCTAssertTrue(driver.cues.contains { $0.text == "完全放松" })
        XCTAssertFalse(driver.cues.contains { $0.kind == .count || $0.text.contains("重量") })
        XCTAssertEqual(store.session?.stage, .active)
        XCTAssertNil(store.session?.currentVisualEvidence)
        XCTAssertTrue(store.session?.records.isEmpty == true)
        XCTAssertEqual(c.cameraState, .stopped)
    }
}
