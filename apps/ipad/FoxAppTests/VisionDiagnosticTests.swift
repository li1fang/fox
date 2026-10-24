import AVFoundation
import Combine
import XCTest
import FoxTrainingCore
@testable import Fox

@MainActor
final class VisionDiagnosticTests: XCTestCase {
    func testDiagnosticSelectionLockPublishesWithoutCameraFrames() throws {
        let root = root(), controller = VisionLabController(diagnosticRoot: root.appendingPathComponent("Diagnostics"), storageDirectory: root)
        let capture = controller.diagnosticCapture, original = controller.configuration
        let deliver = try XCTUnwrap(controller.camera.onDiagnosticResult)
        var notifications = 0
        let subscription = controller.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }

        let failure = VisionDiagnosticArchive.error("synthetic finalization failure")
        for fails in [false, true] {
            let context = context()
            notifications = 0
            XCTAssertFalse(controller.selectionLocked)
            XCTAssertTrue(capture.begin(context))
            XCTAssertTrue(controller.selectionLocked)
            XCTAssertGreaterThan(notifications, 0, "Recording start must refresh selection controls without a camera frame")
            notifications = 0
            capture.markFinishing()
            XCTAssertTrue(controller.selectionLocked, "Keep selection locked until the original recording finishes")
            XCTAssertGreaterThan(notifications, 0)
            notifications = 0
            deliver(UUID(), .failure(failure))
            XCTAssertTrue(controller.selectionLocked)
            XCTAssertEqual(notifications, 0, "An unrelated result cannot unlock the current recording")
            if fails { deliver(context.id, .failure(failure)) }
            else {
                let folder = try VisionDiagnosticArchive.prepare(context, root: capture.draftRoot)
                let manifest = try VisionDiagnosticArchive.seal(context: context, folder: folder, state: "failed",
                    reason: "preparationCancelled", error: nil, video: nil)
                deliver(context.id, .success(manifest))
            }
            XCTAssertFalse(controller.selectionLocked)
            XCTAssertGreaterThan(notifications, 0, "Finalization must refresh selection controls without a camera frame")
        }
        XCTAssertEqual(controller.cameraState, .stopped)
        XCTAssertFalse(controller.trialActive)
        XCTAssertEqual(controller.automaticCount, 0)
        XCTAssertEqual(controller.configuration, original)
    }

    func testPostReviewAnnotationIsBoundToPackageAndOriginalEvidenceIsUnchanged() throws {
        let base = root(), drafts = base.appendingPathComponent("Drafts"), retained = base.appendingPathComponent("Retained")
        let c = context(), folder = try VisionDiagnosticArchive.prepare(c, root: drafts)
        let draft = try VisionDiagnosticArchive.seal(context: c, folder: folder, state: "failed", reason: "neverStarted", error: nil, video: nil)
        let before = try Data(contentsOf: folder.appendingPathComponent("context.json"))
        let review = VisionDiagnosticReview(diagnosticID: c.id, reviewedAt: Date(), referenceCount: 3,
            review: try TrialReview.make(information: "", softwareIssue: "未能开始", trainingFeeling: "", at: Date()))
        var wrong = review; wrong.diagnosticID = UUID()
        XCTAssertThrowsError(try VisionDiagnosticArchive.retain(id: c.id, drafts: drafts, destination: retained, review: wrong))
        XCTAssertEqual(try VisionDiagnosticArchive.decode(VisionDiagnosticManifest.self, at: folder.appendingPathComponent("manifest.json")).files.count, draft.files.count)
        let kept = try VisionDiagnosticArchive.retain(id: c.id, drafts: drafts, destination: retained, review: review)
        let destination = retained.appendingPathComponent(c.id.uuidString)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("context.json")), before)
        XCTAssertTrue(kept.files.contains { $0.path == "review.json" })
        let decoded = try VisionDiagnosticArchive.decode(VisionDiagnosticReview.self, at: destination.appendingPathComponent("review.json"))
        XCTAssertEqual(decoded.referenceCount, 3)
        XCTAssertEqual(decoded.review?.softwareIssue, "未能开始")
        XCTAssertNil(decoded.review?.trainingFeeling)
    }

    private func context() -> VisionDiagnosticContext {
        VisionDiagnosticContext(source: .fixture, device: "fixture", appVersion: "test", appBuild: "test",
            camera: "front", exercise: .curl, arm: .left, bodyView: .side, screenOrientation: .portrait,
            configuration: .standard, runtimePolicy: .standard)
    }
    private func root() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testZeroFramesFailureIsSealedWithoutCreatingTrainingRecord() async throws {
        let root = root(), context = context(), done = expectation(description: "sealed")
        var result: Result<VisionDiagnosticManifest, Error>?
        let recorder = try VisionDiagnosticRecorder(context: context, root: root) { value in
            Task { @MainActor in result = value; done.fulfill() }
        }
        recorder.event(VisionDiagnosticEvent(kind: "prepareRequested"))
        recorder.finish(reason: "cameraUnavailable")
        recorder.finish(reason: "duplicate")
        await fulfillment(of: [done], timeout: 10)
        let manifest = try XCTUnwrap(result).get()
        XCTAssertEqual(manifest.state, "failed")
        XCTAssertNil(manifest.video)
        XCTAssertEqual(manifest.stopReason, "cameraUnavailable")
        XCTAssertEqual(try VisionDiagnosticArchive.list(root: root).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("training-records.v1.json").path))
        let events = try String(contentsOf: recorder.folder.appendingPathComponent("events.jsonl"))
        XCTAssertTrue(events.contains("prepareRequested"))
        XCTAssertTrue(events.contains("recordingEnded"))
    }

    func testEncodedVideoUsesCapturePTSOriginAndHasNoAudio() async throws {
        let root = root(), context = context(), done = expectation(description: "encoded")
        var result: Result<VisionDiagnosticManifest, Error>?
        let recorder = try VisionDiagnosticRecorder(context: context, root: root) { value in
            Task { @MainActor in result = value; done.fulfill() }
        }
        for index in 0..<20 {
            let reason = recorder.append(try VisionDiagnosticRecorder.syntheticSample(timestamp: 100 + Double(index) / 10, width: 64, height: 96))
            XCTAssertNil(reason)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        recorder.finish(reason: "userStopped")
        await fulfillment(of: [done], timeout: 15)
        let manifest = try XCTUnwrap(result).get(), video = try XCTUnwrap(manifest.video)
        XCTAssertEqual(manifest.state, "complete")
        XCTAssertEqual(video.firstCapturePTS, 100)
        XCTAssertGreaterThan(video.encodedFrames, 0)
        XCTAssertFalse(video.audio)
        let url = recorder.folder.appendingPathComponent("video.mp4"), asset = AVURLAsset(url: url)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audios.count, 0)
        let videos = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videos.count, 1)
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: try XCTUnwrap(videos.first), outputSettings: nil)
        reader.add(output); XCTAssertTrue(reader.startReading())
        let first = try XCTUnwrap(output.copyNextSampleBuffer())
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first).seconds, 0, accuracy: 0.001)
        let descriptor = try XCTUnwrap(manifest.files.first { $0.path == "video.mp4" })
        XCTAssertEqual(try VisionDiagnosticArchive.asset(url).sha256, descriptor.sha256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.folder.appendingPathComponent("video.partial.mp4").path))
    }

    func testGeometryChangeDoesNotMixFormatsAndStillSealsFirstClip() async throws {
        let root = root(), done = expectation(description: "geometry")
        var result: Result<VisionDiagnosticManifest, Error>?
        let recorder = try VisionDiagnosticRecorder(context: context(), root: root) { value in
            Task { @MainActor in result = value; done.fulfill() }
        }
        XCTAssertNil(recorder.append(try VisionDiagnosticRecorder.syntheticSample(timestamp: 20, width: 64, height: 96)))
        XCTAssertEqual(recorder.append(try VisionDiagnosticRecorder.syntheticSample(timestamp: 20.1, width: 96, height: 64)), "frameGeometryChanged")
        recorder.finish(reason: "frameGeometryChanged")
        await fulfillment(of: [done], timeout: 15)
        let manifest = try XCTUnwrap(result).get()
        XCTAssertEqual(manifest.state, "interrupted")
        XCTAssertEqual(manifest.video?.width, 64)
        XCTAssertEqual(manifest.video?.encodedFrames, 1)
    }

    func testDurationLimitAndBackgroundRemainSeparateFromWorkoutCompletion() async throws {
        let root = root(), done = expectation(description: "background")
        var c = context(); c.maximumSeconds = 1
        var result: Result<VisionDiagnosticManifest, Error>?
        let recorder = try VisionDiagnosticRecorder(context: c, root: root) { value in
            Task { @MainActor in result = value; done.fulfill() }
        }
        XCTAssertNil(recorder.append(try VisionDiagnosticRecorder.syntheticSample(timestamp: 30, width: 64, height: 96)))
        XCTAssertEqual(recorder.append(try VisionDiagnosticRecorder.syntheticSample(timestamp: 31.1, width: 64, height: 96)), "durationLimit")
        recorder.finish(reason: "background")
        await fulfillment(of: [done], timeout: 15)
        let manifest = try XCTUnwrap(result).get()
        XCTAssertEqual(manifest.state, "interrupted")
        XCTAssertEqual(manifest.stopReason, "background")
        XCTAssertNotNil(manifest.video)
    }

    func testRestartRecoveryDoesNotRecoverAnotherActiveRecorder() throws {
        let root = root(), live = context()
        _ = try VisionDiagnosticArchive.prepare(live, root: root)
        var stale = context(); stale.processToken = UUID()
        _ = try VisionDiagnosticArchive.prepare(stale, root: root)
        let packages = try VisionDiagnosticArchive.list(root: root)
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages[0].id, stale.id)
        XCTAssertEqual(packages[0].state, "interrupted")
        XCTAssertNil(packages[0].video)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(live.id.uuidString).appendingPathComponent("manifest.json").path))
    }

    func testDuplicateIDAndUnsafeDeletePreserveFiles() throws {
        let root = root(), c = context()
        let folder = try VisionDiagnosticArchive.prepare(c, root: root)
        let before = try Data(contentsOf: folder.appendingPathComponent("context.json"))
        XCTAssertThrowsError(try VisionDiagnosticArchive.prepare(c, root: root))
        XCTAssertThrowsError(try VisionDiagnosticArchive.remove(id: c.id, root: root))
        XCTAssertEqual(before, try Data(contentsOf: folder.appendingPathComponent("context.json")))
        _ = try VisionDiagnosticArchive.seal(context: c, folder: folder, state: "failed", reason: "zeroFrames", error: "no video", video: nil)
        XCTAssertThrowsError(try VisionDiagnosticArchive.seal(context: c, folder: folder, state: "failed", reason: "again", error: nil, video: nil))
        try VisionDiagnosticArchive.remove(id: c.id, root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testNoRetainedMediaBeforeAnAttemptAndFailureDoesNotChangeConfiguration() throws {
        let root = root(), controller = VisionLabController(diagnosticRoot: root)
        XCTAssertFalse(controller.diagnosticCapture.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let original = controller.configuration
        let parent = self.root(); try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let blocked = parent.appendingPathComponent("blocked")
        try Data([1]).write(to: blocked)
        XCTAssertThrowsError(try VisionDiagnosticRecorder(context: context(), root: blocked) { _ in })
        XCTAssertEqual(controller.configuration, original)
        XCTAssertEqual(controller.automaticCount, 0)
    }

    func testLeavingOwnerStillFinishesAndDeliversSealedFailure() async throws {
        let root = root(), c = context(), done = expectation(description: "owner released")
        var result: Result<VisionDiagnosticManifest, Error>?
        var camera: PoseCamera? = PoseCamera()
        camera?.onDiagnosticResult = { _, value in result = value; done.fulfill() }
        camera?.beginDiagnostic(context: c, root: root)
        camera?.endDiagnostic(reason: "cameraStopped")
        camera = nil
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(try XCTUnwrap(result).get().state, "failed")
        XCTAssertEqual(try VisionDiagnosticArchive.list(root: root).first?.id, c.id)
    }

    func testReviewRetainMovesDraftAndDiscardNeverCreatesRetainedPackage() throws {
        let base = root(), drafts = base.appendingPathComponent("Drafts"), retained = base.appendingPathComponent("Retained")
        let c = context(), folder = try VisionDiagnosticArchive.prepare(c, root: drafts)
        let draft = try VisionDiagnosticArchive.seal(context: c, folder: folder, state: "failed", reason: "neverStarted", error: nil, video: nil)
        XCTAssertNil(draft.retainedAt)
        XCTAssertEqual(draft.storagePolicy, "temporary-until-review")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
        let kept = try VisionDiagnosticArchive.retain(id: c.id, drafts: drafts, destination: retained)
        XCTAssertNotNil(kept.retainedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try VisionDiagnosticArchive.list(root: retained).count, 1)
        let second = context(), secondFolder = try VisionDiagnosticArchive.prepare(second, root: drafts)
        _ = try VisionDiagnosticArchive.seal(context: second, folder: secondFolder, state: "failed", reason: "neverStarted", error: nil, video: nil)
        try VisionDiagnosticArchive.remove(id: second.id, root: drafts)
        XCTAssertTrue(try VisionDiagnosticArchive.list(root: drafts).isEmpty)
        XCTAssertEqual(try VisionDiagnosticArchive.list(root: retained).map(\.id), [c.id])
    }

    func testCorruptDraftCannotBeRetainedAndOriginalIsPreserved() throws {
        let base = root(), drafts = base.appendingPathComponent("Drafts"), retained = base.appendingPathComponent("Retained")
        let c = context(), folder = try VisionDiagnosticArchive.prepare(c, root: drafts)
        _ = try VisionDiagnosticArchive.seal(context: c, folder: folder, state: "failed", reason: "neverStarted", error: nil, video: nil)
        try Data("damaged".utf8).write(to: folder.appendingPathComponent("context.json"))
        XCTAssertThrowsError(try VisionDiagnosticArchive.retain(id: c.id, drafts: drafts, destination: retained))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
    }

    func testTemporaryExpiryNeverDeletesRetainedPackages() throws {
        let base = root(), drafts = base.appendingPathComponent("Drafts"), retained = base.appendingPathComponent("Retained")
        let c = context(), folder = try VisionDiagnosticArchive.prepare(c, root: drafts)
        _ = try VisionDiagnosticArchive.seal(context: c, folder: folder, state: "failed", reason: "neverStarted", error: nil, video: nil)
        _ = try VisionDiagnosticArchive.retain(id: c.id, drafts: drafts, destination: retained)
        let old = context(), oldFolder = try VisionDiagnosticArchive.prepare(old, root: drafts)
        _ = try VisionDiagnosticArchive.seal(context: old, folder: oldFolder, state: "failed", reason: "neverStarted", error: nil, video: nil)
        try VisionDiagnosticArchive.pruneDrafts(root: drafts, now: Date().addingTimeInterval(25 * 3600))
        XCTAssertTrue(try VisionDiagnosticArchive.list(root: drafts).isEmpty)
        XCTAssertEqual(try VisionDiagnosticArchive.list(root: retained).map(\.id), [c.id])
    }
}
