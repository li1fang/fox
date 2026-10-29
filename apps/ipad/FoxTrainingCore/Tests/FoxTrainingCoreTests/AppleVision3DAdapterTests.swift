import XCTest
import FoxTrainingCore
@testable import FoxVision3D
#if canImport(Vision) && canImport(AVFoundation)
import AVFoundation
import ImageIO
final class AppleVision3DAdapterTests: XCTestCase {
    private func pixels() throws -> CVPixelBuffer {
        var p: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA, nil, &p), kCVReturnSuccess)
        return try XCTUnwrap(p)
    }
    private func context(_ frame: Int = 0) -> Pose3DFrameContext {
        .init(streamID: "capture", segmentID: "s", frameIndex: frame, pts: .init(value: 900, timescale: 30000), width: 32, height: 32, orientation: 6)
    }
    func testTimestampAndOrientationReachRunnerAndEmptyIsNotFailure() throws {
        let extractor = AppleVision3DExtractor { sample, orientation, revision in
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).value, 900)
            XCTAssertEqual(orientation, .right); XCTAssertEqual(revision, 1)
            return .init(revision: revision, skeletons: [])
        }
        let result = extractor.extract(try pixels(), pts: CMTime(value: 900, timescale: 30000), orientation: .right, context: context())
        XCTAssertEqual(result.outcome, .noObservation); XCTAssertEqual(result.context, context())
        try result.validate()
    }
    func testInvalidInputUnsupportedRevisionAndRequestFailureAreDistinct() throws {
        let p = try pixels()
        let unavailable = AppleVision3DExtractor { _,_,_ in throw Vision3DBackendError.unsupported }
        XCTAssertEqual(unavailable.extract(p, pts: .zero, orientation: .right, context: context()).outcome, .invalidInput)
        XCTAssertEqual(unavailable.extract(p, pts: CMTime(value: 900,timescale: 30000), orientation: .right, context: context()).outcome, .unsupported)
        let failed = AppleVision3DExtractor { _,_,_ in throw NSError(domain: "test.backend", code: 42) }
        let result = failed.extract(p, pts: CMTime(value: 900,timescale: 30000), orientation: .right, context: context())
        XCTAssertEqual(result.outcome, .requestFailed); XCTAssertEqual(result.failure?.code, 42)
        try result.validate()
        let wrong = AppleVision3DExtractor { _,_,_ in .init(revision: 2, skeletons: []) }
        XCTAssertEqual(wrong.extract(p, pts: CMTime(value: 900,timescale: 30000), orientation: .right, context: context()).outcome, .invalidOutput)
    }
    func testBusyExtractorDropsWithoutQueueAndRecovers() throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let extractor = AppleVision3DExtractor { _,_,r in entered.signal(); _ = release.wait(timeout: .now()+3); return .init(revision: r, skeletons: []) }
        let p = try pixels(), sample = try AppleVision3DExtractor.makeSampleBuffer(p, pts: CMTime(value: 900,timescale: 30000))
        let finished = expectation(description: "one request finishes")
        DispatchQueue.global().async { _ = extractor.extract(sample, orientation: .right, context: self.context()); finished.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now()+3), .success)
        let dropped = extractor.extract(sample, orientation: .right, context: context())
        XCTAssertEqual(dropped.outcome, .dropped); XCTAssertEqual(dropped.inferenceNanoseconds, 0)
        release.signal(); wait(for: [finished], timeout: 3)
        release.signal()
        XCTAssertEqual(extractor.extract(sample, orientation: .right, context: context()).outcome, .noObservation)
    }
    func testEquivalentTimeCannotRewriteOriginalTimestampIntegers() throws {
        let p = try pixels()
        let changed = Pose3DFrameContext(streamID: "capture", segmentID: "s", frameIndex: 0,
            pts: .init(value: 3, timescale: 100), width: 32, height: 32, orientation: 6)
        let extractor = AppleVision3DExtractor { _,_,r in .init(revision: r, skeletons: []) }
        XCTAssertEqual(extractor.extract(p, pts: CMTime(value: 900, timescale: 30000), orientation: .right, context: changed).outcome, .invalidInput)
    }

    func testCompletePredictionIsExportedButPartialAndMultipleSkeletonsAreRejected() throws {
        let matrix: [Double] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        let skeleton = Pose3DSkeleton(joints: Pose3DJointName.allCases.map { .init(name: $0, modelTransform: matrix) },
            cameraOriginMatrix: matrix, bodyHeightMeters: 1.8, heightSource: .reference)
        let p = try pixels()
        for count in [1,2] {
            let extractor = AppleVision3DExtractor { _,_,r in .init(revision: r, skeletons: Array(repeating: skeleton, count: count)) }
            let result = extractor.extract(p, pts: CMTime(value: 900,timescale: 30000), orientation: .right, context: context())
            XCTAssertEqual(result.outcome, count == 1 ? .observed : .invalidOutput)
            if count == 1 { XCTAssertEqual(result.skeleton, skeleton) }
            try result.validate()
        }
        let partial = Pose3DSkeleton(joints: [], cameraOriginMatrix: matrix, bodyHeightMeters: 1.8, heightSource: .reference)
        let extractor = AppleVision3DExtractor { _,_,r in .init(revision: r, skeletons: [partial]) }
        XCTAssertEqual(extractor.extract(p, pts: CMTime(value: 900,timescale: 30000), orientation: .right, context: context()).outcome, .invalidOutput)
    }

}
#endif
