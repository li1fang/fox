import XCTest
import AVFoundation
import FoxTrainingCore
@testable import Fox

@MainActor
final class FreeCaptureIntegrationTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FreeCaptureIntegration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(8)
        while !predicate(), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(predicate())
    }
    func testNoPeopleAndAnalysisErrorsStillSaveVideoAndLeaveExistingTrainingBytesUntouched() async throws {
        for fixture in ["no_people", "analysis_error"] {
            let base = try root(), file = base.appendingPathComponent("training.json")
            try LocalTrainingRepository.encoder().encode(TrainingArchive()).write(to: file)
            let store = TrainingStore(archiveURL: file)
            let before = try Data(contentsOf: file), prior = store.archive
            let backend = FreeCaptureNativeBackend(root: base.appendingPathComponent("Lab"), fixture: fixture)
            let controller = FreeCaptureController(backend: backend)
            controller.start()
            try await waitUntil { controller.encodedFrames >= 2 && controller.analysisStatus != "等待画面" }
            controller.stop(reason: "userStopped")
            try await waitUntil { controller.phase == .finished }
            let package = try XCTUnwrap(controller.latest)
            XCTAssertTrue(package.videoAvailable)
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.folder.appendingPathComponent("video.mp4").path))
            XCTAssertEqual(controller.evaluationStatus, "未评测")
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertEqual(store.archive.sessions.count, prior.sessions.count)
            let rows = try String(contentsOf: package.folder.appendingPathComponent("poses2d.jsonl"))
            XCTAssertTrue(rows.contains(fixture == "analysis_error" ? "request_failed" : "no_observation"))
            XCTAssertFalse(rows.contains("automatic_count"))
            let reopened = try FreeCaptureArchive.list(root: base.appendingPathComponent("Lab"))
            XCTAssertEqual(reopened.map(\.id), [package.id])
        }
    }
    func testUnavailable3DDoesNotStopVideoOr2DAndBackgroundSealsAsInterrupted() async throws {
        let base = try root(), backend = FreeCaptureNativeBackend(root: base, fixture: "3d_unavailable")
        let controller = FreeCaptureController(backend: backend)
        controller.changeAnalysis(.comparison); controller.start()
        try await waitUntil { controller.encodedFrames >= 2 && controller.analysisStatus.contains("unsupported") }
        XCTAssertEqual(controller.phase, .recording)
        controller.stop(reason: "background")
        try await waitUntil { controller.phase == .finished }
        let package = try XCTUnwrap(controller.latest)
        XCTAssertTrue(package.videoAvailable); XCTAssertEqual(package.recordingState, "interrupted")
        let manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: package.folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.streams.first { $0.kind == "pose3d" }?.state, "interrupted")
        let twoD = try XCTUnwrap(String(contentsOf: package.folder.appendingPathComponent("poses2d.jsonl")).split(separator: "\n").first)
        let threeD = try XCTUnwrap(String(contentsOf: package.folder.appendingPathComponent("poses3d.jsonl")).split(separator: "\n").first)
        let a = try JSONDecoder().decode(LabPose2DFrame.self, from: Data(twoD.utf8))
        let b = try JSONDecoder().decode(Pose3DFrame.self, from: Data(threeD.utf8))
        XCTAssertEqual(b.context.streamID, a.sourceID)
        XCTAssertEqual(b.context.segmentID, a.captureID)
        XCTAssertEqual(b.context.frameIndex, a.seq)
        XCTAssertEqual(String(try XCTUnwrap(b.context.pts).value), a.pts.value)
        XCTAssertEqual(b.context.pts?.timescale, a.pts.timescale)
        XCTAssertEqual(b.context.orientation, a.orientation)
        XCTAssertEqual(b.outcome, .unsupported)
        XCTAssertTrue(a.people.isEmpty)
    }
    func testPhysicalCameraChangeStopsBeforeFirstNewSourceFrameCanEnterSavedVideo() async throws {
        let base = try root(), backend = FreeCaptureNativeBackend(root: base, fixture: "no_people")
        let controller = FreeCaptureController(backend: backend)
        controller.changeAnalysis(.none); controller.start()
        let id = try XCTUnwrap(controller.captureID)
        let first = try VisionDiagnosticRecorder.syntheticSample(timestamp: 300, width: 64, height: 96)
        let second = try VisionDiagnosticRecorder.syntheticSample(timestamp: 300.1, width: 64, height: 96)
        backend.camera.onCaptureQueue {
            backend.camera.deliverRawSample(first, id: id, physicalSourceID: "synthetic-camera-A")
            backend.camera.deliverRawSample(second, id: id, physicalSourceID: "synthetic-camera-B")
        }
        try await waitUntil { controller.phase == .finished }
        let saved = try XCTUnwrap(controller.latest)
        XCTAssertTrue(saved.videoAvailable); XCTAssertEqual(saved.encodedFrames, 1)
        XCTAssertEqual(saved.recordingState, "interrupted")
        let details = try JSONSerialization.jsonObject(with: Data(contentsOf: saved.folder.appendingPathComponent("recording.json"))) as? [String: Any]
        XCTAssertEqual(details?["stop_reason"] as? String, "cameraDiscontinuity")
    }
}
