import Foundation
import XCTest
@testable import FoxTrainingCore

final class MotionStrategyTests: XCTestCase {
    func testThreeStrategiesDescribeCurrentImplementationWithoutDuplicatedThresholds() throws {
        let strategies = try VisionExercise.allCases.map { try MotionStrategy.load($0) }
        XCTAssertEqual(Set(strategies.map(\.id)).count, 3)
        for strategy in strategies {
            try strategy.validate()
            XCTAssertEqual(strategy.algorithm, strategy.exercise.algorithm(runtimePolicy: .standard))
            XCTAssertEqual(strategy.bodyView, strategy.exercise.recommendedBodyView)
            XCTAssertEqual(strategy.preparationJoints, ["selected.shoulder", "selected.elbow"])
            XCTAssertFalse(strategy.phase.fullEccentricComparison)
            XCTAssertEqual(strategy.parameters.profile, strategy.exercise.rawValue)
            XCTAssertFalse(strategy.parameters.configuration.isEmpty)
        }
        XCTAssertEqual(try MotionStrategy.load(.curl).counting.commit, "completed_cycle")
        XCTAssertEqual(try MotionStrategy.load(.lateralRaise).counting.commit, "completed_cycle")
        let lat = try MotionStrategy.load(.latPulldown)
        XCTAssertEqual(lat.counting.commit, "contracted_endpoint")
        XCTAssertEqual(lat.phase.publication, "following_accepted_peak")
        XCTAssertEqual(lat.phase.lastRepetition, "excluded")
    }

    func testUnknownVersionAndContradictorySemanticsAreRejected() throws {
        let bytes = try JSONEncoder().encode(MotionStrategy.load(.latPulldown))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for change in ["schema", "version", "commit"] {
            var value = original
            if change == "schema" { value["schema"] = "future" }
            if change == "version" { value["version"] = 99 }
            if change == "commit" { var counting = value["counting"] as! [String: Any]; counting["commit"] = "completed_cycle"; value["counting"] = counting }
            let strategy = try JSONDecoder().decode(MotionStrategy.self, from: JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try strategy.validate())
        }
    }

    func testPreparationContractMatchesActualGateWithoutWristOrFullBody() throws {
        for side in ArmSide.allCases {
            var frame = LatPulldownTests.frame(150, at: 0, side: side)
            frame.people[0].points = frame.people[0].points.filter { [side.joints[0], side.joints[1]].contains($0.key) }
            XCTAssertTrue(PoseSubjectSelector.isReady(frame, side: side))
            for exercise in VisionExercise.allCases {
                XCTAssertEqual(try MotionStrategy.load(exercise).preparationJoints.count, frame.people[0].points.count)
                XCTAssertNotEqual(PoseGeometry.inspect(frame, side: side, exercise: exercise).quality, .valid)
            }
        }
    }

    func testLegacyActionsDoNotCommitAtPeakAndKeepPhaseEvidenceAfterReturn() throws {
        for exercise in [VisionExercise.curl, .lateralRaise] {
            var tracker = CurlTracker(side: .left, exercise: exercise, runtimePolicy: .standard)
            let angles = exercise == .curl ? [160.0,160,160,160,160,140,120,100,80,55,55,55,55,75,100,120,140,160,160,160,160,160] :
                [10.0,10,10,10,10,25,40,55,70,85,85,85,85,70,55,40,25,10,10,10,10,10]
            for (index, angle) in angles.enumerated() {
                let r = angle * .pi / 180
                let points: [PoseJoint: PosePoint] = exercise == .curl ? [
                    .leftShoulder: PosePoint(x: 0.45, y: 0.8), .leftElbow: PosePoint(x: 0.45, y: 0.55),
                    .leftWrist: PosePoint(x: 0.45 + sin(r) * 0.22 * 720 / 1280, y: 0.55 + cos(r) * 0.22)
                ] : [.leftShoulder: PosePoint(x: 0.5, y: 0.65), .leftHip: PosePoint(x: 0.5, y: 0.35),
                     .leftElbow: PosePoint(x: 0.5 - sin(r) * 0.14 * 720 / 1280, y: 0.65 - cos(r) * 0.14)]
                tracker.process(PoseFrame(timestamp: Double(index) * 0.1, width: 1280, height: 720, people: [BodyPose(points: points)]))
                if index == 12 { XCTAssertEqual(tracker.repetitions.count, 0) }
            }
            XCTAssertEqual(tracker.repetitions.count, 1)
            XCTAssertNotNil(tracker.repetitions.first?.lowerSeconds)
            XCTAssertNil(tracker.repetitions.first?.precedingReturn)
        }
    }
}
