import Foundation
import XCTest
@testable import FoxTrainingCore

final class PoseTests: XCTestCase {
    private func frame(_ angle: Double, at time: Double, side: ArmSide = .left, confidence: Double = 1, width: Double = 1280, height: Double = 720, offset: Double = 0) -> PoseFrame {
        let radians = angle * .pi / 180
        let joints = side.joints
        return PoseFrame(timestamp: time, width: width, height: height, people: [BodyPose(points: [
            joints[0]: PosePoint(x: 0.45 + offset, y: 0.80, confidence: confidence),
            joints[1]: PosePoint(x: 0.45 + offset, y: 0.55, confidence: confidence),
            joints[2]: PosePoint(x: 0.45 + offset + sin(radians) * 0.22 * height / width, y: 0.55 + cos(radians) * 0.22, confidence: confidence)
        ])])
    }
    private func cycle(_ tracker: inout CurlTracker, starting: Double = 0) {
        let angles = [160.0, 160, 160, 160, 160, 140, 120, 100, 80, 55, 55, 55, 55, 75, 100, 120, 140, 160, 160, 160, 160]
        for (index, angle) in angles.enumerated() { tracker.process(frame(angle, at: starting + Double(index) * 0.1, side: tracker.side)) }
    }

    func testPixelAspectCorrectedAngleAndMirroredLetterboxProjection() {
        for dimensions in [(1280.0, 720.0), (720.0, 1280.0)] {
            XCTAssertEqual(PoseGeometry.inspect(frame(60, at: 0, width: dimensions.0, height: dimensions.1), side: .left).angle!, 60, accuracy: 0.001)
        }
        let p = PosePoint(x: 0.25, y: 0.75)
        let projected = PoseGeometry.project(p, imageWidth: 200, imageHeight: 100, viewWidth: 300, viewHeight: 300, mirrored: false)
        XCTAssertEqual(projected.x, 75); XCTAssertEqual(projected.y, 112.5)
        let mirrored = PoseGeometry.project(p, imageWidth: 200, imageHeight: 100, viewWidth: 300, viewHeight: 300, mirrored: true)
        XCTAssertEqual(mirrored.x, 225); XCTAssertEqual(mirrored.y, projected.y)
    }

    func testOneCompleteCycleAndMeasuredPhaseDurations() {
        var tracker = CurlTracker(side: .left)
        cycle(&tracker)
        XCTAssertEqual(tracker.repetitions.count, 1)
        if let rep = tracker.repetitions.first {
            XCTAssertGreaterThanOrEqual(rep.liftSeconds, 0.2)
            XCTAssertGreaterThan(rep.holdSeconds ?? -1, 0)
            XCTAssertGreaterThanOrEqual(rep.lowerSeconds ?? -1, 0.2)
        }
        cycle(&tracker, starting: 2.1)
        XCTAssertEqual(tracker.repetitions.count, 2)
    }

    func testStaticJitterPartialAndInstantJumpDoNotCount() {
        for angles in [Array(repeating: 160.0, count: 50), [160, 150, 149, 152, 155, 148, 160, 150, 160], [160, 160, 160, 140, 120, 120, 140, 160, 160, 160], [160, 160, 160, 160, 55, 55, 55, 55, 160, 160, 160]] {
            var tracker = CurlTracker(side: .left)
            for (index, angle) in angles.enumerated() { tracker.process(frame(angle, at: Double(index) * 0.1)) }
            XCTAssertEqual(tracker.repetitions.count, 0)
        }
    }

    func testVisibilityAndMultiplePeopleAreNotAChosenLargestPerson() {
        XCTAssertEqual(PoseGeometry.inspect(PoseFrame(timestamp: 0, width: 1280, height: 720, people: []), side: .left).quality, .noPerson)
        var two = frame(160, at: 0)
        two.people.append(two.people[0])
        XCTAssertEqual(PoseGeometry.inspect(two, side: .left).quality, .multiplePeople)
        XCTAssertEqual(PoseGeometry.inspect(frame(160, at: 0, confidence: 0.5), side: .left).quality, .lowConfidence)
        var degenerate = frame(160, at: 0)
        degenerate.people[0].points[.leftWrist] = degenerate.people[0].points[.leftElbow]
        XCTAssertEqual(PoseGeometry.inspect(degenerate, side: .left).quality, .lowConfidence)
        degenerate.width = .nan
        XCTAssertEqual(PoseGeometry.inspect(degenerate, side: .left).quality, .invalidFrame)
    }

    func testOcclusionInvalidatesPartialCycleAndRequiresNewExtension() {
        for failure in ["none", "multiple", "confidence"] {
            var tracker = CurlTracker(side: .left, configuration: .legacy)
            for (index, angle) in [160.0, 160, 160, 160, 140, 120, 80, 55, 55, 55].enumerated() { tracker.process(frame(angle, at: Double(index) * 0.1)) }
            var invalid = frame(55, at: 1.0, confidence: failure == "confidence" ? 0.1 : 1)
            if failure == "none" { invalid.people = [] }
            if failure == "multiple" { invalid.people.append(invalid.people[0]) }
            tracker.process(invalid)
            for (index, angle) in [55.0, 55, 100, 140, 160, 160, 160].enumerated() { tracker.process(frame(angle, at: 1.1 + Double(index) * 0.1)) }
            XCTAssertEqual(tracker.repetitions.count, 0)
            XCTAssertEqual(tracker.interruptions, 1)
            cycle(&tracker, starting: 2.0)
            XCTAssertEqual(tracker.repetitions.count, 1)
        }
    }

    func testDroppedFramesAndTargetJumpInvalidateCycle() {
        for failure in ["gap", "jump", "pause"] {
            var tracker = CurlTracker(side: .left)
            for (index, angle) in [160.0, 160, 160, 160, 140, 120, 80, 55, 55, 55].enumerated() { tracker.process(frame(angle, at: Double(index) * 0.1)) }
            if failure == "pause" { tracker.interrupt() }
            tracker.process(frame(55, at: failure == "gap" ? 2 : 1, offset: failure == "jump" ? 0.3 : 0))
            for (index, angle) in [100.0, 130, 160, 160, 160].enumerated() { tracker.process(frame(angle, at: 2.1 + Double(index) * 0.1)) }
            XCTAssertEqual(tracker.repetitions.count, 0)
            cycle(&tracker, starting: 3)
            XCTAssertEqual(tracker.repetitions.count, 1)
        }
    }

    func testSelectedArmIsNeverAutomaticallySwitched() {
        var tracker = CurlTracker(side: .right)
        for index in 0..<30 { tracker.process(frame(160, at: Double(index) * 0.1, side: .left)) }
        XCTAssertEqual(tracker.snapshot.quality, .lowConfidence)
        cycle(&tracker, starting: 3)
        XCTAssertEqual(tracker.repetitions.count, 1)
    }

    func testDuplicateAndBackwardTimestampsDoNotAdvanceCount() {
        var tracker = CurlTracker(side: .left)
        cycle(&tracker)
        let before = tracker.repetitions
        cycle(&tracker)
        XCTAssertEqual(tracker.repetitions, before)
        XCTAssertEqual(before.count, 1)
    }
}
