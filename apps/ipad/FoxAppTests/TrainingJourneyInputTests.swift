import XCTest
import FoxTrainingCore
@testable import Fox

final class TrainingJourneyInputTests: XCTestCase {
    func testObservationChoiceIsBoundToAttemptAndFallsBackToNextExercisePlan() throws {
        var session = try TrainingSession(plan: TrainingPlan.realExerciseDay1Draft(), now: Date())
        let choice = TrainingArmChoice(attemptID: session.currentSetAttemptId, arm: .right)
        XCTAssertEqual(TrainingArmChoice.current(choice, session: session), .right)
        for index in 0..<2 {
            if index > 0 { try session.readyAfterRest(at: Date()) }
            try session.startSet(at: Date())
            try session.finishSet(at: Date())
            try session.submit(reps: 2, feedback: [], notes: "", at: Date())
            XCTAssertEqual(TrainingArmChoice.current(choice, session: session), index == 0 ? .left : .right)
        }
    }
    func testPlanTargetTextPreservesPerSideAndTimedSemantics() {
        XCTAssertEqual(TrainingPlanOutline.targetText(SetTarget(setIndex: 1, reps: 5), basis: .perSide), "5 次 / 侧")
        XCTAssertEqual(TrainingPlanOutline.targetText(SetTarget(setIndex: 2, reps: 8, weight: 2.5), basis: .perSide), "8 次 / 侧")
        XCTAssertEqual(TrainingPlanOutline.targetText(SetTarget(setIndex: 1, reps: 5), basis: .total), "5 次")
        XCTAssertEqual(TrainingPlanOutline.targetText(SetTarget(setIndex: 1, duration: 30), basis: nil), "00:30")
    }
    func testSharedActionGuidesCoverSquatAndExistingSideCurlWithoutEnablingAlgorithms() throws {
        let squat=try XCTUnwrap(ActionGuide.forExercise("bodyweight_squat"))
        let curl=try XCTUnwrap(ActionGuide.forExercise("dumbbell_curl"))
        XCTAssertEqual(squat.diagram,.squatSide);XCTAssertEqual(curl.diagram,.curlSide)
        XCTAssertTrue(squat.camera.contains("髋、膝、踝"));XCTAssertTrue(curl.camera.contains("肩、肘、腕"))
        XCTAssertNil(ActionGuide.forExercise("unknown"))
    }
    @MainActor func testTrialPreferenceIsOffByDefaultAndDoesNotAdmitCurl() throws {
        let suite="FoxTrial-\(UUID())",defaults=try XCTUnwrap(UserDefaults(suiteName:suite))
        defer {defaults.removePersistentDomain(forName:suite)}
        let file=FileManager.default.temporaryDirectory.appendingPathComponent("FoxTrial-\(UUID())/training.json")
        let store=TrainingStore(archiveURL:file,preferences:defaults,assistedDevelopmentEnabled:false,admittedCountOnlyActions:[])
        XCTAssertFalse(store.canChooseSquat);XCTAssertFalse(store.allowsCountOnly(.curl))
        defaults.set(true,forKey:CountOnlyAvailability.trialPreferenceKey)
        XCTAssertTrue(store.canChooseSquat);XCTAssertEqual(store.admittedSquatStrategyID,CountOnlyAvailability.squatStrategyID)
        XCTAssertFalse(store.allowsCountOnly(.curl))
        defaults.set(false,forKey:CountOnlyAvailability.trialPreferenceKey)
        XCTAssertFalse(store.canChooseSquat)
    }
    func testUITestPreferenceDomainIsIsolatedPersistentAndResettable() throws {
        let productionName="FoxPreferenceProduction-\(UUID())", testName="FoxPreferenceUI-\(UUID())"
        let production=try XCTUnwrap(UserDefaults(suiteName:productionName))
        defer { production.removePersistentDomain(forName:productionName); production.removePersistentDomain(forName:testName) }
        let key=CountOnlyAvailability.trialPreferenceKey
        production.set(false,forKey:key)
        let first=FoxPreferenceDomain.resolve(isUITesting:true,production:production,testSuiteName:testName)
        first.set(true,forKey:key)
        XCTAssertFalse(production.bool(forKey:key))
        let reopened=FoxPreferenceDomain.resolve(isUITesting:true,production:production,testSuiteName:testName)
        XCTAssertTrue(reopened.bool(forKey:key))
        FoxPreferenceDomain.resetIfRequested(isUITesting:true,arguments:["--ui-testing-reset"],testSuiteName:testName)
        XCTAssertNil(reopened.object(forKey:key))
        XCTAssertEqual(production.object(forKey:key) as? Bool,false)
        production.set(true,forKey:key)
        FoxPreferenceDomain.resetIfRequested(isUITesting:false,arguments:["--ui-testing-reset"],testSuiteName:productionName)
        XCTAssertTrue(production.bool(forKey:key))
        XCTAssertTrue(FoxPreferenceDomain.resolve(isUITesting:false,production:production,testSuiteName:testName).bool(forKey:key))
    }
    func testUnknownCountOnlyChangesAfterExplicitStep() {
        XCTAssertFalse(TrainingCountInput.canConfirm([""]))
        XCTAssertNil(TrainingCountInput.adjusted("", by: -1))
        XCTAssertEqual(TrainingCountInput.adjusted("", by: 1), "1")
        XCTAssertEqual(TrainingCountInput.adjusted("1", by: -1), "0")
        XCTAssertTrue(TrainingCountInput.canConfirm(["0"]))
    }
    func testCountBoundsAndInvalidSideNeverSilentlyBecomeUnknown() {
        XCTAssertNil(TrainingCountInput.adjusted("1000", by: 1))
        XCTAssertNil(TrainingCountInput.adjusted("0", by: -1))
        XCTAssertNil(TrainingCountInput.adjusted("abc", by: 1))
        XCTAssertTrue(TrainingCountInput.canConfirm(["2", ""]))
        for value in ["-1", "1.5", "abc", "1001"] {
            XCTAssertFalse(TrainingCountInput.canConfirm(["2", value]))
        }
        XCTAssertFalse(TrainingCountInput.canConfirm(["", ""]))
    }
}
