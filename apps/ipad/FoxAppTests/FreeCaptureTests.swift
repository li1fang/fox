import AVFoundation
import XCTest
@testable import Fox

@MainActor
final class FreeCaptureTests: XCTestCase {
    private final class Backend: FreeCaptureBackend {
        var onEvent: ((FreeCaptureEvent) -> Void)?
        var previewSession: AVCaptureSession? { nil }
        var starts: [(UUID, FreeCaptureOptions)] = []
        var stops: [(UUID, String)] = []
        var removed: [UUID] = []
        var packages: [FreeCapturePackageSummary] = []
        func start(id: UUID, options: FreeCaptureOptions) throws { starts.append((id, options)) }
        func stop(id: UUID, reason: String) { stops.append((id, reason)) }
        func refresh() { onEvent?(.library(packages)) }
        func remove(id: UUID) { removed.append(id); packages.removeAll { $0.id == id }; refresh() }
    }

    private func package(_ id: UUID) -> FreeCapturePackageSummary {
        .init(id: id, folder: URL(fileURLWithPath: "/synthetic/\(id)"), recordedAt: Date(timeIntervalSince1970: 100),
              videoAvailable: true, recordingState: "complete", encodedFrames: 3, droppedFrames: 1)
    }

    func testFreeCaptureStartsWithoutPersonExerciseOrCountingCallback() throws {
        let backend = Backend(), controller = FreeCaptureController(backend: backend)
        controller.start()
        let id = try XCTUnwrap(controller.captureID)
        XCTAssertEqual(backend.starts.count, 1)
        XCTAssertEqual(controller.phase, .starting)
        backend.onEvent?(.started(id))
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertEqual(controller.encodedFrames, 0)
        XCTAssertTrue(controller.selectionLocked)
        controller.stop(reason: "userStopped")
        XCTAssertEqual(backend.stops.map(\.0), [id])
        XCTAssertEqual(controller.phase, .finishing)
    }

    func testAnalysisErrorAndSensorDisconnectNeverStopRecordingOrBecomeZeroCount() throws {
        let backend = Backend(), controller = FreeCaptureController(backend: backend)
        controller.start(); let id = try XCTUnwrap(controller.captureID)
        backend.onEvent?(.started(id))
        backend.onEvent?(.analysis(id, "3D 分析失败"))
        backend.onEvent?(.sensor(id, "PUMP 已断开"))
        backend.onEvent?(.progress(id, encoded: 3, dropped: 1))
        XCTAssertEqual(controller.phase, .recording)
        XCTAssertTrue(backend.stops.isEmpty)
        XCTAssertEqual(controller.analysisStatus, "3D 分析失败")
        XCTAssertEqual(controller.sensorStatus, "PUMP 已断开")
        XCTAssertEqual(controller.evaluationStatus, "未评测")
        XCTAssertEqual(controller.encodedFrames, 3)
        XCTAssertEqual(controller.droppedFrames, 1)
    }

    func testOptionsStayIndependentAndCannotChangeDuringRecordingOrFinalization() {
        let backend = Backend(), controller = FreeCaptureController(backend: backend)
        controller.changeCamera(front: false)
        XCTAssertEqual(controller.options.analysis, .twoD)
        controller.changeAnalysis(.comparison)
        XCTAssertFalse(controller.options.frontCamera)
        controller.start()
        controller.changeCamera(front: true); controller.changeAnalysis(.none)
        XCTAssertFalse(controller.options.frontCamera)
        XCTAssertEqual(controller.options.analysis, .comparison)
        controller.stop(reason: "userStopped")
        controller.changeCamera(front: true)
        XCTAssertFalse(controller.options.frontCamera)
    }

    func testOldCaptureCallbacksCannotFinishOrOverwriteNewCapture() throws {
        let backend = Backend(), controller = FreeCaptureController(backend: backend)
        controller.start(); let first = try XCTUnwrap(controller.captureID)
        controller.stop(reason: "userStopped")
        let original = package(first); backend.packages = [original]
        backend.onEvent?(.finished(original))
        controller.start(); let second = try XCTUnwrap(controller.captureID)
        XCTAssertNotEqual(first, second)
        backend.onEvent?(.failed(first, "late failure"))
        backend.onEvent?(.finished(original))
        backend.onEvent?(.progress(first, encoded: 999, dropped: 0))
        XCTAssertEqual(controller.captureID, second)
        XCTAssertEqual(controller.phase, .starting)
        XCTAssertEqual(controller.encodedFrames, 0)
        XCTAssertEqual(controller.packages.map(\.id), [first])
    }

    func testCancelledExportAndAnotherCaptureNeverDeleteSavedOriginal() throws {
        let backend = Backend(), controller = FreeCaptureController(backend: backend)
        controller.start(); let id = try XCTUnwrap(controller.captureID)
        let saved = package(id); backend.packages = [saved]
        controller.stop(reason: "userStopped"); backend.onEvent?(.finished(saved))
        XCTAssertEqual(controller.exportURL(for: saved), saved.folder)
        controller.exportFinished(success: false)
        XCTAssertTrue(backend.removed.isEmpty)
        XCTAssertEqual(controller.packages.map(\.id), [id])
        controller.start()
        XCTAssertTrue(backend.removed.isEmpty)
        XCTAssertEqual(controller.packages.map(\.id), [id])
        controller.remove(saved)
        XCTAssertTrue(backend.removed.isEmpty, "Deletion is unavailable during an active capture")
    }
    func testCameraPermissionFailureStaysDistinctFromUnknownPoseAfterMetadataIsSaved() throws {
        let backend = Backend(), controller = FreeCaptureController(backend: backend)
        controller.start(); let id = try XCTUnwrap(controller.captureID)
        backend.onEvent?(.camera(id, "相机权限未开启"))
        backend.onEvent?(.finishing(id))
        var failed = package(id); failed.videoAvailable = false; failed.recordingState = "failed"
        failed.encodedFrames = 0; failed.droppedFrames = 0; failed.stopReason = "cameraPermissionDenied"
        backend.packages = [failed]; backend.onEvent?(.finished(failed))
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertEqual(controller.cameraStatus, "相机权限未开启")
        XCTAssertEqual(controller.evaluationStatus, "未评测")
        XCTAssertEqual(controller.latest?.stopDescription, "相机权限不可用")
        XCTAssertFalse(try XCTUnwrap(controller.latest).videoAvailable)
    }
}
