import XCTest
@testable import Fox

final class FreeCaptureAnalysisTests: XCTestCase {
    func testBusyAnalysisDropsAdmissionWithoutBlockingVideoAndRejectsWrongCapture() {
        let id = UUID(), gate = FreeCaptureAnalysisGate(captureID: id)
        XCTAssertEqual(gate.admit(captureID: id, frame: 1), .accepted)
        XCTAssertEqual(gate.admit(captureID: id, frame: 2), .busy)
        XCTAssertEqual(gate.admit(captureID: UUID(), frame: 3), .wrongCapture)
        XCTAssertEqual(gate.busyDrops, 1)
        XCTAssertTrue(gate.complete(captureID: id, frame: 1))
        XCTAssertEqual(gate.admit(captureID: id, frame: 3), .accepted)
    }

    func testLateOrDuplicateCompletionCannotReleaseAnotherFrame() {
        let id = UUID(), gate = FreeCaptureAnalysisGate(captureID: id)
        XCTAssertEqual(gate.admit(captureID: id, frame: 1), .accepted)
        XCTAssertTrue(gate.complete(captureID: id, frame: 1))
        XCTAssertEqual(gate.admit(captureID: id, frame: 2), .accepted)
        XCTAssertFalse(gate.complete(captureID: id, frame: 1))
        XCTAssertFalse(gate.complete(captureID: UUID(), frame: 2))
        XCTAssertEqual(gate.admit(captureID: id, frame: 3), .busy)
        XCTAssertTrue(gate.complete(captureID: id, frame: 2))
    }

    func testClosingAnalysisRejectsNewWorkAndLateResultWithoutDiscardingVideo() {
        let id = UUID(), gate = FreeCaptureAnalysisGate(captureID: id)
        XCTAssertEqual(gate.admit(captureID: id, frame: 1), .accepted)
        gate.close()
        XCTAssertEqual(gate.admit(captureID: id, frame: 2), .closed)
        XCTAssertFalse(gate.complete(captureID: id, frame: 1))
        XCTAssertEqual(gate.busyDrops, 0)
    }
}
