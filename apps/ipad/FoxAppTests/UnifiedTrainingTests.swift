import FoxTrainingCore
import XCTest
@testable import Fox

@MainActor
final class UnifiedTrainingTests: XCTestCase {
    func testKnownCapabilitiesResolveOnlyExplicitIDsInNewPlanCopies() throws {
        let original = TrainingPlan.starter
        let resolved = TrainingCapabilities.prepared(original)
        XCTAssertNil(original.exercises[0].visualObservation)
        XCTAssertEqual(resolved.exercises.map { $0.visualObservation?.exercise }, [.curl, .lateralRaise])
        XCTAssertEqual(resolved.exercises.map(\.targetSets), original.exercises.map(\.targetSets))
        XCTAssertEqual(resolved.exercises.map(\.tempo), original.exercises.map(\.tempo))
        try resolved.validate()
        let unknown = Exercise(id: "trx_curl", name: "哑铃弯举", sets: [SetTarget(setIndex: 1)])
        let timed = Exercise(id: "dumbbell_curl", name: "哑铃弯举", sets: [SetTarget(setIndex: 1, duration: 30)])
        XCTAssertNil(TrainingCapabilities.prepared(TrainingPlan(focus: "test", exercises: [unknown])).exercises[0].visualObservation)
        XCTAssertNil(TrainingCapabilities.prepared(TrainingPlan(focus: "test", exercises: [timed])).exercises[0].visualObservation)
        let explicit = try TrainingPlan.realExerciseDay1Draft()
        XCTAssertEqual(TrainingCapabilities.prepared(explicit), explicit)
        for exercise in VisionExercise.allCases {
            let trial = TrainingCapabilities.trial(try XCTUnwrap(TrainingActivity(rawValue: exercise.rawValue)))
            try trial.validate()
            XCTAssertEqual(trial.exercises[0].visualObservation?.exercise, exercise)
            XCTAssertEqual(trial.totalSets, 1)
        }
        var total = original
        total.exercises[0].repetitionBasis = .total
        XCTAssertEqual(TrainingCapabilities.prepared(total).exercises[0], total.exercises[0], "Do not reinterpret an explicit total as per side")
    }

    func testTrialPreservesPlanAndAnExistingSessionIsNeverReplaced() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingStore(archiveURL: root.appendingPathComponent("training.json"), diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        let original = store.archive.plan
        store.startTrial()
        XCTAssertEqual(store.archive.plan, original)
        let session = try XCTUnwrap(store.session)
        XCTAssertEqual(session.plan.totalSets, 1)
        XCTAssertEqual(session.exercise.visualObservation?.exercise, .curl)
        XCTAssertEqual(session.stage, .ready)
        store.startTrial()
        XCTAssertEqual(store.session, session)
        XCTAssertEqual(store.archive.sessions.count, 1)
    }

    func testPreviewAndManualChoiceDoNotStartTimerAndChoiceSurvivesReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "UnifiedTraining-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("training.json")
        let store = TrainingStore(archiveURL: file, diagnosticRoot: root.appendingPathComponent("Diagnostics"), preferences: defaults)
        store.startTrial()
        let session = try XCTUnwrap(store.session)
        let clock = VisionReplayClock(), controller = store.workoutVision.controller
        controller.enableReplay(clock: clock)
        store.workoutVision.preview()
        XCTAssertEqual(controller.cameraState, .running)
        XCTAssertFalse(controller.isCounting)
        XCTAssertNil(store.session?.currentObservationId)
        XCTAssertEqual(store.session, session)
        XCTAssertTrue(store.usesVision)
        store.setVisionEnabled(false)
        XCTAssertFalse(store.usesVision)
        XCTAssertEqual(controller.cameraState, .stopped)
        var expected = session
        var inputs = session.clientState ?? TrainingClientState(); inputs.manual = true
        expected.clientState = inputs
        XCTAssertEqual(store.session, expected, "Only the explicit per-session presentation choice changes; all training facts remain equal")
        let reopened = TrainingStore(archiveURL: file, diagnosticRoot: root.appendingPathComponent("Diagnostics"), preferences: defaults)
        XCTAssertFalse(reopened.usesVision)
        reopened.workoutVision.preview()
        XCTAssertEqual(reopened.workoutVision.controller.cameraState, .stopped)
        reopened.setVisionEnabled(true)
        XCTAssertTrue(reopened.visionRequested)
        reopened.workoutVision.stop()
    }

    func testExistingUnconfiguredActiveSessionAndHistoryAreNotMigrated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("training.json")
        let repo = try LocalTrainingRepository(fileURL: file)
        try repo.start(plan: .starter, at: Date())
        let bytes = try Data(contentsOf: file)
        let before = try LocalTrainingRepository.decoder().decode(TrainingArchive.self, from: bytes)
        let store = TrainingStore(archiveURL: file, diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        store.startTrial()
        XCTAssertEqual(store.archive, before)
        XCTAssertFalse(store.usesVision)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testBackgroundPreviewStopsAndLateCameraCallbackCannotRestartIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingStore(archiveURL: root.appendingPathComponent("training.json"), diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        store.startTrial()
        let controller = store.workoutVision.controller
        controller.enableReplay(clock: VisionReplayClock())
        store.workoutVision.preview()
        let oldID = try XCTUnwrap(controller.replayCaptureID)
        store.workoutVision.stopUnarmedPreview()
        controller.camera.onState?(oldID, .running)
        XCTAssertEqual(controller.cameraState, .stopped)
        XCTAssertNil(controller.replayCaptureID)
        XCTAssertNil(store.session?.currentObservationId)
        XCTAssertEqual(store.session?.stage, .ready)
        store.workoutVision.preview()
        XCTAssertEqual(controller.cameraState, .running)
        XCTAssertNotEqual(controller.replayCaptureID, oldID)
        store.workoutVision.stop()
    }

    func testManualStartedAttemptCannotEnableVisionUntilNextSet() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TrainingStore(archiveURL: root.appendingPathComponent("training.json"), diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        store.start()
        store.workoutVision.controller.enableReplay(clock: VisionReplayClock())
        store.setVisionEnabled(false)
        XCTAssertTrue(store.updateSession { try $0.startSet(at: Date()) })
        XCTAssertTrue(store.workoutVision.pause())
        store.setVisionEnabled(true)
        XCTAssertFalse(store.usesVision, "A manually started attempt must stay manual after pause")
        XCTAssertNil(store.session?.currentVisualEvidence)
        store.workoutVision.finish()
        XCTAssertTrue(store.updateSession { try $0.submit(reps: 5, feedback: [], notes: "", at: Date()) })
        XCTAssertTrue(store.updateSession { try $0.readyAfterRest(at: Date()) })
        store.setVisionEnabled(true)
        XCTAssertTrue(store.usesVision, "The next untouched attempt may enable vision")
        store.workoutVision.stop()
    }

    func testDeniedCameraManualPauseStaysManualAfterReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("training.json")
        let store = TrainingStore(archiveURL: file, diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        store.startTrial()
        let controller = store.workoutVision.controller
        controller.enableReplay(clock: VisionReplayClock())
        store.workoutVision.preview()
        controller.camera.onState?(try XCTUnwrap(controller.replayCaptureID), .denied)
        XCTAssertFalse(store.usesVision)
        XCTAssertTrue(store.updateSession { try $0.startSet(at: Date()) })
        XCTAssertTrue(store.workoutVision.pause())
        XCTAssertFalse(store.usesVision)
        let reopened = TrainingStore(archiveURL: file, diagnosticRoot: root.appendingPathComponent("Diagnostics"))
        XCTAssertFalse(reopened.usesVision)
        XCTAssertTrue(reopened.updateSession { try $0.startSet(at: Date()) })
        XCTAssertEqual(reopened.session?.stage, .active)
        XCTAssertNil(reopened.session?.currentObservationId)
    }
}
