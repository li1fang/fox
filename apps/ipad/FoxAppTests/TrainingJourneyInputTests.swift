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
