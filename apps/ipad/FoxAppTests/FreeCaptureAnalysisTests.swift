import XCTest
@testable import Fox

final class FreeCaptureAnalysisTests: XCTestCase {
    func testClosingAnOldCaptureDoesNotAdmitAnotherBackendUntilSlowAnalysisReturns() throws {
        let firstID = UUID(), nextID = UUID(), reopenedID = UUID()
        let first = FreeCaptureAnalysisGate(captureID: firstID)
        let next = FreeCaptureAnalysisGate(captureID: nextID)
        let reopened = FreeCaptureAnalysisGate(captureID: reopenedID)
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
        let unwantedSecondStage = DispatchSemaphore(value: 0)
        XCTAssertEqual(first.admit(captureID: firstID, frame: 1), .accepted)
        DispatchQueue.global().async {
            let deliver = first.perform(captureID: firstID, frame: 1, first: {
                began.signal(); release.wait()
            }, then: { unwantedSecondStage.signal() })
            XCTAssertFalse(deliver)
            ended.signal()
        }
        XCTAssertEqual(began.wait(timeout: .now() + 2), .success)
        first.close()
        XCTAssertEqual(next.admit(captureID: nextID, frame: 1), .busy, "Stopping/sealing may finish while the old analyzer is still running")
        XCTAssertEqual(reopened.admit(captureID: reopenedID, frame: 1), .busy, "A new backend/page must share the application analysis budget")
        release.signal(); XCTAssertEqual(ended.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(unwantedSecondStage.wait(timeout: .now()), .timedOut, "Stopped 2D work must not start a later 3D request")
        XCTAssertEqual(reopened.admit(captureID: reopenedID, frame: 2), .accepted)
        XCTAssertFalse(first.complete(captureID: firstID, frame: 1))
        XCTAssertEqual(next.admit(captureID: nextID, frame: 2), .busy, "Late old completion cannot release the new owner's slot")
        _ = reopened.complete(captureID: reopenedID, frame: 2)
    }
    func testStoppedQueuedAnalysisStartsNeitherRequestAndReleasesOnlyItsOwnSlot() {
        let id = UUID(), gate = FreeCaptureAnalysisGate(captureID: id)
        XCTAssertEqual(gate.admit(captureID: id, frame: 1), .accepted)
        gate.close()
        XCTAssertFalse(gate.perform(captureID: id, frame: 1, first: { XCTFail("2D started after stop") }, then: { XCTFail("3D started after stop") }))
        let nextID = UUID(), next = FreeCaptureAnalysisGate(captureID: nextID)
        XCTAssertEqual(next.admit(captureID: nextID, frame: 1), .accepted)
        XCTAssertFalse(gate.complete(captureID: id, frame: 1))
        XCTAssertEqual(next.admit(captureID: nextID, frame: 2), .busy)
        _ = next.complete(captureID: nextID, frame: 1)
    }
    func testWorkerCompletionReleasesQuotaButStillReportsUndeliveredResultAtStop() {
        let id = UUID(), gate = FreeCaptureAnalysisGate(captureID: id)
        XCTAssertEqual(gate.admit(captureID: id, frame: 1), .accepted)
        XCTAssertTrue(gate.perform(captureID: id, frame: 1, first: {}, then: {}))
        XCTAssertEqual(gate.admit(captureID: id, frame: 2), .busy, "This capture may not queue another result before acknowledgement")
        let nextID = UUID(), next = FreeCaptureAnalysisGate(captureID: nextID)
        XCTAssertEqual(next.admit(captureID: nextID, frame: 1), .accepted, "Finished worker releases the application quota")
        XCTAssertTrue(gate.close(), "A stop queued before result delivery must mark the missing pose result")
        XCTAssertFalse(gate.complete(captureID: id, frame: 1))
        XCTAssertEqual(next.admit(captureID: nextID, frame: 2), .busy)
        _ = next.complete(captureID: nextID, frame: 1)
    }
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
