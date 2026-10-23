import XCTest
@testable import FoxTrainingCore

final class PoseAttemptTests: XCTestCase {
    private func frame(_ angle: Double, at t: Double, confidence: Double = 1) -> PoseFrame {
        let r = angle * .pi / 180
        return PoseFrame(timestamp: t, width: 1280, height: 720, people: [BodyPose(points: [
            .leftShoulder: PosePoint(x: 0.45, y: 0.80), .leftElbow: PosePoint(x: 0.45, y: 0.55),
            .leftWrist: PosePoint(x: 0.45 + sin(r) * 0.22 * 720 / 1280, y: 0.55 + cos(r) * 0.22, confidence: confidence)
        ])])
    }
    private func feed(_ angles: [Double], tracker: inout CurlTracker) {
        for (i, angle) in angles.enumerated() { tracker.process(frame(angle, at: Double(i) / 10)) }
    }
    func testAcceptedCycleAndTempoDeviationAreNotConflated() {
        var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
        feed([160,160,160,160,160,140,120,100,80,55,55,55,55,75,100,120,140,160,160,160,160], tracker: &tracker)
        XCTAssertEqual(tracker.repetitions.count, 1)
        XCTAssertEqual(tracker.attempts.map(\.outcome), [.accepted])
        XCTAssertNil(tracker.attempts[0].reason)
    }
    func testVisibleShortRangeIsBelowMinimumButRestIsNotAnAttempt() {
        var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
        feed(Array(repeating: 160, count: 30), tracker: &tracker)
        tracker.interrupt()
        XCTAssertTrue(tracker.attempts.isEmpty)
        tracker = CurlTracker(side: .left, runtimePolicy: .standard)
        feed([160,160,160,160,160,140,120,100,95,95,95,100,120,140,160,160,160,160], tracker: &tracker)
        XCTAssertEqual(tracker.repetitions.count, 0)
        XCTAssertEqual(tracker.attempts.map(\.outcome), [.observedBelowMinimum])
        XCTAssertEqual(tracker.attempts.first?.reason, .incompleteRange)
    }
    func testUnobservedPeakIsUnobservableNotBadFormAndNeverCounted() {
        var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
        feed([160,160,160,160,160,140,120,100], tracker: &tracker)
        for i in 8...14 { tracker.process(frame(55, at: Double(i) / 10, confidence: 0.1)) }
        XCTAssertEqual(tracker.repetitions.count, 0)
        XCTAssertEqual(tracker.attempts.map(\.outcome), [.unobservable])
        XCTAssertEqual(tracker.attempts.first?.reason, .dropoutTimeout)
    }
}
