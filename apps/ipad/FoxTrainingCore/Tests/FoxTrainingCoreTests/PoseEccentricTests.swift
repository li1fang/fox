import XCTest
@testable import FoxTrainingCore

final class PoseEccentricTests: XCTestCase {
    func testCurrentReturnSignalDoesNotBackdateDetectionOrPublishFinishedDuration() throws {
        var estimator = PoseEccentricEstimator(policy: .init())
        for i in 0...20 { estimator.observe(angle: 50, at: Double(i) / 10) }
        XCTAssertEqual(estimator.currentPhaseObservation.status, .waiting)
        estimator.observe(angle: 60, at: 2.1)
        XCTAssertEqual(estimator.currentPhaseObservation.status, .waiting)
        estimator.observe(angle: 63, at: 2.2)
        estimator.observe(angle: 66, at: 2.3)
        XCTAssertEqual(estimator.currentPhaseObservation.status, .returning)
        XCTAssertEqual(try XCTUnwrap(estimator.currentPhaseObservation.detectedAtSeconds), 2.3, accuracy: 0.000001)
        XCTAssertEqual(estimator.finish(at: 2.3).status, .insufficientMotion, "Phase cue is not a complete measurement")
        estimator.markGap()
        XCTAssertEqual(estimator.currentPhaseObservation.status, .unavailable)
        XCTAssertNil(estimator.currentPhaseObservation.detectedAtSeconds)
    }
    private func signal(_ t: Double) -> Double {
        if t < 1 { return 130 - 80 * t }
        if t < 2 { return 50 }
        return min(140, 50 + 30 * (t - 2))
    }
    func testPlateauIsNotDescentAndDifferentRatesAgree() throws {
        for hz in [8.0, 10, 30] {
            var estimator = PoseEccentricEstimator(policy: .init())
            for i in 0...Int(5 * hz) {
                let t = Double(i) / hz
                estimator.observe(angle: signal(t), at: t)
            }
            let result = estimator.finish(at: 5)
            XCTAssertEqual(result.status, .measured)
            let uncertainty = try XCTUnwrap(result.onsetUncertaintySeconds)
            let start = try XCTUnwrap(result.startedAtSeconds)
            XCTAssertLessThanOrEqual(uncertainty, 0.4)
            XCTAssertEqual(start - uncertainty, 2, accuracy: 0.2)
            XCTAssertLessThanOrEqual(start, 2.3)
            XCTAssertEqual(try XCTUnwrap(result.durationSeconds) + uncertainty, 3, accuracy: 0.2)
            XCTAssertGreaterThan(try XCTUnwrap(result.detectedAtSeconds), try XCTUnwrap(result.startedAtSeconds))
        }
    }
    func testNoiseGapReversalAndClockCannotManufactureTempo() {
        for mode in ["noise", "gap", "reverse", "clock", "cadenceGap"] {
            var estimator = PoseEccentricEstimator(policy: .init())
            for i in 0...50 {
                let t = Double(i) / 10
                if mode == "cadenceGap" && (25...27).contains(i) { continue }
                if mode == "gap" && i == 30 { estimator.markGap() }
                let angle = mode == "noise" ? 50 + (i % 2 == 0 ? 1.0 : -1.0) :
                    (mode == "reverse" && i == 35 ? 75 : signal(t))
                estimator.observe(angle: angle, at: mode == "clock" && i == 30 ? 0 : t)
            }
            let result = estimator.finish(at: 5)
            XCTAssertNotEqual(result.status, .measured, mode)
            XCTAssertNil(result.durationSeconds, mode)
            XCTAssertNil(result.startedAtSeconds, mode)
        }
    }
}
