import XCTest
@testable import FoxTrainingCore

final class LateralTorsoReferenceTests: XCTestCase {
    private let angles = [10.0,10,10,10,10,25,40,55,70,85,85,85,85,70,55,40,25,10,10,10,10,10]
    private func frame(_ angle: Double, at t: Double, side: ArmSide = .left, missing: Bool = true) -> PoseFrame {
        let s = side == .left ? 0.4 : 0.6, other = side == .left ? 0.6 : 0.4
        let r = angle * .pi / 180, sign = side == .left ? -1.0 : 1.0
        var points: [PoseJoint: PosePoint] = [
            side.joints[0]: .init(x: s, y: 0.8), side.joints[1]: .init(x: s + sign * sin(r) * 0.15, y: 0.8 - cos(r) * 0.15),
            side.joints[2]: .init(x: s + sign * sin(r) * 0.25, y: 0.8 - cos(r) * 0.25),
            side == .left ? .rightShoulder : .leftShoulder: .init(x: other, y: 0.8),
            side == .left ? .rightHip : .leftHip: .init(x: other, y: 0.4)
        ]
        if !missing { points[side == .left ? .leftHip : .rightHip] = .init(x: s, y: 0.4) }
        return .init(timestamp: t, width: 1000, height: 1000, people: [.init(points: points)])
    }
    func testFreshOppositeTorsoCountsBothSidesAndNumericReplayIsExact() throws {
        for side in ArmSide.allCases {
            var policy = PoseRuntimePolicy.standard; policy.lateralTorsoReference = .freshOpposite
            var tracker = CurlTracker(side: side, exercise: .lateralRaise, runtimePolicy: policy)
            for (i, angle) in angles.enumerated() { tracker.process(frame(angle, at: Double(i)/10, side: side)) }
            XCTAssertEqual(tracker.repetitions.count, 1)
            XCTAssertGreaterThan(tracker.repetitions.first?.geometryFallbackFrames ?? 0, 0)
            let report = VisionTrial(startedAt: .distantPast, endedAt: .distantFuture, device: "synthetic", appVersion: "candidate",
                visionRevision: 1, source: .fixture, camera: "front", arm: side, repetitions: tracker.repetitions,
                manualAdjustment: 0, referenceCount: nil, metrics: .init(), notes: "", exercise: .lateralRaise,
                counterDiagnostics: tracker.diagnostics)
            XCTAssertEqual(report.algorithm, "lateral_raise_2d_v4")
            XCTAssertEqual(try PoseReplay.replay(report).repetitions, tracker.repetitions)
        }
    }
    func testLegacyPolicyKeepsMissingHipSemanticsAndAlgorithm() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PoseRuntimePolicy.standard)) as? [String: Any])
        object.removeValue(forKey: "lateralTorsoReference"); object.removeValue(forKey: "maximumTorsoObliquityDegrees")
        let old = try JSONDecoder().decode(PoseRuntimePolicy.self, from: JSONSerialization.data(withJSONObject: object))
        var tracker = CurlTracker(side: .left, exercise: .lateralRaise, runtimePolicy: old)
        for (i, angle) in angles.enumerated() { tracker.process(frame(angle, at: Double(i)/10)) }
        XCTAssertEqual(tracker.repetitions.count, 0)
        XCTAssertEqual(VisionExercise.lateralRaise.algorithm(runtimePolicy: old), "lateral_raise_2d_v3")
    }
    func testNoFreshReferenceMissingArmOtherSubjectOrDegenerateTorsoCannotBeRescued() {
        var policy = PoseRuntimePolicy.standard; policy.lateralTorsoReference = .freshOpposite
        for failure in ["both_hips", "other_shoulder", "arm", "degenerate", "oblique", "multiple"] {
            var pose = frame(85, at: 0)
            switch failure {
            case "both_hips": pose.people[0].points.removeValue(forKey: .rightHip)
            case "other_shoulder": pose.people[0].points[.rightShoulder]?.confidence = 0.1
            case "arm": pose.people[0].points[.leftElbow]?.confidence = 0.1
            case "degenerate": pose.people[0].points[.rightHip] = pose.people[0].points[.rightShoulder]
            case "oblique": pose.people[0].points[.rightHip] = .init(x: 0.95, y: 0.7)
            default: pose.people.append(pose.people[0])
            }
            XCTAssertNotEqual(PoseGeometry.inspect(pose, side: .left, exercise: .lateralRaise, runtimePolicy: policy).quality, .valid, failure)
        }
        var curl = frame(85, at: 0)
        curl.people[0].points.removeValue(forKey: .leftWrist)
        XCTAssertNotEqual(PoseGeometry.inspect(curl, side: .left, exercise: .curl, runtimePolicy: policy).quality, .valid)
    }
    func testFallbackStillNeedsFullCycleAndObservedPeak() {
        var policy = PoseRuntimePolicy.standard; policy.lateralTorsoReference = .freshOpposite
        for values in [Array(repeating: 85.0, count: 30), [10,10,10,10,10,25,40,55,40,25,10,10,10],
                       [10,10,10,10,10,40,85,40,10,10,10]] {
            var tracker = CurlTracker(side: .left, exercise: .lateralRaise, runtimePolicy: policy)
            for (i, angle) in values.enumerated() { tracker.process(frame(angle, at: Double(i)/10)) }
            XCTAssertEqual(tracker.repetitions.count, 0)
        }
    }
    func testFreshSameSideHipIsPreferredAndDoesNotMarkFallback() throws {
        var policy = PoseRuntimePolicy.standard; policy.lateralTorsoReference = .freshOpposite
        let reading = PoseGeometry.inspect(frame(85, at: 0, missing: false), side: .left, exercise: .lateralRaise, runtimePolicy: policy)
        XCTAssertEqual(try XCTUnwrap(reading.angle), 85, accuracy: 0.001)
        XCTAssertFalse(reading.usedTorsoFallback)
        var pose = frame(85, at: 0, missing: false)
        pose.people[0].points[.leftHip] = pose.people[0].points[.leftShoulder]
        XCTAssertNotEqual(PoseGeometry.inspect(pose, side: .left, exercise: .lateralRaise, runtimePolicy: policy).quality, .valid)
    }
}
