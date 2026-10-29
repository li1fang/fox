import AVFoundation
import Foundation

/// Receives raw camera samples on the capture queue; it has no pose, exercise or training dependency.
final class FreeCaptureVideoWriter {
    struct Frame {
        var capturePTS: CMTime
        var videoTime: CMTime?
        var encoded: Bool
        var reason: String?
        var width: Int
        var height: Int
    }
    struct Summary {
        var firstPTS: CMTime
        var lastPTS: CMTime
        var width: Int
        var height: Int
        var encodedFrames: Int
        var droppedFrames: Int
    }
    enum Stop: String, Error, LocalizedError {
        case invalidSample, frameGeometryChanged, clockDiscontinuity, durationLimit, sizeLimit, writerFailure, alreadyFinishing
        var errorDescription: String? { "录像结束原因：\(rawValue)" }
    }
    let folder: URL
    private let maximumSeconds: Double
    private let beforeCreatingWriter: (() -> Void)?
    private let began = ProcessInfo.processInfo.systemUptime
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var lastCapturePTS: CMTime?
    private var dimensions: (Int, Int)?
    private(set) var encodedFrames = 0
    private(set) var droppedFrames = 0
    private let finishLock = NSLock()
    private var finishing = false
    private var finalResult: Result<Summary?, Error>?
    private var completions: [(Result<Summary?, Error>) -> Void] = []

    init(folder: URL, maximumSeconds: Double = 300, beforeCreatingWriter: (() -> Void)? = nil) throws {
        self.folder = folder; self.maximumSeconds = maximumSeconds; self.beforeCreatingWriter = beforeCreatingWriter
        guard maximumSeconds.isFinite, maximumSeconds > 0,
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.mp4").path),
              !FileManager.default.fileExists(atPath: folder.appendingPathComponent("video.partial.mp4").path) else {
            throw VisionDiagnosticArchive.error("录像文件已存在或时长无效，未覆盖。")
        }
    }
    @discardableResult
    func append(_ sample: CMSampleBuffer) throws -> Frame {
        // Serialize admission through append with finalization; finish cannot seal an empty
        // writer while an admitted frame is still creating the first video file.
        finishLock.lock(); defer { finishLock.unlock() }
        guard !finishing else { throw Stop.alreadyFinishing }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid, pts.isNumeric, pts.seconds.isFinite, let pixels = CMSampleBufferGetImageBuffer(sample) else { throw Stop.invalidSample }
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        if let firstPTS, firstPTS.epoch != pts.epoch { throw Stop.clockDiscontinuity }
        if let dimensions, dimensions != (width, height) { throw Stop.frameGeometryChanged }
        if ProcessInfo.processInfo.systemUptime - began >= maximumSeconds || firstPTS.map({ CMTimeSubtract(pts, $0).seconds >= maximumSeconds }) == true {
            throw Stop.durationLimit
        }
        if writer == nil {
            beforeCreatingWriter?()
            let candidate = try AVAssetWriter(outputURL: folder.appendingPathComponent("video.partial.mp4"), fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_800_000, AVVideoAllowFrameReorderingKey: false]])
            input.expectsMediaDataInRealTime = true
            guard candidate.canAdd(input) else { throw Stop.writerFailure }
            candidate.add(input)
            guard candidate.startWriting() else { throw candidate.error ?? Stop.writerFailure }
            candidate.startSession(atSourceTime: pts)
            writer = candidate; self.input = input; firstPTS = pts; dimensions = (width, height)
        }
        guard let writer, let input, let firstPTS else { throw Stop.writerFailure }
        let ordered = lastCapturePTS.map { CMTimeCompare(pts, $0) > 0 } ?? true
        if ordered { lastCapturePTS = pts }
        let accepted = ordered && input.isReadyForMoreMediaData && input.append(sample)
        if accepted { encodedFrames += 1; lastPTS = pts } else { droppedFrames += 1 }
        guard writer.status != .failed else { throw writer.error ?? Stop.writerFailure }
        guard encodedFrames > 0 else { throw Stop.writerFailure }
        if encodedFrames % 30 == 0 {
            let bytes = try folder.appendingPathComponent("video.partial.mp4").resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if bytes > 200 * 1024 * 1024 { throw Stop.sizeLimit }
        }
        return Frame(capturePTS: pts, videoTime: CMTimeSubtract(pts, firstPTS), encoded: accepted,
            reason: accepted ? nil : (ordered ? "encoderBackpressure" : "outOfOrder"), width: width, height: height)
    }
    func finish(_ completion: @escaping (Result<Summary?, Error>) -> Void) {
        finishLock.lock()
        if let result = finalResult { finishLock.unlock(); completion(result); return }
        completions.append(completion)
        if finishing { finishLock.unlock(); return }
        finishing = true; finishLock.unlock()
        guard let writer, encodedFrames > 0, let firstPTS, let lastPTS, let dimensions else {
            writer?.cancelWriting(); complete(.success(nil)); return
        }
        let summary = Summary(firstPTS: firstPTS, lastPTS: lastPTS, width: dimensions.0, height: dimensions.1,
                              encodedFrames: encodedFrames, droppedFrames: droppedFrames)
        guard writer.status == .writing else { complete(.failure(writer.error ?? Stop.writerFailure)); return }
        input?.markAsFinished()
        writer.finishWriting { [self] in
            do {
                guard writer.status == .completed else { throw writer.error ?? Stop.writerFailure }
                try FileManager.default.moveItem(at: folder.appendingPathComponent("video.partial.mp4"), to: folder.appendingPathComponent("video.mp4"))
                complete(.success(summary))
            } catch { complete(.failure(error)) }
        }
    }
    private func complete(_ result: Result<Summary?, Error>) {
        finishLock.lock(); finalResult = result; let callbacks = completions; completions = []; finishLock.unlock()
        callbacks.forEach { $0(result) }
    }
}
