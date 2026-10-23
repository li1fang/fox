import AVFoundation
import Foundation

// All append/finish calls belong to PoseCamera's serial queue. Hashing runs after the writer closes.
final class VisionDiagnosticRecorder {
    let context: VisionDiagnosticContext
    let folder: URL
    private let completed: (Result<VisionDiagnosticManifest, Error>) -> Void
    private var logs: [String: FileHandle] = [:]
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var origin: Double?
    private var lastPTS: Double?
    private var dimensions: (Int, Int)?
    private var encoded = 0
    private var dropped = 0
    private var finishing = false
    private var failure: String?
    private var lastAutomaticCount: Int?
    private let began = ProcessInfo.processInfo.systemUptime

    init(context: VisionDiagnosticContext, root: URL,
         completed: @escaping (Result<VisionDiagnosticManifest, Error>) -> Void) throws {
        self.context = context; self.completed = completed
        folder = try VisionDiagnosticArchive.prepare(context, root: root)
        for name in ["frames.jsonl", "poses.jsonl", "events.jsonl"] {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw VisionDiagnosticArchive.error("无法创建诊断日志。") }
            logs[name] = try FileHandle(forWritingTo: url)
        }
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        guard let file = logs[name] else { throw VisionDiagnosticArchive.error("诊断日志已关闭。") }
        try file.write(contentsOf: VisionDiagnosticArchive.encode(value))
        try file.write(contentsOf: Data("\n".utf8))
    }

    @discardableResult
    func append(_ sample: CMSampleBuffer) -> String? {
        guard !finishing else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, pts.seconds.isFinite, let pixels = CMSampleBufferGetImageBuffer(sample) else {
            failure = "无效相机帧。"; return "invalidSample"
        }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        if let dimensions, (dimensions.0 != width || dimensions.1 != height) { return "frameGeometryChanged" }
        if ProcessInfo.processInfo.systemUptime - began >= context.maximumSeconds { return "durationLimit" }
        if let origin, pts.seconds - origin >= context.maximumSeconds { return "durationLimit" }
        do {
            if writer == nil {
                let writer = try AVAssetWriter(outputURL: folder.appendingPathComponent("video.partial.mp4"), fileType: .mp4)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: width, AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_800_000,
                        AVVideoAllowFrameReorderingKey: false]])
                input.expectsMediaDataInRealTime = true
                guard writer.canAdd(input) else { throw VisionDiagnosticArchive.error("不支持当前视频格式。") }
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? VisionDiagnosticArchive.error("无法开始视频编码。") }
                writer.startSession(atSourceTime: pts)
                self.writer = writer; self.input = input; dimensions = (width, height); origin = pts.seconds
            }
            guard let input, let writer, let origin else { throw VisionDiagnosticArchive.error("编码器未就绪。") }
            let ordered = lastPTS.map { pts.seconds > $0 } ?? true
            let accepted = ordered && input.isReadyForMoreMediaData && input.append(sample)
            if accepted { encoded += 1; lastPTS = pts.seconds } else { dropped += 1 }
            struct Frame: Encodable {
                var capturePTS: Double; var videoSeconds: Double; var receivedUptime: Double
                var width: Int; var height: Int; var encoded: Bool; var reason: String?
            }
            try write(Frame(capturePTS: pts.seconds, videoSeconds: pts.seconds - origin,
                receivedUptime: ProcessInfo.processInfo.systemUptime, width: width, height: height,
                encoded: accepted, reason: accepted ? nil : (ordered ? "encoderBackpressure" : "outOfOrder")), to: "frames.jsonl")
            if writer.status == .failed { throw writer.error ?? VisionDiagnosticArchive.error("视频编码失败。") }
            if encoded == 0 { throw VisionDiagnosticArchive.error("首帧未被编码器接收，请重试录像。") }
            if encoded % 30 == 0 {
                let bytes = (try? folder.appendingPathComponent("video.partial.mp4").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if bytes > 200 * 1024 * 1024 { return "sizeLimit" }
            }
        } catch { failure = error.localizedDescription; return "writerFailure" }
        return nil
    }

    func appendPose(_ value: VisionDiagnosticPose) {
        guard !finishing else { return }
        do {
            var value = value; value.videoSeconds = origin.map { value.capturePTS - $0 }
            try write(value, to: "poses.jsonl")
            lastAutomaticCount = value.automaticCount
        } catch { failure = error.localizedDescription; finish(reason: "logFailure") }
    }

    func event(_ value: VisionDiagnosticEvent) {
        guard !finishing else { return }
        do { try write(value, to: "events.jsonl") }
        catch { failure = error.localizedDescription; finish(reason: "logFailure") }
    }

    func finish(reason: String) {
        guard !finishing else { return }
        finishing = true
        do { try write(VisionDiagnosticEvent(kind: "recordingEnded", detail: reason), to: "events.jsonl") }
        catch { failure = failure ?? error.localizedDescription }
        for file in logs.values { try? file.synchronize(); try? file.close() }; logs = [:]
        let folder = self.folder, context = self.context, callback = completed, failure = self.failure
        let automaticCount = lastAutomaticCount
        let video = origin.flatMap { origin in dimensions.map { dimensions in
            VisionDiagnosticManifest.Video(width: dimensions.0, height: dimensions.1, firstCapturePTS: origin,
                lastCapturePTS: lastPTS ?? origin, encodedFrames: encoded, droppedFrames: dropped)
        } }
        let seal: (Bool, String?) -> Void = { succeeded, writerError in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let message = failure ?? writerError
                    let partial = folder.appendingPathComponent("video.partial.mp4")
                    if succeeded { try FileManager.default.moveItem(at: partial, to: folder.appendingPathComponent("video.mp4")) }
                    let interrupted = ["background", "cameraStopped", "cameraInterrupted", "frameGeometryChanged", "processEnded"].contains(reason)
                    let state = message != nil || !succeeded ? "failed" : (interrupted ? "interrupted" : "complete")
                    callback(.success(try VisionDiagnosticArchive.seal(context: context, folder: folder,
                        state: state, reason: reason, error: message ?? (succeeded ? nil : "没有可播放视频；诊断元数据已保留。"),
                        video: succeeded ? video : nil, automaticCount: automaticCount)))
                } catch { callback(.failure(error)) }
            }
        }
        if let writer, encoded > 0, writer.status == .writing {
            input?.markAsFinished()
            writer.finishWriting { seal(writer.status == .completed, writer.error?.localizedDescription) }
        } else {
            writer?.cancelWriting()
            seal(false, writer?.error?.localizedDescription)
        }
    }

    static func syntheticSample(timestamp: Double, width: Int = 720, height: Int = 1280) throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw VisionDiagnosticArchive.error("无法创建测试画面。") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(buffer) { memset(bytes, 64, CVPixelBufferGetBytesPerRow(buffer) * height) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescriptionOut: &format) == noErr, let format else { throw VisionDiagnosticArchive.error("测试画面格式无效。") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 10),
            presentationTimeStamp: CMTime(seconds: timestamp, preferredTimescale: 60000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw VisionDiagnosticArchive.error("无法创建测试视频帧。") }
        return sample
    }
}
