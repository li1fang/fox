import Foundation
import FoxTrainingCore
#if os(macOS)
import AVFoundation
import Vision
import CryptoKit

struct Corpus: Decodable {
    struct Segment: Decodable {
        var id: String; var start: Double; var end: Double; var exercise: VisionExercise?
        var declared_arm: String?; var peak_candidates_seconds: [Double]
    }
    struct Checkpoint: Codable {
        var seconds: Double; var minX: Double; var maxX: Double; var minY: Double; var maxY: Double
    }
    var schema: String; var asset: String; var sha256: String; var duration_seconds: Double
    var segments: [Segment]; var subject_checkpoints: [Checkpoint]
}
struct CacheHeader: Codable {
    var schema = "fox.video_pose_cache.v1"
    var videoSHA256: String
    var platform: String
    var revision: Int
    var sampledHz: Double
    var fullFrame = true
    var audioInput = false
}
func write<T: Encodable>(_ value: T, to handle: FileHandle, newline: Bool = true) throws {
    try handle.write(contentsOf: JSONEncoder().encode(value))
    if newline { try handle.write(contentsOf: Data("\n".utf8)) }
}
func checksum(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func extract(_ video: URL, header: CacheHeader, output: URL, duration: Double) throws {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1280, height: 1280)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let request = VNDetectHumanBodyPoseRequest(); request.revision = header.revision
    let joints: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .nose), (.neck, .neck), (.root, .root), (.leftShoulder, .leftShoulder), (.rightShoulder, .rightShoulder),
        (.leftElbow, .leftElbow), (.rightElbow, .rightElbow), (.leftWrist, .leftWrist), (.rightWrist, .rightWrist),
        (.leftHip, .leftHip), (.rightHip, .rightHip), (.leftKnee, .leftKnee), (.rightKnee, .rightKnee),
        (.leftAnkle, .leftAnkle), (.rightAnkle, .rightAnkle)
    ]
    let temporary = output.appendingPathExtension("partial")
    guard !FileManager.default.fileExists(atPath: output.path), !FileManager.default.fileExists(atPath: temporary.path) else {
        throw NSError(domain: "FoxVideoReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cache already exists; choose a new output path"])
    }
    FileManager.default.createFile(atPath: temporary.path, contents: nil)
    let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
    try write(header, to: handle)
    var previous = -1.0
    for index in 0..<Int(ceil(duration * header.sampledHz)) {
        try autoreleasepool {
            var actual = CMTime.zero
            let image = try generator.copyCGImage(at: CMTime(seconds: Double(index) / header.sampledHz, preferredTimescale: 60000), actualTime: &actual)
            guard actual.seconds > previous else { return }
            previous = actual.seconds
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            let people = try (request.results ?? []).map { observation -> [PoseTraceJoint] in
                let points = try observation.recognizedPoints(.all)
                return joints.compactMap { joint, name -> PoseTraceJoint? in
                    guard let p = points[name] else { return nil }
                    return PoseTraceJoint(joint: joint, x: p.location.x, y: p.location.y, confidence: Double(p.confidence))
                }
            }.filter { $0.contains(where: { $0.confidence > 0 }) }
            try write(PoseVideoRow(seconds: actual.seconds, width: Double(image.width), height: Double(image.height), people: people), to: handle)
        }
        if index % 200 == 0 { FileHandle.standardError.write(Data("Extracted \(index) full frames\n".utf8)) }
    }
    try handle.synchronize(); try FileManager.default.moveItem(at: temporary, to: output)
}
struct SelectedRow: Codable {
    var seconds: Double; var people: Int; var state: PoseSubjectState; var selectedIndex: Int?
    var shoulderX: Double?; var shoulderY: Double?; var rawAngle: Double?; var phase: CurlPhase; var reason: PoseFailureReason?; var count: Int
}
struct CheckResult: Codable { var seconds: Double; var state: PoseSubjectState; var selectedIndex: Int?; var status: String }
struct SegmentResult: Codable {
    var id: String; var side: ArmSide; var scope: String; var frames: Int
    var strictFullFrameV2Count: Int; var selectedV2Count: Int; var selectedV3Count: Int
    var firstReadyAt: Double?; var countdownReadyAt: Double?
    var subjectStates: [String: Int]; var selectedV3Resets: [String: Int]
    var checkpoints: [CheckResult]; var eventEvaluation: PoseEventEvaluation
    var negativeWindowCounts: [String: Int]; var traceFile: String
    var selectedCandidateCount: Int; var candidateAlgorithm: String; var candidateResets: [String: Int]
    var candidateEventEvaluation: PoseEventEvaluation; var candidateRepetitions: [CurlRepetition]
    var originSeconds: Double
}
struct Evaluation: Codable {
    var schema = "fox.video_replay_evaluation.v1"
    var cache: CacheHeader; var configuration: PoseCounterConfiguration; var runtimePolicy: PoseRuntimePolicy
    var cacheSHA256: String
    var countingBypassesStartCountdown = true
    var evidenceBoundary = "macOS offline video; not real-time iPad acceptance; checkpoint labels are coarse"
    var segments: [SegmentResult]
}
func evaluate(_ corpus: Corpus, header: CacheHeader, rows: [PoseVideoRow], output: URL,
              configuration: PoseCounterConfiguration, policy: PoseRuntimePolicy, cacheHash: String) throws {
    var results: [SegmentResult] = []
    for segment in corpus.segments where segment.exercise != nil {
        // Extend the preceding training segment into its negative window without reacquiring anyone.
        let end = segment.id == "A02" ? 120 : (segment.id == "front-exploration" ? corpus.duration_seconds : segment.end)
        let selectedRows = rows.filter { $0.seconds >= segment.start && $0.seconds < end }
        for side in ArmSide.allCases {
            var selector = PoseSubjectSelector(policy: policy)
            var full = CurlTracker(side: side, exercise: segment.exercise!, configuration: configuration)
            var legacyPolicy = policy; legacyPolicy.lateralTorsoReference = .sameSide
            var old = full, baseline = CurlTracker(side: side, exercise: segment.exercise!, configuration: configuration, runtimePolicy: legacyPolicy)
            var current = CurlTracker(side: side, exercise: segment.exercise!, configuration: configuration, runtimePolicy: policy)
            var startGate = PoseStartGate(lossTolerance: policy.countdownLossTolerance); startGate.arm()
            var firstReady: Double?, readyAt: Double?, states: [String: Int] = [:], trace: [SelectedRow] = []
            for row in selectedRows {
                let frame = try row.frame(); let previous = selector.selection.state
                let selection = selector.process(frame), chosen = selection.selectedFrame(from: frame)
                if selection.state == .lost && previous != .lost { old.interrupt(); baseline.interrupt(); current.interrupt() }
                let ready = PoseSubjectSelector.isReady(chosen, side: side, confidence: policy.subjectConfidence)
                if ready && firstReady == nil { firstReady = row.seconds }
                if startGate.process(timestamp: row.seconds, poseReady: ready) == .ready && readyAt == nil { readyAt = row.seconds }
                full.process(frame); old.process(chosen)
                baseline.process(chosen, originalPeopleCount: frame.people.count, selection: selection)
                current.process(chosen, originalPeopleCount: frame.people.count, selection: selection)
                states[selection.state.rawValue, default: 0] += 1
                let reading = PoseGeometry.inspect(chosen, side: side, exercise: segment.exercise!, configuration: configuration, runtimePolicy: policy)
                trace.append(SelectedRow(seconds: row.seconds, people: frame.people.count, state: selection.state,
                    selectedIndex: selection.index, shoulderX: selection.anchor?.x, shoulderY: selection.anchor?.y,
                    rawAngle: reading.angle, phase: current.snapshot.phase, reason: current.snapshot.failureReason, count: current.repetitions.count))
            }
            let origin = selectedRows.first?.seconds ?? segment.start
            let checks = corpus.subject_checkpoints.filter { $0.seconds >= segment.start && $0.seconds < end }.map { checkpoint -> CheckResult in
                let nearest = trace.min(by: { abs($0.seconds - checkpoint.seconds) < abs($1.seconds - checkpoint.seconds) })!
                let status: String
                if let x = nearest.shoulderX, let y = nearest.shoulderY {
                    status = (checkpoint.minX...checkpoint.maxX).contains(x) && (checkpoint.minY...checkpoint.maxY).contains(y)
                        ? "within-reviewed-subject-region" : "outside-reviewed-subject-region"
                } else { status = "not-selected" }
                return CheckResult(seconds: checkpoint.seconds, state: nearest.state, selectedIndex: nearest.selectedIndex, status: status)
            }
            let traceName = "\(output.deletingPathExtension().lastPathComponent)-\(segment.id)-\(side.rawValue)-trace.jsonl"
            let traceData = try trace.reduce(into: Data()) { data, item in
                data.append(try JSONEncoder().encode(item)); data.append(Data("\n".utf8))
            }
            try traceData.write(to: output.deletingLastPathComponent().appendingPathComponent(traceName), options: .atomic)
            var negative: [String: Int] = [:]
            if end > segment.end { negative["\(segment.end)-\(end)"] = current.repetitions.filter { $0.completedAtSeconds + origin >= segment.end }.count }
            results.append(SegmentResult(id: segment.id, side: side,
                scope: segment.id == "front-exploration" ? "unsupported-front-curl-diagnostic" : "adapted-exercise-candidate",
                frames: selectedRows.count, strictFullFrameV2Count: full.repetitions.count, selectedV2Count: old.repetitions.count,
                selectedV3Count: baseline.repetitions.count, firstReadyAt: firstReady, countdownReadyAt: readyAt,
                subjectStates: states, selectedV3Resets: baseline.diagnostics.resetCounts, checkpoints: checks,
                eventEvaluation: try PoseEventEvaluator.evaluate(baseline.repetitions, origin: origin, peaks: segment.peak_candidates_seconds),
                negativeWindowCounts: negative, traceFile: traceName, selectedCandidateCount: current.repetitions.count,
                candidateAlgorithm: segment.exercise!.algorithm(runtimePolicy: policy), candidateResets: current.diagnostics.resetCounts,
                candidateEventEvaluation: try PoseEventEvaluator.evaluate(current.repetitions, origin: origin, peaks: segment.peak_candidates_seconds),
                candidateRepetitions: current.repetitions, originSeconds: origin))
        }
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Evaluation(cache: header, configuration: configuration, runtimePolicy: policy, cacheSHA256: cacheHash, segments: results)).write(to: output, options: .atomic)
    print("Replay report: \(output.path)")
    for item in results { print("\(item.id) \(item.side.rawValue): full/v2/v3/candidate \(item.strictFullFrameV2Count)/\(item.selectedV2Count)/\(item.selectedV3Count)/\(item.selectedCandidateCount); unmatched labels \(item.candidateEventEvaluation.unmatchedPeakCandidates.count)") }
}
do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 3, ["extract", "evaluate"].contains(args[0]) else {
        throw NSError(domain: "FoxVideoReplay", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "Usage: fox-video-replay extract <manifest.json> <cache.jsonl> | evaluate <manifest.json> <cache.jsonl> <report.json> [configuration.json] [runtime-policy.json]"])
    }
    let manifestURL = URL(fileURLWithPath: args[1])
    let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: manifestURL))
    guard corpus.schema == "fox.video_corpus.v1", corpus.asset == URL(fileURLWithPath: corpus.asset).lastPathComponent,
          corpus.duration_seconds.isFinite, corpus.duration_seconds > 0,
          corpus.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
          Set(corpus.segments.map(\.id)).count == corpus.segments.count,
          corpus.segments.allSatisfy({ segment in
              segment.id.range(of: "^[a-zA-Z0-9_-]{1,80}$", options: .regularExpression) != nil &&
              segment.start.isFinite && segment.end.isFinite && segment.start >= 0 && segment.start < segment.end && segment.end <= corpus.duration_seconds &&
              segment.peak_candidates_seconds.allSatisfy { $0.isFinite && $0 >= segment.start && $0 < segment.end }
          }), corpus.subject_checkpoints.allSatisfy({ c in
              c.seconds.isFinite && c.seconds >= 0 && c.seconds < corpus.duration_seconds &&
              (0...1).contains(c.minX) && (c.minX...1).contains(c.maxX) && (0...1).contains(c.minY) && (c.minY...1).contains(c.maxY)
          }) else { throw VisionTrialError.invalidReport }
    let video = manifestURL.deletingLastPathComponent().appendingPathComponent(corpus.asset)
    guard try checksum(video) == corpus.sha256 else { throw VisionTrialError.invalidReport }
    let cacheURL = URL(fileURLWithPath: args[2])
    if args[0] == "extract" {
        try extract(video, header: CacheHeader(videoSHA256: corpus.sha256, platform: ProcessInfo.processInfo.operatingSystemVersionString,
            revision: VNDetectHumanBodyPoseRequest.currentRevision, sampledHz: 10), output: cacheURL, duration: corpus.duration_seconds)
    } else {
        guard args.count >= 4 else { throw VisionTrialError.invalidReport }
        let lines = try String(contentsOf: cacheURL, encoding: .utf8).split(separator: "\n")
        guard let first = lines.first else { throw VisionTrialError.invalidReport }
        let header = try JSONDecoder().decode(CacheHeader.self, from: Data(first.utf8))
        guard header.schema == "fox.video_pose_cache.v1", header.videoSHA256 == corpus.sha256, header.fullFrame, !header.audioInput,
              header.sampledHz >= 5 else { throw VisionTrialError.invalidReport }
        let rows = try lines.dropFirst().map { try JSONDecoder().decode(PoseVideoRow.self, from: Data($0.utf8)) }
        var previous = -1.0
        for row in rows { _ = try row.frame(); guard row.seconds > previous, row.seconds - max(0, previous) <= 0.4 else { throw VisionTrialError.invalidReport }; previous = row.seconds }
        guard let firstRow = rows.first, firstRow.seconds <= 0.2,
              let last = rows.last, last.seconds >= corpus.duration_seconds - 0.2 else { throw VisionTrialError.invalidReport }
        let config = args.count > 4 ? try PoseCounterConfiguration.decode(Data(contentsOf: URL(fileURLWithPath: args[4]))) : .standard
        let policy = args.count > 5 ? try JSONDecoder().decode(PoseRuntimePolicy.self, from: Data(contentsOf: URL(fileURLWithPath: args[5]))) : .standard
        try PoseSessionSettings(configuration: config, runtimePolicy: policy).validate()
        try evaluate(corpus, header: header, rows: rows, output: URL(fileURLWithPath: args[3]), configuration: config, policy: policy, cacheHash: checksum(cacheURL))
    }
} catch {
    FileHandle.standardError.write(Data("Video replay failed: \(error.localizedDescription)\n".utf8)); exit(1)
}
#else
print("Video extraction requires macOS Apple Vision; numeric replay remains available on other platforms.")
exit(1)
#endif
