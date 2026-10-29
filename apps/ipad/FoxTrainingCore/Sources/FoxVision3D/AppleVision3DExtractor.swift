import Foundation
import FoxTrainingCore
#if canImport(Vision) && canImport(AVFoundation)
import Vision
import AVFoundation
import ImageIO

struct Vision3DRequestOutput {
    let revision: Int
    let skeletons: [Pose3DSkeleton]
}
enum Vision3DBackendError: Error { case unsupported }

/// Side-channel only. One in-flight request, no waiting queue, no shared Vision
/// request history across frames/streams. Caller retains input until return.
public final class AppleVision3DExtractor {
    public let revision: Int
    private let lock = NSLock()
    private let runner: (CMSampleBuffer, CGImagePropertyOrientation, Int) throws -> Vision3DRequestOutput
    public init(revision: Int = 1) { self.revision = revision; runner = Self.perform }
    init(revision: Int = 1, runner: @escaping (CMSampleBuffer, CGImagePropertyOrientation, Int) throws -> Vision3DRequestOutput) {
        self.revision = revision; self.runner = runner
    }
    public func extract(_ sampleBuffer: CMSampleBuffer, orientation: CGImagePropertyOrientation, context: Pose3DFrameContext) -> Pose3DFrame {
        func result(_ outcome: Pose3DOutcome, _ failure: Pose3DFailure? = nil, actual: Int? = nil,
                    skeleton: Pose3DSkeleton? = nil, nanos: UInt64 = 0) -> Pose3DFrame {
            .init(context: context, requestedRevision: revision, actualRevision: actual, outcome: outcome,
                  skeleton: skeleton, failure: failure, inferenceNanoseconds: nanos)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard (try? context.validate()) != nil, revision > 0, orientation.rawValue == context.orientation,
              CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer), pts.isNumeric,
              context.pts == Pose3DTime(value: pts.value, timescale: pts.timescale, epoch: pts.epoch),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(pixels) == context.width, CVPixelBufferGetHeight(pixels) == context.height else {
            return result(.invalidInput, .init(domain: "fox.pose3d.input", code: 1))
        }
        guard lock.try() else { return result(.dropped, .init(domain: "fox.pose3d.busy", code: 1)) }
        defer { lock.unlock() }
        let start = DispatchTime.now().uptimeNanoseconds
        func elapsed() -> UInt64 { DispatchTime.now().uptimeNanoseconds - start }
        do {
            let output = try runner(sampleBuffer, orientation, revision)
            guard output.revision == revision, output.skeletons.count <= 1 else {
                return result(.invalidOutput, .init(domain: "fox.pose3d.output", code: 1), actual: output.revision, nanos: elapsed())
            }
            if let skeleton = output.skeletons.first {
                guard (try? skeleton.validate()) != nil else {
                    return result(.invalidOutput, .init(domain: "fox.pose3d.output", code: 2), actual: output.revision, nanos: elapsed())
                }
                return result(.observed, actual: output.revision, skeleton: skeleton, nanos: elapsed())
            }
            return result(.noObservation, actual: output.revision, nanos: elapsed())
        } catch Vision3DBackendError.unsupported {
            return result(.unsupported, .init(domain: "fox.pose3d.availability", code: 1), nanos: elapsed())
        } catch {
            let error = error as NSError
            // Do not export localized descriptions that may include private paths.
            return result(.requestFailed, .init(domain: error.domain, code: error.code), nanos: elapsed())
        }
    }
    public func extract(_ pixels: CVPixelBuffer, pts: CMTime, orientation: CGImagePropertyOrientation,
                        context: Pose3DFrameContext, cameraIntrinsics: Data? = nil) -> Pose3DFrame {
        do {
            let sample = try Self.makeSampleBuffer(pixels, pts: pts)
            if let cameraIntrinsics {
                CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                value: cameraIntrinsics as CFData, attachmentMode: kCMAttachmentMode_ShouldPropagate)
            }
            return extract(sample, orientation: orientation, context: context)
        } catch {
            return .init(context: context, requestedRevision: revision, outcome: .invalidInput,
                         failure: .init(domain: "fox.pose3d.sample", code: (error as NSError).code))
        }
    }
    static func makeSampleBuffer(_ pixels: CVPixelBuffer, pts: CMTime) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let made = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                         formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard made == noErr, let sample else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(made)) }
        return sample
    }
    private static func perform(_ sample: CMSampleBuffer, _ orientation: CGImagePropertyOrientation, _ revision: Int) throws -> Vision3DRequestOutput {
        guard #available(iOS 17, macOS 14, tvOS 17, *) else { throw Vision3DBackendError.unsupported }
        guard VNDetectHumanBodyPose3DRequest.supportedRevisions.contains(revision) else { throw Vision3DBackendError.unsupported }
        let request = VNDetectHumanBodyPose3DRequest(); request.revision = revision
        try VNImageRequestHandler(cmSampleBuffer: sample, orientation: orientation, options: [:]).perform([request])
        func matrix(_ m: simd_float4x4) -> [Double] {
            [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
        }
        let names: [(Pose3DJointName, VNHumanBodyPose3DObservation.JointName)] = [
            (.root,.root),(.spine,.spine),(.centerShoulder,.centerShoulder),(.centerHead,.centerHead),(.topHead,.topHead),
            (.leftShoulder,.leftShoulder),(.rightShoulder,.rightShoulder),(.leftElbow,.leftElbow),(.rightElbow,.rightElbow),
            (.leftWrist,.leftWrist),(.rightWrist,.rightWrist),(.leftHip,.leftHip),(.rightHip,.rightHip),
            (.leftKnee,.leftKnee),(.rightKnee,.rightKnee),(.leftAnkle,.leftAnkle),(.rightAnkle,.rightAnkle)]
        let skeletons = try (request.results ?? []).map { observation in
            let joints = try names.map { Pose3DJoint(name: $0.0, modelTransform: matrix(try observation.recognizedPoint($0.1).position)) }
            let height: Pose3DHeightSource
            switch observation.heightEstimation {
            case .reference: height = .reference
            case .measured: height = .measured
            @unknown default: throw Pose3DContractError.invalid
            }
            return Pose3DSkeleton(joints: joints, cameraOriginMatrix: matrix(observation.cameraOriginMatrix),
                                  bodyHeightMeters: Double(observation.bodyHeight), heightSource: height)
        }
        return .init(revision: request.revision, skeletons: skeletons)
    }
}
#endif
