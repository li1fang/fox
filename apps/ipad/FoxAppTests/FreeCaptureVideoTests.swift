import AVFoundation
import XCTest
@testable import Fox

final class FreeCaptureVideoTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FreeCapture-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testRawFramesEncodeWithoutAnyPoseAndPreserveExactPTSAndNoAudio() async throws {
        let folder = try root(), writer = try FreeCaptureVideoWriter(folder: folder)
        let original = CMTime(value: 6_000_001, timescale: 60_000)
        let first = try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: original.seconds, width: 64, height: 96))
        XCTAssertTrue(first.encoded)
        XCTAssertEqual(CMTimeCompare(try XCTUnwrap(first.videoTime), .zero), 0)
        XCTAssertEqual(CMTimeCompare(first.capturePTS, original), 0)
        try await Task.sleep(nanoseconds: 30_000_000)
        let next = try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: original.seconds + 0.1, width: 64, height: 96))
        XCTAssertEqual(next.videoTime?.seconds ?? -1, 0.1, accuracy: 0.0001)
        let summary = try await finish(writer)
        XCTAssertGreaterThan(try XCTUnwrap(summary).encodedFrames, 0)
        let asset = AVURLAsset(url: folder.appendingPathComponent("video.mp4"))
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.partial.mp4").path))
    }
    func testDuplicatePTSIsRecordedAsDroppedAndCannotAdvanceOriginOrFrameCount() async throws {
        let writer = try FreeCaptureVideoWriter(folder: root())
        let sample = try VisionDiagnosticRecorder.syntheticSample(timestamp: 50, width: 64, height: 96)
        XCTAssertTrue(try writer.append(sample).encoded)
        let duplicate = try writer.append(sample)
        XCTAssertFalse(duplicate.encoded); XCTAssertEqual(duplicate.reason, "outOfOrder")
        let completed = try await finish(writer)
        let summary = try XCTUnwrap(completed)
        XCTAssertEqual(summary.encodedFrames, 1); XCTAssertEqual(summary.droppedFrames, 1)
        XCTAssertEqual(summary.firstPTS.seconds, 50); XCTAssertEqual(summary.lastPTS.seconds, 50)
    }
    func testGeometryChangePreservesExistingVideoAndDoesNotMixFormats() async throws {
        let writer = try FreeCaptureVideoWriter(folder: root())
        _ = try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: 20, width: 64, height: 96))
        XCTAssertThrowsError(try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: 20.1, width: 96, height: 64)))
        let completed = try await finish(writer)
        let summary = try XCTUnwrap(completed)
        XCTAssertEqual(summary.width, 64); XCTAssertEqual(summary.height, 96); XCTAssertEqual(summary.encodedFrames, 1)
    }
    func testZeroFramesAndDuplicateFinishNeverClaimPlayableVideo() async throws {
        let writer = try FreeCaptureVideoWriter(folder: root())
        let first = try await finish(writer)
        XCTAssertNil(first)
        let again = try await finish(writer)
        XCTAssertNil(again)
    }
    func testExistingVideoIsNeverOverwrittenAndDurationLimitKeepsFirstFrame() async throws {
        let folder = try root(), original = Data("original".utf8)
        try original.write(to: folder.appendingPathComponent("video.mp4"))
        XCTAssertThrowsError(try FreeCaptureVideoWriter(folder: folder))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("video.mp4")), original)
        let writer = try FreeCaptureVideoWriter(folder: root(), maximumSeconds: 1)
        _ = try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: 10, width: 64, height: 96))
        XCTAssertThrowsError(try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: 11.1, width: 64, height: 96)))
        let completed = try await finish(writer)
        XCTAssertEqual(completed?.encodedFrames, 1)
    }
    func testFinishingCannotPublishEmptyResultWhileFirstAdmittedFrameIsPaused() async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let requested = DispatchSemaphore(value: 0), sealed = DispatchSemaphore(value: 0)
        let appended = expectation(description: "first frame appended"), finished = expectation(description: "video sealed")
        let writer = try FreeCaptureVideoWriter(folder: root(), beforeCreatingWriter: {
            entered.signal(); _ = release.wait(timeout: .now() + 5)
        })
        let sample = try VisionDiagnosticRecorder.syntheticSample(timestamp: 100, width: 64, height: 96)
        var result: Result<FreeCaptureVideoWriter.Summary?, Error>?
        DispatchQueue.global().async {
            do { _ = try writer.append(sample) } catch { XCTFail("First admitted frame failed: \(error)") }
            appended.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            requested.signal()
            writer.finish { value in result = value; sealed.signal(); finished.fulfill() }
        }
        XCTAssertEqual(requested.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(sealed.wait(timeout: .now() + 0.05), .timedOut, "An admitted first frame must finish before an empty result can be published")
        release.signal()
        await fulfillment(of: [appended, finished], timeout: 10)
        let outcome = try XCTUnwrap(result).get()
        XCTAssertEqual(outcome?.encodedFrames, 1)
    }
    func testRawCaptureOrderIsEnforcedIndependentlyOfEncoderBackpressure() async throws {
        let writer = try FreeCaptureVideoWriter(folder: root())
        _ = try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: 100, width: 64, height: 96))
        _ = try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: 103, width: 64, height: 96))
        let reordered = try writer.append(VisionDiagnosticRecorder.syntheticSample(timestamp: 102, width: 64, height: 96))
        XCTAssertFalse(reordered.encoded)
        XCTAssertEqual(reordered.reason, "outOfOrder", "Raw time cannot regress even if encoding rejected the previous input")
        _ = try await finish(writer)
    }
    private func finish(_ writer: FreeCaptureVideoWriter) async throws -> FreeCaptureVideoWriter.Summary? {
        try await withCheckedThrowingContinuation { continuation in writer.finish { continuation.resume(with: $0) } }
    }
}
