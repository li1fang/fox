import Foundation
import FoxTrainingCore
#if os(macOS) || os(iOS)
import AVFoundation
import Vision
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CreateMLComponents

struct ExperimentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct Manifest: Decodable {
    struct Segment: Decodable {
        let id: String; let start: Double; let end: Double; let exercise: VisionExercise?
    }
    struct Checkpoint: Decodable { let seconds: Double; let minX: Double; let maxX: Double; let minY: Double; let maxY: Double }
    let asset: String; let sha256: String; let duration_seconds: Double; let segments: [Segment]
    let subject_checkpoints: [Checkpoint]
}
struct StreamFrame: Codable {
    var seconds: Double; var width: Double; var height: Double
    var people: [[PoseTraceJoint]]
    var imagePNG: String?; var imageSHA256: String
    var visionMs: Double
    var mediapipe: [[PoseTraceJoint]]?
    var mediapipeMs: Double?
    var row: PoseVideoRow { PoseVideoRow(seconds: seconds, width: width, height: height, people: people) }
}
let visionJoints: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
    (.nose,.nose),(.neck,.neck),(.root,.root),(.leftShoulder,.leftShoulder),(.rightShoulder,.rightShoulder),
    (.leftElbow,.leftElbow),(.rightElbow,.rightElbow),(.leftWrist,.leftWrist),(.rightWrist,.rightWrist),
    (.leftHip,.leftHip),(.rightHip,.rightHip),(.leftKnee,.leftKnee),(.rightKnee,.rightKnee),
    (.leftAnkle,.leftAnkle),(.rightAnkle,.rightAnkle)
]
let appleKeys: [PoseJoint: JointKey] = [
    .nose:.nose,.neck:.neck,.root:.root,.leftShoulder:.leftShoulder,.rightShoulder:.rightShoulder,
    .leftElbow:.leftElbow,.rightElbow:.rightElbow,.leftWrist:.leftWrist,.rightWrist:.rightWrist,
    .leftHip:.leftHip,.rightHip:.rightHip,.leftKnee:.leftKnee,.rightKnee:.rightKnee,
    .leftAnkle:.leftAnkle,.rightAnkle:.rightAnkle
]
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func fileDigest(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}
func emit<T: Encodable>(_ value: T) throws {
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(value))
    try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
}
func save<T: Encodable>(_ value: T, _ url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { throw ExperimentError(message: "Output already exists") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}
public func streamFrames(_ manifestURL: URL) throws {
    try extractFrames(manifestURL, includeImage: true, header: { try emit($0) }, frame: { try emit($0) }, progress: { index in
        if index % 200 == 0 { FileHandle.standardError.write(Data("Canonical frames \(index)\n".utf8)) }
    })
}

public func exportVisionCache(_ manifestURL: URL, output: URL, progress: (Int) throws -> Void) throws {
    guard !FileManager.default.fileExists(atPath: output.path),
          FileManager.default.createFile(atPath: output.path, contents: nil) else {
        throw ExperimentError(message: "Cannot create new cache")
    }
    let file = try FileHandle(forWritingTo: output); defer { try? file.close() }
    func write<T: Encodable>(_ value: T) throws {
        try file.write(contentsOf: JSONEncoder().encode(value))
        try file.write(contentsOf: Data("\n".utf8))
    }
    try extractFrames(manifestURL, includeImage: false, header: { value in
        var cacheHeader = value; cacheHeader["schema"] = "fox.pose_comparison_cache.v1"
        cacheHeader["source"] = "device-video-not-camera"
        try write(cacheHeader)
    }, frame: { try write($0) }, progress: progress)
    try file.synchronize()
}

func extractFrames(_ manifestURL: URL, includeImage: Bool, header: ([String:String]) throws -> Void,
                   frame: (StreamFrame) throws -> Void, progress: (Int) throws -> Void) throws {
    let corpus = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    guard corpus.asset == URL(fileURLWithPath: corpus.asset).lastPathComponent,
          corpus.duration_seconds.isFinite, (0...600).contains(corpus.duration_seconds) else { throw VisionTrialError.invalidReport }
    let video = manifestURL.deletingLastPathComponent().appendingPathComponent(corpus.asset)
    guard try fileDigest(video) == corpus.sha256 else { throw VisionTrialError.invalidReport }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1280, height: 1280)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let request = VNDetectHumanBodyPoseRequest(); request.revision = 1
    try header(["schema":"fox.pose_comparison_stream.v1", "videoSHA256":corpus.sha256,
              "platform":ProcessInfo.processInfo.operatingSystemVersionString, "sampledHz":"10", "visionRevision":"1",
              "preprocessingVersion":"avasset-exact-transform-max1280-png-v1", "timebase":"asset-seconds"])
    var previous = -1.0
    for index in 0..<Int(ceil(corpus.duration_seconds * 10)) {
        try autoreleasepool {
            var actual = CMTime.zero
            let original = try generator.copyCGImage(at: CMTime(seconds: Double(index) / 10, preferredTimescale: 60000), actualTime: &actual)
            guard actual.seconds > previous else { return }
            previous = actual.seconds
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
                throw ExperimentError(message: "Cannot encode canonical PNG")
            }
            CGImageDestinationAddImage(destination, original, nil)
            guard CGImageDestinationFinalize(destination),
                  let source = CGImageSourceCreateWithData(buffer, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ExperimentError(message: "Cannot decode canonical PNG")
            }
            let began = ProcessInfo.processInfo.systemUptime
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            let elapsed = (ProcessInfo.processInfo.systemUptime - began) * 1000
            let people = try (request.results ?? []).map { observation in
                let points = try observation.recognizedPoints(.all)
                return visionJoints.compactMap { joint, name -> PoseTraceJoint? in
                    guard let point = points[name] else { return nil }
                    return PoseTraceJoint(joint: joint, x: point.location.x, y: point.location.y, confidence: Double(point.confidence))
                }
            }.filter { $0.contains { $0.confidence > 0 } }
            let data = buffer as Data
            try frame(StreamFrame(seconds: actual.seconds, width: Double(image.width), height: Double(image.height),
                people: people, imagePNG: includeImage ? data.base64EncodedString() : nil, imageSHA256: digest(data), visionMs: elapsed))
        }
        if index % 100 == 0 { try progress(index) }
    }
}
struct ModeResult: Codable {
    let count: Int; let originSeconds: Double; let repetitions: [CurlRepetition]
    let resetCounts: [String:Int]
}
struct SegmentResult: Codable {
    let id: String; let side: ArmSide; let exercise: VisionExercise
    let frames: Int; let subjectStates: [String:Int]; let geometryStates: [String:Int]
    let originalPeople: [String:Int]; let selectedNoneWithDetectedPerson: Int
    let firstReadyAt: Double?; let countdownReadyAt: Double?; let countdownResets: Int
    let firstLostAt: Double?; let diagnostic: ModeResult; let gated: ModeResult
    let negativeWindowDiagnosticCount: Int; let negativeWindowGatedCount: Int
    let subjectCheckpoints: [SubjectCheck]
}
struct SubjectCheck: Codable { let seconds: Double; let selectedAt: Double; let state: PoseSubjectState; let status: String }
struct CounterPoint: Codable { let windowStart: Double; let windowEnd: Double; let cumulativeCount: Float }
struct CounterRun: Codable {
    let id: String; let side: ArmSide; let hz: Int; let joints: String
    let startedAt: Double; let frames: Int; let points: [CounterPoint]
    let processingSeconds: Double; let error: String?
}
struct Report: Codable {
    var schema = "fox.pose_comparison_evaluation.v1"
    let backend: String; let inputSHA256: String; let videoSHA256: String; let platform: String
    let inferencePlatform: String?
    let configuration: PoseCounterConfiguration; let runtimePolicy: PoseRuntimePolicy
    let segments: [SegmentResult]; let appleCounterRuns: [CounterRun]
}
public func evaluate(_ manifestURL: URL, _ cache: URL, _ backend: String, _ output: URL, includeAppleCounter: Bool = true) async throws {
    guard ["vision", "mediapipe"].contains(backend) else { throw VisionTrialError.invalidReport }
    let corpus = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
    let lines = try String(contentsOf: cache, encoding: .utf8).split(separator: "\n")
    guard let first = lines.first,
          let header = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String:Any],
          header["schema"] as? String == "fox.pose_comparison_cache.v1",
          header["videoSHA256"] as? String == corpus.sha256 else { throw VisionTrialError.invalidReport }
    let data = try lines.dropFirst().map { try JSONDecoder().decode(StreamFrame.self, from: Data($0.utf8)) }
    guard let firstFrame = data.first, let last = data.last, firstFrame.seconds <= 0.2,
          last.seconds >= corpus.duration_seconds - 0.2 else { throw VisionTrialError.invalidReport }
    var prior = -1.0
    for item in data {
        guard item.seconds > prior, item.seconds - max(0, prior) <= 0.4, item.imagePNG == nil,
              item.imageSHA256.count == 64, backend != "mediapipe" || item.mediapipe != nil else { throw VisionTrialError.invalidReport }
        _ = try item.row.frame(); prior = item.seconds
    }
    var results: [SegmentResult] = [], counterRuns: [CounterRun] = []
    let config = PoseCounterConfiguration.standard, policy = PoseRuntimePolicy.standard
    for segment in corpus.segments where segment.exercise != nil {
        let end = segment.id == "A02" ? 120 : (segment.id == "front-exploration" ? corpus.duration_seconds : segment.end)
        let rows = data.filter { $0.seconds >= segment.start && $0.seconds < end }
        for side in ArmSide.allCases {
            var selector = PoseSubjectSelector(policy: policy)
            var tracker = CurlTracker(side: side, exercise: segment.exercise!, configuration: config, runtimePolicy: policy)
            var gated = tracker
            var gate = PoseStartGate(lossTolerance: policy.countdownLossTolerance); gate.arm()
            var states: [String:Int] = [:], geometries: [String:Int] = [:], people: [String:Int] = [:]
            var firstReady: Double?, readyAt: Double?, lostAt: Double?, resets = 0, none = 0
            var selected: [(Double, BodyPose?)] = []
            var selections: [(Double, PoseSubjectSelection)] = []
            for row in rows {
                let frame = try PoseVideoRow(seconds: row.seconds, width: row.width, height: row.height,
                    people: backend == "vision" ? row.people : row.mediapipe!).frame()
                let previous = selector.selection.state
                let choice = selector.process(frame), chosen = choice.selectedFrame(from: frame)
                if choice.state == .lost && previous != .lost { tracker.interrupt(); gated.interrupt() }
                if choice.state == .lost && lostAt == nil { lostAt = row.seconds }
                states[choice.state.rawValue, default:0] += 1; people[String(frame.people.count),default:0] += 1
                if chosen.people.isEmpty && !frame.people.isEmpty { none += 1 }
                let reading = PoseGeometry.inspect(chosen, side: side, exercise: segment.exercise!, configuration: config, runtimePolicy: policy)
                geometries[reading.failureReason?.rawValue ?? reading.quality.rawValue,default:0] += 1
                let ready = PoseSubjectSelector.isReady(chosen, side: side, confidence: policy.subjectConfidence)
                if ready && firstReady == nil { firstReady = row.seconds }
                let wasCountdown: Bool
                if case .countdown = gate.state { wasCountdown = true } else { wasCountdown = false }
                let state = gate.process(timestamp: row.seconds, poseReady: ready)
                if wasCountdown && state == .waiting { resets += 1 }
                if state == .ready && readyAt == nil { readyAt = row.seconds }
                tracker.process(chosen, originalPeopleCount: frame.people.count, selection: choice)
                if readyAt != nil { gated.process(chosen, originalPeopleCount: frame.people.count, selection: choice) }
                selected.append((row.seconds, chosen.people.first))
                selections.append((row.seconds, choice))
            }
            let origin = rows.first?.seconds ?? segment.start
            let gatedOrigin = readyAt ?? origin
            let checks = corpus.subject_checkpoints.filter { $0.seconds >= segment.start && $0.seconds < end }.compactMap { point -> SubjectCheck? in
                guard let nearest = selections.min(by: { abs($0.0 - point.seconds) < abs($1.0 - point.seconds) }) else { return nil }
                let status: String
                if let anchor = nearest.1.anchor {
                    status = (point.minX...point.maxX).contains(anchor.x) && (point.minY...point.maxY).contains(anchor.y)
                        ? "within-reviewed-subject-region" : "outside-reviewed-subject-region"
                } else { status = "not-selected" }
                return SubjectCheck(seconds:point.seconds,selectedAt:nearest.0,state:nearest.1.state,status:status)
            }
            results.append(SegmentResult(id: segment.id, side: side, exercise: segment.exercise!, frames: rows.count,
                subjectStates: states, geometryStates: geometries, originalPeople: people, selectedNoneWithDetectedPerson: none,
                firstReadyAt: firstReady, countdownReadyAt: readyAt, countdownResets: resets, firstLostAt: lostAt,
                diagnostic: ModeResult(count: tracker.repetitions.count, originSeconds: origin, repetitions: tracker.repetitions, resetCounts: tracker.diagnostics.resetCounts),
                gated: ModeResult(count: gated.repetitions.count, originSeconds: gatedOrigin, repetitions: gated.repetitions, resetCounts: gated.diagnostics.resetCounts),
                negativeWindowDiagnosticCount: end > segment.end ? tracker.repetitions.filter { $0.completedAtSeconds + origin >= segment.end }.count : 0,
                negativeWindowGatedCount: end > segment.end ? gated.repetitions.filter { $0.completedAtSeconds + gatedOrigin >= segment.end }.count : 0,
                subjectCheckpoints: checks))
            let isTarget = (segment.id == "A01" && side == .left) || (segment.id == "A02" && side == .right) || segment.id == "A03"
            if includeAppleCounter && backend == "vision" && isTarget {
                for hz in [10,5] { for profile in ["body_without_face", "observed_arm"] {
                    let chunks = selected.split { $0.1 == nil }
                    for chunk in chunks {
                        let samples = chunk.enumerated().filter { $0.offset % (10 / hz) == 0 }.map(\.element)
                        guard samples.count >= 90 else { continue }
                        let began = ProcessInfo.processInfo.systemUptime
                        do {
                            let (points, partialError) = try await countApple(samples, side: side, profile: profile, hz: hz)
                            counterRuns.append(CounterRun(id: segment.id, side: side, hz: hz, joints: profile,
                                startedAt: samples[0].0, frames: samples.count, points: points,
                                processingSeconds: ProcessInfo.processInfo.systemUptime - began, error: partialError))
                        } catch {
                            counterRuns.append(CounterRun(id: segment.id, side: side, hz: hz, joints: profile,
                                startedAt: samples[0].0, frames: samples.count, points: [],
                                processingSeconds: ProcessInfo.processInfo.systemUptime - began, error: error.localizedDescription))
                        }
                    }
                } }
            }
        }
    }
    try save(Report(backend: backend, inputSHA256: fileDigest(cache), videoSHA256: corpus.sha256,
        platform: ProcessInfo.processInfo.operatingSystemVersionString, inferencePlatform: header["platform"] as? String, configuration: config,
        runtimePolicy: policy, segments: results, appleCounterRuns: counterRuns), output)
}
@MainActor
func countApple(_ samples: [(Double, BodyPose?)], side: ArmSide, profile: String, hz: Int) async throws -> ([CounterPoint], String?) {
    let features: [TemporalFeature<Pose>] = samples.enumerated().map { index, sample in
        let (_, body) = sample
        let points = body!.points.filter { joint, _ in profile == "observed_arm" ? side.joints.contains(joint) : joint != .nose }
        let apple = Dictionary(uniqueKeysWithValues: points.compactMap { joint, point -> (JointKey,JointPoint)? in
            guard let key = appleKeys[joint] else { return nil }
            return (key,JointPoint(key,location:CGPoint(x:point.x,y:point.y),confidence:Float(point.confidence)))
        })
        // Sliding windows index samples, not 60 kHz presentation-time ticks.
        return TemporalFeature(id:TemporalSegmentIdentifier(source:"fox-private-video",range:index..<(index+1),timescale:hz),feature:Pose(from:apple))
    }
    let stream = AsyncStream<TemporalFeature<Pose>> { continuation in
        features.forEach { continuation.yield($0) }; continuation.finish()
    }
    let input = AnyTemporalSequence(stream, count:features.count)
    let windows = try SlidingWindowTransformer<Pose>(stride:5,length:90).applied(to:input,eventHandler:nil)
    let counted = try await HumanBodyActionCounter().applied(to:windows)
    var points: [CounterPoint] = []
    do {
        for try await item in counted {
            guard item.feature.isFinite else { throw ExperimentError(message:"Non-finite native counter result") }
            points.append(CounterPoint(windowStart:samples[0].0 + item.id.rangeInSeconds.lowerBound,
                windowEnd:samples[0].0 + item.id.rangeInSeconds.upperBound,cumulativeCount:item.feature))
        }
    } catch {
        return (points, error.localizedDescription)
    }
    return (points, nil)
}
#endif
