import Foundation

public enum VisionInputSource: String, Codable { case camera, fixture }

public struct VisionMetrics: Codable, Equatable {
    public var processedFrames: Int
    public var validFrames: Int
    public var interruptions: Int
    public var processedHz: Double
    public var latencyP50Ms: Double
    public var latencyP95Ms: Double
    public var peakThermalState: String
    public init(processedFrames: Int = 0, validFrames: Int = 0, interruptions: Int = 0, processedHz: Double = 0,
                latencyP50Ms: Double = 0, latencyP95Ms: Double = 0, peakThermalState: String = "nominal") {
        self.processedFrames = processedFrames; self.validFrames = validFrames; self.interruptions = interruptions
        self.processedHz = processedHz; self.latencyP50Ms = latencyP50Ms; self.latencyP95Ms = latencyP95Ms
        self.peakThermalState = peakThermalState
    }
}

public struct VisionTrial: Codable, Equatable, Identifiable {
    public var schema = "fox.vision_trial.v1"
    public var algorithm = "curl_2d_v1"
    public var exercise: VisionExercise?
    public var resolvedExercise: VisionExercise { exercise ?? .curl }
    public var id = UUID()
    public var startedAt: Date
    public var endedAt: Date
    public var device: String
    public var appVersion: String
    public var visionRevision: Int
    public var source: VisionInputSource
    public var camera: String
    public var arm: ArmSide
    public var automaticCount: Int
    public var manualAdjustment: Int
    public var referenceCount: Int?
    public var repetitions: [CurlRepetition]
    public var metrics: VisionMetrics
    public var notes: String
    public var trialReview: TrialReview? = nil
    public var captureContext: VisionCaptureContext?
    public var counterDiagnostics: PoseCounterDiagnostics?
    public private(set) var confirmedCount: Int

    public init(startedAt: Date, endedAt: Date, device: String, appVersion: String, visionRevision: Int,
                source: VisionInputSource, camera: String, arm: ArmSide, repetitions: [CurlRepetition],
                manualAdjustment: Int, referenceCount: Int?, metrics: VisionMetrics, notes: String,
                captureContext: VisionCaptureContext? = nil, exercise: VisionExercise = .curl,
                counterDiagnostics: PoseCounterDiagnostics? = nil) {
        self.exercise = exercise; algorithm = counterDiagnostics == nil ? exercise.algorithm :
            exercise.algorithm(runtimePolicy: counterDiagnostics?.runtimePolicy)
        self.counterDiagnostics = counterDiagnostics
        self.startedAt = startedAt; self.endedAt = endedAt; self.device = device; self.appVersion = appVersion
        self.visionRevision = visionRevision; self.source = source; self.camera = camera; self.arm = arm
        self.repetitions = repetitions; automaticCount = repetitions.count; self.manualAdjustment = manualAdjustment
        confirmedCount = repetitions.count + manualAdjustment
        self.referenceCount = referenceCount; self.metrics = metrics; self.notes = notes
        self.captureContext = captureContext
    }

    public func validate() throws {
        try trialReview?.validate()
        let reliable = counterDiagnostics != nil
        try counterDiagnostics?.validate(side: arm)
        let policy = counterDiagnostics?.configuration.tracking ?? PoseCounterConfiguration.legacy.tracking
        let expectedAlgorithm = !reliable ? resolvedExercise.algorithm :
            resolvedExercise.algorithm(runtimePolicy: counterDiagnostics?.runtimePolicy)
        guard schema == "fox.vision_trial.v1", algorithm == expectedAlgorithm,
              !reliable || exercise != nil, automaticCount == repetitions.count,
              (0...10000).contains(automaticCount), (-10000...10000).contains(manualAdjustment),
              confirmedCount == automaticCount + manualAdjustment,
              (0...10000).contains(confirmedCount), referenceCount.map({ (0...10000).contains($0) }) ?? true,
              endedAt >= startedAt, ["front", "back"].contains(camera), visionRevision > 0,
              metrics.processedFrames >= 0, (0...metrics.processedFrames).contains(metrics.validFrames),
              metrics.interruptions >= 0,
              [metrics.processedHz, metrics.latencyP50Ms, metrics.latencyP95Ms].allSatisfy({ $0.isFinite && $0 >= 0 }),
              metrics.latencyP95Ms >= metrics.latencyP50Ms,
              ["nominal", "fair", "serious", "critical"].contains(metrics.peakThermalState),
              repetitions.allSatisfy({ rep in
                  if resolvedExercise == .latPulldown { return true }
                  guard let hold = rep.holdSeconds, let lower = rep.lowerSeconds,
                        rep.countingBasis == nil, rep.precedingReturn == nil else { return false }
                  return [rep.liftSeconds, hold, lower, rep.completedAtSeconds, rep.minimumConfidence].allSatisfy({ $0.isFinite && $0 >= 0 }) &&
                  rep.liftSeconds >= policy.minimumMovementSeconds - 0.000001 && lower >= policy.minimumMovementSeconds - 0.000001 &&
                  rep.liftSeconds + hold + lower <= policy.maximumCycleSeconds &&
                  (policy.trackingConfidence...1).contains(rep.minimumConfidence) &&
                  (rep.trackingGapSeconds.map { $0.isFinite && $0 >= 0 && $0 <= rep.liftSeconds + hold + lower } ?? true) &&
                  (reliable || rep.trackingGapSeconds == nil) &&
                  (rep.geometryFallbackFrames.map { (0...10000).contains($0) && algorithm == "lateral_raise_2d_v4" } ?? true) &&
                  ((counterDiagnostics?.runtimePolicy == nil && rep.startedAtSeconds == nil && rep.peakAtSeconds == nil && rep.loweredAtSeconds == nil) ||
                   (counterDiagnostics?.runtimePolicy != nil && rep.startedAtSeconds.map { $0.isFinite && $0 >= 0 } == true &&
                    rep.peakAtSeconds.map { $0.isFinite && $0 >= rep.startedAtSeconds! } == true &&
                    rep.loweredAtSeconds.map { $0.isFinite && $0 >= rep.peakAtSeconds! && $0 <= rep.completedAtSeconds } == true))
              }) else { throw VisionTrialError.invalidReport }
        try captureContext?.validate(frontCamera: camera == "front", source: source)
        if resolvedExercise == .latPulldown {
            try validatePulldownRepetitions(policy: policy)
            return
        }
        for rep in repetitions {
            guard (counterDiagnostics?.runtimePolicy?.eccentricPolicy == nil) == (rep.eccentric == nil) else {
                throw VisionTrialError.invalidReport
            }
            try rep.eccentric?.validate(start: rep.startedAtSeconds ?? 0, end: rep.loweredAtSeconds ?? rep.completedAtSeconds,
                gap: rep.trackingGapSeconds ?? 0)
        }
    }

    private func validatePulldownRepetitions(policy: PoseTrackingPolicy) throws {
        guard let diagnostics = counterDiagnostics else { throw VisionTrialError.invalidReport }
        var previous = -1.0
        for (index, rep) in repetitions.enumerated() {
            guard rep.countingBasis == .contractedEndpoint, rep.holdSeconds == nil, rep.lowerSeconds == nil,
                  rep.loweredAtSeconds == nil, rep.eccentric == nil, rep.geometryFallbackFrames == nil,
                  let start = rep.startedAtSeconds, let peak = rep.peakAtSeconds,
                  [start,peak,rep.completedAtSeconds,rep.liftSeconds,rep.minimumConfidence].allSatisfy({ $0.isFinite && $0 >= 0 }),
                  start > previous, peak <= rep.completedAtSeconds,
                  rep.completedAtSeconds - start <= policy.maximumCycleSeconds,
                  rep.liftSeconds >= policy.minimumMovementSeconds - 0.000001,
                  abs(peak - start - rep.liftSeconds) < 0.000001,
                  (diagnostics.configuration.pulldown.trackingConfidence...1).contains(rep.minimumConfidence),
                  rep.trackingGapSeconds.map({ $0.isFinite && (0...rep.liftSeconds).contains($0) }) ?? true else {
                throw VisionTrialError.invalidReport
            }
            if let observation = rep.precedingReturn {
                guard index > 0, observation.repetitionIndex == index - 1 else { throw VisionTrialError.invalidReport }
                try observation.measurement.validate(start: repetitions[index - 1].completedAtSeconds, end: start, gap: 0)
            }
            previous = rep.completedAtSeconds
        }
    }
}

public enum VisionTrialError: LocalizedError {
    case invalidReport, corruptArchive
    public var errorDescription: String? {
        switch self {
        case .invalidReport: return "验证记录不完整，或次数、测量值超出范围。"
        case .corruptArchive: return "视觉记录无法读取，原文件已保留。"
        }
    }
}

public final class VisionTrialRepository {
    private struct Archive: Codable { var schemaVersion = 1; var trials: [VisionTrial] }
    public let fileURL: URL
    public private(set) var trials: [VisionTrial]
    private let writer: (Data, URL) throws -> Void

    public init(fileURL: URL, writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.fileURL = fileURL; self.writer = writer
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let archive = try LocalTrainingRepository.decoder().decode(Archive.self, from: Data(contentsOf: fileURL))
                guard archive.schemaVersion == 1, Set(archive.trials.map(\.id)).count == archive.trials.count else { throw VisionTrialError.corruptArchive }
                try archive.trials.forEach { try $0.validate() }
                trials = archive.trials
            } catch { throw VisionTrialError.corruptArchive }
        } else { trials = [] }
    }

    public func append(_ trial: VisionTrial) throws {
        try trial.validate()
        guard !trials.contains(where: { $0.id == trial.id }) else { throw VisionTrialError.invalidReport }
        let next = trials + [trial]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer(LocalTrainingRepository.encoder().encode(Archive(trials: next)), fileURL)
        trials = next
    }
}
