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
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(8)
        while !predicate(), Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        _ = try XCTUnwrap(predicate() ? true : nil, "Timed out waiting for the capture result", file: file, line: line)
    }
    func testNoPeopleAndAnalysisErrorsStillSaveVideoAndLeaveExistingTrainingBytesUntouched() async throws {
        for fixture in ["no_people", "analysis_error"] {
            let base = try root(), file = base.appendingPathComponent("training.json")
            try LocalTrainingRepository.encoder().encode(TrainingArchive()).write(to: file)
            let store = TrainingStore(archiveURL: file)
            let before = try Data(contentsOf: file), prior = store.archive
            let backend = FreeCaptureNativeBackend(root: base.appendingPathComponent("Lab"), fixture: fixture)
            let controller = FreeCaptureController(backend: backend)
            var analysisDelivered = false
            let receive = backend.onEvent
            backend.onEvent = { event in
                receive?(event)
                if case .analysis = event { analysisDelivered = true }
            }
            controller.start()
            defer { controller.stop(reason: "testCleanup") }
            try await waitUntil { controller.encodedFrames >= 2 && analysisDelivered }
            controller.stop(reason: "userStopped")
            try await waitUntil { controller.phase == .finished }
            let package = try XCTUnwrap(controller.latest)
            XCTAssertTrue(package.videoAvailable)
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.folder.appendingPathComponent("video.mp4").path))
            XCTAssertEqual(controller.evaluationStatus, "未评测")
            XCTAssertEqual(try Data(contentsOf: file), before)
            XCTAssertEqual(store.archive.sessions.count, prior.sessions.count)
            let rows = try String(contentsOf: package.folder.appendingPathComponent("poses2d.jsonl"))
            let decoded = try rows.split(separator: "\n").map { try JSONDecoder().decode(LabPose2DFrame.self, from: Data($0.utf8)) }
            for row in decoded { try row.validate() }
            let expected = fixture == "analysis_error" ? "request_failed" : "no_observation"
            XCTAssertTrue(decoded.contains { $0.state == expected }, "\(fixture): \(rows)")
            if fixture == "analysis_error" {
                XCTAssertTrue(decoded.contains { $0.reason == "fox.synthetic_analysis:1" })
            }
            XCTAssertFalse(rows.contains("automatic_count"))
            let reopened = try FreeCaptureArchive.list(root: base.appendingPathComponent("Lab"))
            XCTAssertEqual(reopened.map(\.id), [package.id])
        }
    }
    func testUnavailable3DDoesNotStopVideoOr2DAndBackgroundSealsAsInterrupted() async throws {
        let blockerID = UUID()
        let owner = FreeCaptureAnalysisGate(captureID: blockerID)
        XCTAssertEqual(owner.admit(captureID: blockerID, frame: 0), .accepted)
        defer { _ = owner.complete(captureID: blockerID, frame: 0) }
        let base = try root(), backend = FreeCaptureNativeBackend(root: base, fixture: "3d_unavailable")
        let controller = FreeCaptureController(backend: backend)
        controller.changeAnalysis(.comparison); controller.start()
        defer { controller.stop(reason: "testCleanup") }
        try await waitUntil { controller.encodedFrames >= 2 }
        _ = owner.complete(captureID: blockerID, frame: 0)
        try await waitUntil { controller.encodedFrames >= 2 && controller.analysisStatus.contains("unsupported") }
        XCTAssertEqual(controller.phase, .recording)
        controller.stop(reason: "background")
        try await waitUntil { controller.phase == .finished }
        let package = try XCTUnwrap(controller.latest)
        XCTAssertTrue(package.videoAvailable); XCTAssertEqual(package.recordingState, "interrupted")
        let manifest = try JSONDecoder().decode(LabCaptureManifest.self, from: Data(contentsOf: package.folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.streams.first { $0.kind == "pose3d" }?.state, "interrupted")
        let twoD = try String(contentsOf: package.folder.appendingPathComponent("poses2d.jsonl")).split(separator: "\n")
            .map { try JSONDecoder().decode(LabPose2DFrame.self, from: Data($0.utf8)) }
        let threeD = try String(contentsOf: package.folder.appendingPathComponent("poses3d.jsonl")).split(separator: "\n")
            .map { try JSONDecoder().decode(Pose3DFrame.self, from: Data($0.utf8)) }
        XCTAssertEqual(threeD.first?.outcome, .dropped, "The deliberately busy frames must remain in the original")
        XCTAssertTrue(threeD.contains { $0.outcome == .unsupported }, "An actual unsupported result is required, not just drops")
        XCTAssertEqual(Set(twoD.map(\.seq)).count, twoD.count)
        XCTAssertEqual(Set(threeD.map { $0.context.frameIndex }).count, threeD.count)
        XCTAssertEqual(twoD.count, threeD.count)
        for row in twoD { try row.validate() }
        let byFrame = Dictionary(grouping: twoD, by: \.seq)
        for b in threeD {
            try b.validate()
            let a = try XCTUnwrap(byFrame[b.context.frameIndex]?.first)
            XCTAssertEqual(b.context.streamID, a.sourceID)
            XCTAssertEqual(b.context.segmentID, a.captureID)
            XCTAssertEqual(String(try XCTUnwrap(b.context.pts).value), a.pts.value)
            XCTAssertEqual(b.context.pts?.timescale, a.pts.timescale)
            XCTAssertEqual(b.context.orientation, a.orientation)
            XCTAssertTrue(a.people.isEmpty)
            if b.outcome == .dropped {
                XCTAssertEqual(a.state, "dropped")
                XCTAssertEqual(b.failure?.domain, "fox.capture.analysis_busy")
            } else {
                XCTAssertEqual(b.outcome, .unsupported)
                XCTAssertEqual(a.state, "no_observation")
                XCTAssertEqual(b.failure?.domain, "fox.synthetic_3d_unavailable")
            }
        }
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
