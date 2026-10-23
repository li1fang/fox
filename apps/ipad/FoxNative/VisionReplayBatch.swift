#if DEBUG
import CryptoKit
import FoxPoseExperimentKit
import FoxTrainingCore
import Foundation
import UIKit

final class VisionBatchControl: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    func stop(_ reason: String) { lock.lock(); defer { lock.unlock() }; self.reason = self.reason ?? reason }
    func check() throws {
        lock.lock(); let value = reason; lock.unlock()
        if let value { throw VisionBatchCancelled(reason: value) }
    }
}
struct VisionBatchCancelled: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

struct VisionBatchJob: Codable {
    enum Kind: String, Codable { case cache, diagnostic, video }
    enum Mode: String, Codable { case controller, observations }
    struct Case: Codable {
        var id: String
        var exercise: VisionExercise
        var arm: ArmSide
        var startSeconds: Double
        var endSeconds: Double
        var rebindAtSeconds: [Double]
    }
    var schema: String
    var id: UUID
    var kind: Kind
    var mode: Mode?
    var effectiveMode: Mode { mode ?? .controller }
    var input: String
    var files: [VisionDiagnosticManifest.Asset]
    var cases: [Case]
    var settings: PoseSessionSettings?

    static func safeName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 100 && name != "." && name != ".." &&
            name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
    func validate(id expectedID: UUID, folder: URL) throws {
        guard schema == "fox.vision_batch_job.v1", id == expectedID, Self.safeName(input),
              (1...4).contains(files.count), Set(files.map(\.path)).count == files.count,
              files.contains(where: { $0.path == input }),
              (effectiveMode == .controller ? (1...16).contains(cases.count) : cases.isEmpty && kind != .diagnostic),
              Set(cases.map(\.id)).count == cases.count else { throw VisionDiagnosticArchive.error("Invalid batch manifest") }
        try settings?.validate()
        for c in cases {
            guard Self.safeName(c.id), c.startSeconds.isFinite, c.endSeconds.isFinite,
                  c.startSeconds >= 0, c.endSeconds > c.startSeconds, c.endSeconds - c.startSeconds <= 600,
                  c.rebindAtSeconds.count <= 50, c.rebindAtSeconds == c.rebindAtSeconds.sorted(),
                  Set(c.rebindAtSeconds).count == c.rebindAtSeconds.count,
                  c.rebindAtSeconds.allSatisfy({ $0.isFinite && $0 >= c.startSeconds && $0 < c.endSeconds }) else {
                throw VisionDiagnosticArchive.error("Invalid batch segment")
            }
        }
        for file in files {
            guard Self.safeName(file.path), file.bytes > 0, file.bytes <= 512 * 1024 * 1024,
                  file.sha256.count == 64, file.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw VisionDiagnosticArchive.error("Invalid batch asset")
            }
            let actual = try VisionDiagnosticArchive.asset(folder.appendingPathComponent(file.path))
            guard actual.bytes == file.bytes, actual.sha256 == file.sha256 else { throw VisionDiagnosticArchive.error("Batch asset checksum mismatch") }
        }
    }
}

struct VisionBatchTrace: Codable {
    let seconds: Double
    let subjectState: PoseSubjectState
    let selectedIndex: Int?
    let startState: String
    let counting: Bool
    let automaticCount: Int
    let phase: CurlPhase
}
struct VisionBatchCaseResult: Codable {
    let specification: VisionBatchJob.Case
    let originSeconds: Double?
    let repetitions: [CurlRepetition]
    let resetCounts: [String: Int]
    let trace: [VisionBatchTrace]
    var validatedReport: VisionTrial? = nil
}
struct VisionBatchResult: Codable {
    var schema = "fox.vision_batch_result.v1"
    let jobID: UUID
    let jobSHA256: String
    let inputAssets: [VisionDiagnosticManifest.Asset]
    let inferencePerformed: Bool
    let mode: VisionBatchJob.Mode
    let observationFrameCount: Int
    let inputProvenance: [String: String]
    let controllerVersion: String
    let appVersion: String
    let appBuild: String
    let device: String
    let platform: String
    let settings: PoseSessionSettings
    let settingsSHA256: String
    let algorithms: [String: String]
    let cases: [VisionBatchCaseResult]
    // Captured from the executing app bundle, not inferred from the developer's later checkout.
    var motionStrategies: [MotionStrategy]? = nil
    var evidenceBoundary = "offline-observations-through-real-controller-not-live-camera-or-new-human-acceptance"
}
struct VisionBatchStatus: Codable {
    var schema = "fox.vision_batch_status.v1"
    let jobID: UUID
    var jobSHA256: String?
    var phase: String
    var processedFrames = 0
    var error: String?
    var files: [VisionDiagnosticManifest.Asset] = []
}

@MainActor
enum VisionReplayBatch {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func run(id: UUID, documents: URL, control: VisionBatchControl = .init(),
                    progress: @escaping @MainActor (String, Int) -> Void = { _, _ in }) async throws -> VisionBatchResult {
        let manager = FileManager.default, root = documents.appendingPathComponent("FoxReplay")
        // CoreDevice owns uploaded directories; App-owned output must be outside that read-only inbox.
        let input = root.appendingPathComponent("Jobs/\(id.uuidString)")
        let output = documents.appendingPathComponent("FoxReplayRuns/\(id.uuidString)")
        guard !manager.fileExists(atPath: output.path) else { throw VisionDiagnosticArchive.error("Batch ID already exists; original run preserved") }
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: output, withIntermediateDirectories: false)
        var status = VisionBatchStatus(jobID: id, phase: "validating")
        func saveStatus() throws {
            try VisionDiagnosticArchive.encode(status).write(to: output.appendingPathComponent("status.json"), options: .atomic)
            progress(status.phase, status.processedFrames)
        }
        do {
            try saveStatus(); try control.check(); try Task.checkCancellation()
            let jobURL = input.appendingPathComponent("job.json")
            guard try VisionDiagnosticArchive.asset(jobURL).bytes <= 128 * 1024 else { throw VisionDiagnosticArchive.error("Batch manifest too large") }
            let bytes = try Data(contentsOf: jobURL), job = try JSONDecoder().decode(VisionBatchJob.self, from: bytes)
            status.jobSHA256 = digest(bytes)
            try job.validate(id: id, folder: input)
            let settings = job.settings ?? PoseSessionSettings(configuration: .standard, runtimePolicy: .standard)
            let cache: URL
            if job.kind == .video {
                status.phase = "extracting"; try saveStatus()
                let manifest = input.appendingPathComponent(job.input)
                let source = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any]
                guard let name = source?["asset"] as? String, let sha = source?["sha256"] as? String,
                      job.files.contains(where: { $0.path == name && $0.sha256 == sha }) else {
                    throw VisionDiagnosticArchive.error("Video must be a declared, verified asset")
                }
                let partial = output.appendingPathComponent("vision.partial.jsonl")
                try await Task.detached {
                    try control.check()
                    try exportVisionCache(manifest, output: partial) { index in
                        try control.check()
                        Task { @MainActor in progress("extracting", index) }
                    }
                }.value
                try control.check(); try Task.checkCancellation()
                cache = output.appendingPathComponent("vision.jsonl")
                try manager.moveItem(at: partial, to: cache)
            } else { cache = input.appendingPathComponent(job.input) }
            guard try VisionDiagnosticArchive.asset(cache).bytes <= 64 * 1024 * 1024 else { throw VisionDiagnosticArchive.error("Pose cache exceeds 64 MiB") }
            let lines = try String(contentsOf: cache, encoding: .utf8).split(whereSeparator: \.isNewline)
            guard !lines.isEmpty, lines.count <= 20001 else { throw VisionDiagnosticArchive.error("Invalid cache length") }
            let frames: [PoseFrame], provenance: [String: String]
            if job.kind == .diagnostic {
                provenance = ["source":"imported-diagnostic-observations", "timebase":"capture-PTS"]
                frames = try lines.map {
                    let row = try JSONDecoder().decode(VisionDiagnosticPose.self, from: Data($0.utf8))
                    return try PoseVideoRow(seconds: row.capturePTS, width: row.width, height: row.height, people: row.people).frame()
                }
            } else {
                let header = try JSONDecoder().decode([String: String].self, from: Data(lines[0].utf8))
                guard header["schema"] == "fox.pose_comparison_cache.v1", header["visionRevision"] == "1",
                      header["sampledHz"] == "10", header["videoSHA256"]?.count == 64,
                      header["source"] != nil else { throw VisionDiagnosticArchive.error("Unsupported pose cache provenance") }
                provenance = header
                frames = try lines.dropFirst().map { try JSONDecoder().decode(PoseVideoRow.self, from: Data($0.utf8)).frame() }
            }
            guard frames.count >= 2, zip(frames, frames.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }),
                  frames.last!.timestamp - frames.first!.timestamp <= 600.1 else { throw VisionDiagnosticArchive.error("Empty, non-monotonic or oversized cache timeline") }
            status.phase = job.effectiveMode == .controller ? "replaying" : "observing"
            if job.effectiveMode == .observations { status.processedFrames = frames.count }
            try saveStatus()
            var results: [VisionBatchCaseResult] = []
            let work = output.appendingPathComponent("work")
            defer { try? manager.removeItem(at: work) }
            for item in job.cases {
                let selected = frames.filter { $0.timestamp >= item.startSeconds && $0.timestamp < item.endSeconds }
                guard selected.count >= 2 else { throw VisionDiagnosticArchive.error("Empty batch segment: \(item.id)") }
                let directory = work.appendingPathComponent(item.id)
                let controller = VisionLabController(diagnosticRoot: directory.appendingPathComponent("diagnostics"), storageDirectory: directory)
                let clock = VisionReplayClock(origin: Date(timeIntervalSince1970: 0))
                controller.enableReplay(clock: clock)
                try controller.applyConfiguration(settings.configuration, runtimePolicy: settings.runtimePolicy)
                controller.changeExercise(item.exercise); controller.changeArm(item.arm)
                controller.startCamera(); controller.startCounting()
                defer { controller.stopCamera() }
                var trace: [VisionBatchTrace] = [], origin: Double?, rebinds = item.rebindAtSeconds[...]
                for (index, frame) in selected.enumerated() {
                    if index % 20 == 0 {
                        try control.check(); try Task.checkCancellation()
                        try saveStatus(); await Task.yield()
                    }
                    while let time = rebinds.first, frame.timestamp > time { controller.rebindSubject(); rebinds = rebinds.dropFirst() }
                    clock.uptime = 1000 + frame.timestamp
                    controller.replayFrame(CapturedPose(frame: frame, latencyMs: 0, revision: 1))
                    if controller.isCounting && origin == nil { origin = frame.timestamp }
                    let state: String
                    switch controller.startState {
                    case .idle: state = "idle"
                    case .waiting: state = "waiting"
                    case .countdown(let n): state = "countdown-\(n)"
                    case .ready: state = "ready"
                    }
                    trace.append(.init(seconds: frame.timestamp, subjectState: controller.subjectSelection.state,
                        selectedIndex: controller.subjectSelection.index, startState: state, counting: controller.isCounting,
                        automaticCount: controller.automaticCount, phase: controller.snapshot.phase))
                    status.processedFrames += 1
                }
                guard rebinds.isEmpty else { throw VisionDiagnosticArchive.error("Rebind command lies outside observed frames") }
                var report: VisionTrial?
                if item.exercise == .latPulldown {
                    controller.finishCounting()
                    guard controller.saveReport(referenceCount: nil, notes: "Private replay; not live-camera acceptance", bodyView: .back) else {
                        throw VisionDiagnosticArchive.error(controller.errorMessage ?? "Pulldown report not saved")
                    }
                    report = controller.lastTrial
                }
                results.append(.init(specification: item, originSeconds: origin, repetitions: controller.repetitions,
                    resetCounts: controller.diagnostics.resetCounts, trace: trace, validatedReport: report))
            }
            try control.check(); try Task.checkCancellation()
            var result = VisionBatchResult(jobID: id, jobSHA256: status.jobSHA256!, inputAssets: job.files,
                inferencePerformed: job.kind == .video, mode: job.effectiveMode, observationFrameCount: frames.count, inputProvenance: provenance,
                controllerVersion: job.effectiveMode == .controller ? VisionLabController.preparationFlowVersion : "not-run",
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                device: VisionDiagnosticArchive.hardwareModel(), platform: ProcessInfo.processInfo.operatingSystemVersionString,
                settings: settings, settingsSHA256: digest(try VisionDiagnosticArchive.encode(settings)),
                algorithms: job.effectiveMode == .controller ? Dictionary(uniqueKeysWithValues: VisionExercise.allCases.map { ($0.rawValue, $0.algorithm(runtimePolicy: settings.runtimePolicy)) }) : [:], cases: results)
            result.motionStrategies = try VisionExercise.allCases.map { try MotionStrategy.load($0) }
                .filter { result.algorithms[$0.exercise.rawValue] == $0.algorithm }
            if job.effectiveMode == .observations { result.evidenceBoundary = "raw-video-observations-only-no-controller-no-counts-no-exercise-adaptation" }
            let resultURL = output.appendingPathComponent("result.json")
            try VisionDiagnosticArchive.encode(result).write(to: resultURL, options: .atomic)
            let settingsURL = output.appendingPathComponent("settings.json")
            try VisionDiagnosticArchive.encode(settings).write(to: settingsURL, options: .atomic)
            status.files = [try VisionDiagnosticArchive.asset(resultURL), try VisionDiagnosticArchive.asset(settingsURL)]
            if job.kind == .video { status.files.append(try VisionDiagnosticArchive.asset(cache)) }
            try control.check(); try Task.checkCancellation()
            status.phase = "completed"; try saveStatus()
            return result
        } catch {
            status.phase = error is VisionBatchCancelled || error is CancellationError ? "cancelled" : "failed"
            status.error = error.localizedDescription; status.files = []
            try? saveStatus()
            throw error
        }
    }
}
#endif
