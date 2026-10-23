import XCTest
@testable import FoxTrainingCore

final class PoseStartGateTests: XCTestCase {
    private func advance(_ gate: inout PoseStartGate, from: Double, through: Double, ready: Bool = true) {
        for tick in Int((from * 10).rounded())...Int((through * 10).rounded()) {
            gate.process(timestamp: Double(tick) / 10, poseReady: ready)
        }
    }

    func testCanArmWithoutPersonAndWaitIndefinitely() {
        var gate = PoseStartGate()
        gate.arm()
        advance(&gate, from: 0, through: 20, ready: false)
        XCTAssertEqual(gate.state, .waiting)
    }

    func testStablePoseThenThreeTwoOneBeforeReady() {
        var gate = PoseStartGate()
        gate.arm()
        advance(&gate, from: 0, through: 0.2)
        XCTAssertEqual(gate.state, .waiting)
        advance(&gate, from: 0.3, through: 1.2)
        XCTAssertEqual(gate.state, .countdown(3))
        advance(&gate, from: 1.3, through: 2.2)
        XCTAssertEqual(gate.state, .countdown(2))
        advance(&gate, from: 2.3, through: 3.2)
        XCTAssertEqual(gate.state, .countdown(1))
        advance(&gate, from: 3.3, through: 3.5)
        XCTAssertEqual(gate.state, .ready)
    }

    func testLostPoseRestartsFullCountdownRatherThanFinishingOldDeadline() {
        var gate = PoseStartGate()
        gate.arm()
        advance(&gate, from: 0, through: 2.3)
        gate.process(timestamp: 2.4, poseReady: false)
        XCTAssertEqual(gate.state, .waiting)
        advance(&gate, from: 2.5, through: 2.8)
        XCTAssertEqual(gate.state, .countdown(3))
        advance(&gate, from: 2.9, through: 5.7)
        XCTAssertEqual(gate.state, .countdown(1))
        gate.process(timestamp: 5.8, poseReady: true)
        XCTAssertEqual(gate.state, .ready)
    }

    func testMissingFramesAndDiscontinuityResetPreparation() {
        var gate = PoseStartGate()
        gate.arm()
        advance(&gate, from: 0, through: 1)
        gate.process(timestamp: 4, poseReady: true)
        XCTAssertEqual(gate.state, .waiting)
        advance(&gate, from: 4.1, through: 4.3)
        XCTAssertEqual(gate.state, .countdown(3))
        gate.invalidate()
        XCTAssertEqual(gate.state, .waiting)
    }

    func testCancelAndRearmRequireNewCountdown() {
        var gate = PoseStartGate()
        gate.arm()
        advance(&gate, from: 0, through: 2)
        gate.cancel()
        advance(&gate, from: 2.1, through: 10)
        XCTAssertEqual(gate.state, .idle)
        gate.arm()
        advance(&gate, from: 10.1, through: 10.4)
        XCTAssertEqual(gate.state, .countdown(3))
    }

    func testDuplicateBackwardAndNonfiniteTimesCannotAdvanceDeadline() {
        var gate = PoseStartGate()
        gate.arm()
        advance(&gate, from: 0, through: 0.3)
        gate.process(timestamp: 0.3, poseReady: false)
        gate.process(timestamp: -1, poseReady: false)
        gate.process(timestamp: .infinity, poseReady: true)
        XCTAssertEqual(gate.state, .countdown(3))
    }
}
