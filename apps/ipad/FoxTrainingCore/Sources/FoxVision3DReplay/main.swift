import Foundation
import FoxTrainingCore
#if os(macOS)
import AVFoundation
import CryptoKit
import ImageIO
import FoxVision3D
import Darwin

struct ReplayHeader: Encodable {
    let schema = "fox.pose3d_replay.v1"
    let inputSHA256: String
    let inputBytes: Int
    let requestedFrames: Int
    let orientation: UInt32
    let systemVersion: String
    let evidenceBoundary = "Predicted prominent-person skeletons; no count, phase truth, calibrated distance or 2D subject match."
}
func run() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count == 4, let frames = Int(args[2]), (1...30).contains(frames),
          let raw = UInt32(args[3]), let orientation = CGImagePropertyOrientation(rawValue: raw) else {
        throw NSError(domain: "fox.pose3d.cli.usage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: fox-vision3d-replay INPUT OUTPUT_DIRECTORY MAX_FRAMES(1...30) EXIF_ORIENTATION(1...8). Input must be a regular small video <=64MiB; orientation is explicit, not auto-applied twice."])
    }
    func checkSpace() throws {
        var info = statfs()
        guard statfs(NSHomeDirectory(), &info) == 0,
              UInt64(info.f_bavail)*UInt64(info.f_bsize) >= 2*1024*1024*1024 else { throw NSError(domain: "fox.pose3d.cli.low_space", code: 1) }
    }
    try checkSpace()
    let input = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])
    let values = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size > 0, size <= 64*1024*1024 else { throw NSError(domain: "fox.pose3d.cli.input", code: 1) }
    guard !FileManager.default.fileExists(atPath: output.path) else { throw NSError(domain: "fox.pose3d.cli.output_exists", code: 1) }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let file = try FileHandle(forReadingFrom: input); defer { try? file.close() }
    var hasher = SHA256()
    while let bytes = try file.read(upToCount: 1024*1024), !bytes.isEmpty { hasher.update(data: bytes) }
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let header = ReplayHeader(inputSHA256: digest, inputBytes: size, requestedFrames: frames, orientation: raw, systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
    try encoder.encode(header).write(to: output.appendingPathComponent("input.json"), options: .withoutOverwriting)
    let partial = output.appendingPathComponent("frames.partial.jsonl")
    FileManager.default.createFile(atPath: partial.path, contents: nil)
    let handle = try FileHandle(forWritingTo: partial); defer { try? handle.close() }
    let asset = AVURLAsset(url: input)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "fox.pose3d.cli.no_video", code: 1) }
    let formats = try await track.load(.formatDescriptions)
    guard !formats.isEmpty, formats.allSatisfy({
        let d = CMVideoFormatDescriptionGetDimensions($0)
        return d.width > 0 && d.height > 0 && d.width <= 4096 && d.height <= 4096 && Int64(d.width)*Int64(d.height) <= 4_194_304
    }) else { throw NSError(domain: "fox.pose3d.cli.dimensions", code: 1) }
    let reader = try AVAssetReader(asset: asset)
    let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    decoded.alwaysCopiesSampleData = false
    guard reader.canAdd(decoded) else { throw NSError(domain: "fox.pose3d.cli.reader", code: 1) }
    reader.add(decoded)
    guard reader.startReading() else { throw reader.error ?? NSError(domain: "fox.pose3d.cli.reader", code: 2) }
    defer { reader.cancelReading() }
    let extractor = AppleVision3DExtractor()
    var previous: Pose3DFrameContext?, processed = 0, outcomes: [String:Int] = [:]
    for index in 0..<frames {
        try checkSpace()
        guard let sample = decoded.copyNextSampleBuffer() else { break }
        try autoreleasepool {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw Pose3DContractError.invalid }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            let stamp = time.isNumeric ? Pose3DTime(value: time.value, timescale: time.timescale, epoch: time.epoch) : nil
            let context = Pose3DFrameContext(streamID: digest, segmentID: "video-track-0", frameIndex: index, pts: stamp,
                width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels), orientation: raw,
                sourceMirrored: [.upMirrored,.downMirrored,.leftMirrored,.rightMirrored].contains(orientation))
            if let previous { _ = try context.missingFrames(after: previous) }
            previous = context
            let result = extractor.extract(sample, orientation: orientation, context: context)
            try result.validate()
            try handle.write(contentsOf: encoder.encode(result)); try handle.write(contentsOf: Data([10]))
            outcomes[result.outcome.rawValue, default: 0] += 1; processed += 1
        }
    }
    guard processed > 0, reader.status != .failed else { throw reader.error ?? NSError(domain: "fox.pose3d.cli.empty", code: 1) }
    // Failed requests retain per-frame receipts but do not become a successful smoke.
    let failures = outcomes.filter { !["observed", "noObservation"].contains($0.key) }.values.reduce(0,+)
    let summary: [String:Any] = ["schema":"fox.pose3d_replay_receipt.v1", "processed":processed, "outcomes":outcomes,
        "status":failures == 0 ? "requests_completed_not_accuracy_acceptance" : "requests_with_failures", "inputSHA256":digest]
    try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]).write(to: output.appendingPathComponent("receipt.json"), options: .withoutOverwriting)
    try handle.synchronize()
    try FileManager.default.moveItem(at: partial, to: output.appendingPathComponent("frames.jsonl"))
    if failures > 0 { throw NSError(domain: "fox.pose3d.cli.requests_failed", code: failures) }
    print("Processed \(processed) frames; predicted skeleton quality not assessed.")
}
do { try await run() } catch { fputs("\(error)\n", stderr); exit(1) }
#else
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
fputs("fox-vision3d-replay requires macOS with AVFoundation/Vision.\n", stderr)
exit(1)
#endif
