import XCTest
@testable import FoxTrainingCore

final class PoseVideoReplayTests: XCTestCase {
    private func rep(_ start: Double, _ peak: Double, _ end: Double) -> CurlRepetition {
        CurlRepetition(liftSeconds: peak - start, holdSeconds: 0, lowerSeconds: end - peak, completedAtSeconds: end + 0.2,
            minimumConfidence: 0.8, startedAtSeconds: start, peakAtSeconds: peak, loweredAtSeconds: end)
    }
    func testEqualTotalDoesNotHideMergedMissedOrExtraEvents() throws {
        let result = try PoseEventEvaluator.evaluate([rep(0, 1, 3), rep(5, 6, 7), rep(8, 9, 10)], origin: 100, peaks: [101, 102, 109])
        XCTAssertEqual(result.events.map(\.status), ["merged-peaks", "unmatched-predicted-event", "one-peak-in-observed-cycle"])
        XCTAssertEqual(result.events.count, 3)
    }
    func testMissingPeaksAndInvalidOrOverlappingIntervals() throws {
        let result = try PoseEventEvaluator.evaluate([rep(0, 1, 2)], origin: 7, peaks: [8, 12])
        XCTAssertEqual(result.unmatchedPeakCandidates, [12])
        XCTAssertThrowsError(try PoseEventEvaluator.evaluate([rep(2, 1, 3)], origin: 0, peaks: []))
        XCTAssertThrowsError(try PoseEventEvaluator.evaluate([rep(0, 1, 3), rep(2, 3, 4)], origin: 0, peaks: []))
        XCTAssertThrowsError(try PoseEventEvaluator.evaluate([], origin: 0, peaks: [1, 1]))
    }
    func testRawCacheRejectsDuplicateOrInvalidJointsBeforeDictionaryCreation() {
        let joint = PoseTraceJoint(joint: .leftElbow, x: 0.5, y: 0.4, confidence: 0.8)
        XCTAssertThrowsError(try PoseVideoRow(seconds: 1, width: 1280, height: 720, people: [[joint, joint]]).frame())
        XCTAssertThrowsError(try PoseVideoRow(seconds: .nan, width: 1280, height: 720, people: []).frame())
    }
    func testFullSceneSelectionMetadataSurvivesReplayAndInvalidIndexRejected() throws {
        var tracker = CurlTracker(side: .left, runtimePolicy: .standard)
        tracker.process(PoseFrame(timestamp: 1, width: 1280, height: 720, people: [BodyPose(points: [:])]),
            originalPeopleCount: 3, selection: PoseSubjectSelection(state: .bound, index: 2))
        try tracker.diagnostics.validate(side: .left)
        XCTAssertEqual(tracker.diagnostics.samples[0].originalPeopleCount, 3)
        var diagnostics = tracker.diagnostics
        diagnostics.samples[0].selectedSubjectIndex = 3
        XCTAssertThrowsError(try diagnostics.validate(side: .left))
    }
}
