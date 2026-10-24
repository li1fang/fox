import Foundation
import XCTest
@testable import FoxTrainingCore

final class LateralRaiseTests: XCTestCase {
    private let cycle = [10.0, 10, 10, 10, 10, 25, 40, 55, 70, 85, 85, 85, 85, 70, 55, 40, 25, 10, 10, 10, 10, 10]

    private func frame(_ angle: Double, at time: Double, side: ArmSide = .left,
                       width: Double = 720, height: Double = 1280, rotation: Double = 0) -> PoseFrame {
        let sign = side == .left ? -1.0 : 1.0
        let radians = angle * .pi / 180
        let shoulder = (x: 0.5, y: 0.65)
        func point(_ x: Double, _ y: Double) -> PosePoint {
            let r = rotation * .pi / 180
            let px = x * height, py = y * height
            return PosePoint(x: shoulder.x + (px * cos(r) - py * sin(r)) / width,
                             y: shoulder.y + (px * sin(r) + py * cos(r)) / height)
        }
        return PoseFrame(timestamp: time, width: width, height: height, people: [BodyPose(points: [
            side.joints[0]: PosePoint(x: shoulder.x, y: shoulder.y),
            side.joints[1]: point(sign * sin(radians) * 0.14, -cos(radians) * 0.14),
            side.joints[2]: point(sign * sin(radians) * 0.24, -cos(radians) * 0.24),
            side == .left ? .leftHip : .rightHip: point(0, -0.30)
        ])])
    }

    private func feed(_ angles: [Double], to tracker: inout CurlTracker, start: Double = 0) {
        for (i, angle) in angles.enumerated() { tracker.process(frame(angle, at: start + Double(i) * 0.1, side: tracker.side)) }
    }

    func testShoulderAngleUsesTorsoNotImageVerticalAndPixelAspect() throws {
        for side in ArmSide.allCases {
            for dimensions in [(720.0, 1280.0), (1280.0, 720.0)] {
                for rotation in [-25.0, 0, 25] {
                    let reading = PoseGeometry.inspect(frame(80, at: 0, side: side, width: dimensions.0, height: dimensions.1, rotation: rotation), side: side, exercise: .lateralRaise)
                    XCTAssertEqual(reading.quality, .valid)
                    XCTAssertEqual(try XCTUnwrap(reading.angle), 80, accuracy: 0.001)
                }
            }
        }
    }

    func testFullCycleBothSelectedArmsAndPhaseDurations() {
        for side in ArmSide.allCases {
            var tracker = CurlTracker(side: side, exercise: .lateralRaise)
            feed(cycle, to: &tracker)
            XCTAssertEqual(tracker.repetitions.count, 1)
            XCTAssertGreaterThanOrEqual(tracker.repetitions.first?.liftSeconds ?? 0, 0.2 - 0.000001)
            XCTAssertGreaterThanOrEqual(tracker.repetitions.first?.lowerSeconds ?? 0, 0.2 - 0.000001)
            XCTAssertGreaterThan(tracker.repetitions.first?.holdSeconds ?? 0, 0)
            feed(cycle, to: &tracker, start: 2.2)
            XCTAssertEqual(tracker.repetitions.count, 2)
        }
    }

    func testStaticHalfRangeJitterInstantJumpAndStartingAtTopDoNotCount() {
        for angles in [Array(repeating: 10.0, count: 40), Array(repeating: 85.0, count: 40),
                       [10, 10, 10, 15, 21, 19, 22, 10], [10, 10, 10, 40, 55, 40, 10, 10, 10],
                       [10, 10, 10, 85, 85, 85, 10, 10, 10], [85, 85, 85, 55, 10, 10, 10]] {
            var tracker = CurlTracker(side: .left, exercise: .lateralRaise)
            feed(angles, to: &tracker)
            XCTAssertEqual(tracker.repetitions.count, 0)
        }
    }

    func testMissingHipAndDegenerateTorsoRejectButWristIsOptional() {
        for joint in [PoseJoint.leftHip] {
            var pose = frame(85, at: 0)
            pose.people[0].points.removeValue(forKey: joint)
            XCTAssertEqual(PoseGeometry.inspect(pose, side: .left, exercise: .lateralRaise).quality, .lowConfidence)
        }
        var withoutWrist = frame(85, at: 0)
        withoutWrist.people[0].points.removeValue(forKey: .leftWrist)
        XCTAssertEqual(PoseGeometry.inspect(withoutWrist, side: .left, exercise: .lateralRaise).quality, .valid)
        XCTAssertEqual(PoseGeometry.inspect(withoutWrist, side: .left, exercise: .lateralRaise, configuration: .legacy).quality, .lowConfidence)
        var pose = frame(85, at: 0)
        pose.people[0].points[.leftHip] = pose.people[0].points[.leftShoulder]
        XCTAssertEqual(PoseGeometry.inspect(pose, side: .left, exercise: .lateralRaise).quality, .lowConfidence)
        pose = frame(85, at: 0)
        pose.people[0].points[.leftHip]?.confidence = 0.2
        XCTAssertEqual(PoseGeometry.inspect(pose, side: .left, exercise: .lateralRaise).quality, .lowConfidence)
    }

    func testInterruptedCycleNeverCompletesAcrossOcclusionGapOrPause() {
        for failure in ["none", "multiple", "hip", "gap", "pause", "jump"] {
            var tracker = CurlTracker(side: .left, exercise: .lateralRaise)
            feed(Array(cycle.prefix(13)), to: &tracker)
            var invalid = frame(85, at: failure == "gap" ? 2 : 1.3)
            if failure == "none" { invalid.people = [] }
            if failure == "multiple" { invalid.people.append(invalid.people[0]) }
            if failure == "hip" { invalid.people[0].points.removeValue(forKey: .leftHip) }
            if failure == "pause" { tracker.interrupt() }
            if failure == "jump" { invalid.people[0].points[.leftShoulder]?.x += 0.3 }
            tracker.process(invalid)
            feed([70, 55, 40, 10, 10, 10, 10], to: &tracker, start: 2.1)
            XCTAssertEqual(tracker.repetitions.count, 0)
            feed(cycle, to: &tracker, start: 3)
            XCTAssertEqual(tracker.repetitions.count, 1)
        }
    }

    func testNoAutomaticArmSwitchAndDuplicateTimeIgnored() {
        var tracker = CurlTracker(side: .right, exercise: .lateralRaise)
        for (i, angle) in cycle.enumerated() { tracker.process(frame(angle, at: Double(i) * 0.1)) }
        XCTAssertEqual(tracker.repetitions.count, 0)
        feed(cycle, to: &tracker, start: 3)
        let before = tracker.repetitions
        feed(cycle, to: &tracker, start: 3)
        XCTAssertEqual(tracker.repetitions, before)
        XCTAssertEqual(before.count, 1)
    }

    func testContextUsesSelectedExerciseQuality() {
        var pose = frame(85, at: 0)
        pose.people[0].points.removeValue(forKey: .leftHip)
        var recorder = VisionContextRecorder()
        recorder.record(elapsedSeconds: 0, screenOrientation: .portrait, motionStatus: .unavailable,
                        devicePose: nil, frame: pose, side: .left, automaticCount: 0, interruptions: 0, exercise: .lateralRaise)
        XCTAssertEqual(recorder.samples.first?.trackingQuality, .lowConfidence)
    }

    func testWristCurlWithoutUpperArmRaiseIsNotLateralRepetition() {
        var tracker = CurlTracker(side: .left, exercise: .lateralRaise)
        for i in 0..<60 {
            var pose = frame(10, at: Double(i) * 0.1)
            // Keep the upper arm stationary while the forearm moves.
            pose.people[0].points[.leftWrist] = PosePoint(x: 0.3, y: i % 20 < 10 ? 0.6 : 0.4)
            tracker.process(pose)
        }
        XCTAssertEqual(tracker.repetitions.count, 0)
    }

    func testOverlongCycleExpiresAndFreshCycleCanCount() {
        var tracker = CurlTracker(side: .left, exercise: .lateralRaise)
        feed(Array(cycle.prefix(13)), to: &tracker)
        for i in 13..<230 { tracker.process(frame(85, at: Double(i) * 0.1)) }
        feed([70, 55, 40, 10, 10, 10, 10], to: &tracker, start: 23)
        XCTAssertEqual(tracker.repetitions.count, 0)
        feed(cycle, to: &tracker, start: 24)
        XCTAssertEqual(tracker.repetitions.count, 1)
    }

    func testFixtureLikeCycleKeepsTimingMarginUnderFrameJitter() {
        let angles = [10.0, 10, 10, 10, 10, 25, 40, 55, 65, 70, 85, 85, 85, 85, 75, 65, 55, 45, 35, 25, 15, 10, 10, 10, 10, 10, 10, 10]
        for interval in [0.095, 0.1, 0.105] {
            var tracker = CurlTracker(side: .left, exercise: .lateralRaise)
            var trace: [String] = []
            for i in 0..<(angles.count * 2) {
                let snapshot = tracker.process(frame(angles[i % angles.count], at: Double(i) * interval))
                trace.append("\(i):\(snapshot.phase.rawValue):\(Int(snapshot.angle ?? -1)):\(snapshot.quality.rawValue)")
            }
            XCTAssertEqual(tracker.repetitions.count, 2, "interval=\(interval), \(trace.joined(separator: ","))")
        }
    }

    func testWristFlickerDoesNotBlockShoulderAngleCount() {
        var tracker = CurlTracker(side: .left, exercise: .lateralRaise)
        for (i, angle) in cycle.enumerated() {
            var value = frame(angle, at: Double(i) * 0.1)
            value.people[0].points.removeValue(forKey: .leftWrist)
            tracker.process(value)
        }
        XCTAssertEqual(tracker.repetitions.count, 1)
        XCTAssertEqual(tracker.interruptions, 0)
    }

    func testShortHipFlickerKeepsCycleButDoesNotInventMissingTorso() {
        for missing in [11, 15, 20] {
            var tracker = CurlTracker(side: .left, exercise: .lateralRaise)
            let slow = [10.0, 10, 10, 10, 25, 40, 50, 60, 70, 85, 85, 85, 85, 85, 75, 55, 45, 35, 25, 10, 10, 10, 10, 10]
            for (i, angle) in slow.enumerated() {
                var value = frame(angle, at: Double(i) * 0.1)
                if i == missing { value.people[0].points.removeValue(forKey: .leftHip) }
                tracker.process(value)
                if i == missing {
                    XCTAssertEqual(tracker.snapshot.trackingState, .grace)
                    XCTAssertNil(tracker.snapshot.angle)
                }
            }
            XCTAssertEqual(tracker.repetitions.count, 1, "missing=\(missing)")
            XCTAssertEqual(tracker.diagnostics.recoveries, 1)
        }
    }
}
