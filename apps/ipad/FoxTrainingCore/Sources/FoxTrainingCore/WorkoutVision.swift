import Foundation

public enum RepetitionBasis: String, Codable { case total, perSide = "per_side" }

public struct SideRepetitions: Codable, Equatable {
    public var left: Int?
    public var right: Int?
    public init(left: Int? = nil, right: Int? = nil) { self.left = left; self.right = right }
    public func count(for side: ArmSide) -> Int? { side == .left ? left : right }
    public var commonCount: Int? { left != nil && left == right ? left : nil }
    public func validate() throws {
        guard left != nil || right != nil,
              [left, right].compactMap({ $0 }).allSatisfy({ (0...1000).contains($0) }) else { throw TrainingError.invalidRecord }
    }
}

public struct WorkoutObservationSettings: Codable, Equatable {
    public var exercise: VisionExercise
    public var arm: ArmSide
    public var bodyView: VisionBodyView
    public init(exercise: VisionExercise, arm: ArmSide, bodyView: VisionBodyView) {
        self.exercise = exercise; self.arm = arm; self.bodyView = bodyView
    }
    public func validate() throws {
        guard bodyView == exercise.recommendedBodyView else { throw TrainingError.invalidPlan }
    }
}

public struct WorkoutSetBinding: Codable, Equatable {
    public var sessionId: UUID
    public var exerciseId: String
    public var setIndex: Int
    public var attemptId: UUID
}

public enum PoseAttemptOutcome: String, Codable {
    case accepted, observedBelowMinimum = "observed_below_minimum", unobservable
}

public struct PoseAttemptEvent: Codable, Equatable {
    public let startedAtSeconds: Double
    public let endedAtSeconds: Double
    public let outcome: PoseAttemptOutcome
    public let reason: PoseFailureReason?
    public init(startedAtSeconds: Double, endedAtSeconds: Double, outcome: PoseAttemptOutcome, reason: PoseFailureReason? = nil) {
        self.startedAtSeconds = startedAtSeconds; self.endedAtSeconds = endedAtSeconds
        self.outcome = outcome; self.reason = reason
    }
    public func validate() throws {
        guard startedAtSeconds.isFinite, endedAtSeconds.isFinite, startedAtSeconds >= 0,
              endedAtSeconds >= startedAtSeconds,
              (outcome == .accepted && reason == nil) || (outcome != .accepted && reason != nil),
              outcome != .observedBelowMinimum || reason == .incompleteRange || reason == .movementTooShort else {
            throw TrainingError.invalidRecord
        }
    }
}

public enum WorkoutObservationInterruption: String, Codable {
    case pause, restart, cameraInterrupted = "camera_interrupted", userFinished = "user_finished"
}
public enum WorkoutManualReason: String, Codable {
    case userChoice = "user_choice", cameraDenied = "camera_denied", cameraUnavailable = "camera_unavailable"
    case trackingLost = "tracking_lost", cameraInterrupted = "camera_interrupted"
}

public struct WorkoutObservationSegment: Codable, Equatable, Identifiable {
    public let id: UUID
    public let preparedAt: Date
    public private(set) var startedAt: Date?
    public private(set) var updatedAt: Date?
    public private(set) var endedAt: Date?
    public private(set) var interruption: WorkoutObservationInterruption?
    public private(set) var repetitions: [CurlRepetition] = []
    public private(set) var attempts: [PoseAttemptEvent] = []
    public private(set) var droppedAttempts = 0
    public private(set) var metrics = VisionMetrics()
    public private(set) var resetCounts: [String: Int]?
    public private(set) var captureContext: VisionCaptureContext?

    init(id: UUID, at now: Date) { self.id = id; preparedAt = now }
    mutating func begin(at now: Date) throws {
        guard startedAt == nil, endedAt == nil, now >= preparedAt else { throw TrainingError.invalidTransition }
        startedAt = now
    }
    mutating func update(repetitions: [CurlRepetition], attempts: [PoseAttemptEvent], droppedAttempts: Int,
                         metrics: VisionMetrics, resetCounts: [String: Int], captureContext: VisionCaptureContext?, at now: Date) throws {
        guard let startedAt, endedAt == nil, now >= startedAt, now >= (updatedAt ?? startedAt),
              repetitions.starts(with: self.repetitions), attempts.starts(with: self.attempts),
              droppedAttempts >= self.droppedAttempts,
              metrics.processedFrames >= self.metrics.processedFrames,
              metrics.validFrames >= self.metrics.validFrames,
              metrics.interruptions >= self.metrics.interruptions,
              (self.resetCounts ?? [:]).allSatisfy({ resetCounts[$0.key, default: 0] >= $0.value }),
              self.captureContext.map({ old in
                  captureContext.map { $0.samples.starts(with: old.samples) && $0.droppedSamples >= old.droppedSamples &&
                      $0.declaredBodyView == old.declaredBodyView && $0.cameraGeometry == old.cameraGeometry } ?? false
              }) ?? true else { throw TrainingError.invalidRecord }
        self.repetitions = repetitions; self.attempts = attempts; self.droppedAttempts = droppedAttempts
        self.metrics = metrics; self.resetCounts = resetCounts; updatedAt = now
        self.captureContext = captureContext
    }
    mutating func end(reason: WorkoutObservationInterruption, at now: Date) {
        guard endedAt == nil else { return }
        endedAt = max(now, updatedAt ?? startedAt ?? preparedAt); interruption = reason
    }
}

public struct WorkoutVisualEvidence: Codable, Equatable {
    public private(set) var schema = "fox.workout_visual_evidence.v1"
    public let binding: WorkoutSetBinding
    public let settings: WorkoutObservationSettings
    public let configuration: PoseCounterConfiguration
    public let runtimePolicy: PoseRuntimePolicy
    public let source: VisionInputSource
    public let algorithm: String
    public private(set) var segments: [WorkoutObservationSegment] = []
    public private(set) var fallbackReason: WorkoutManualReason?
    public var automaticCount: Int { segments.reduce(0) { $0 + $1.repetitions.count } }
    public var repetitions: [CurlRepetition] { segments.flatMap(\.repetitions) }
    public var hasObservedFrames: Bool { segments.contains { $0.metrics.processedFrames > 0 } }
    public var hasIncompleteCoverage: Bool {
        fallbackReason != nil || segments.contains {
            $0.interruption == .pause || $0.interruption == .restart || $0.interruption == .cameraInterrupted ||
            $0.metrics.interruptions > ($0.resetCounts?[PoseFailureReason.explicitInterrupt.rawValue] ?? 0) ||
            $0.droppedAttempts > 0 || $0.repetitions.contains { ($0.trackingGapSeconds ?? 0) > 0 } ||
            $0.attempts.contains { $0.outcome == .unobservable }
        }
    }

    init(binding: WorkoutSetBinding, settings: WorkoutObservationSettings, configuration: PoseCounterConfiguration,
         runtimePolicy: PoseRuntimePolicy, source: VisionInputSource) throws {
        try settings.validate()
        try PoseSessionSettings(configuration: configuration, runtimePolicy: runtimePolicy).validate()
        self.binding = binding; self.settings = settings; self.configuration = configuration
        self.runtimePolicy = runtimePolicy; self.source = source; algorithm = settings.exercise.algorithm(runtimePolicy: runtimePolicy)
    }
    mutating func prepare(at now: Date) throws -> UUID {
        guard segments.count < 200, segments.last?.endedAt != nil || segments.isEmpty,
              now >= (segments.last?.endedAt ?? now) else { throw TrainingError.invalidTransition }
        let id = UUID(); segments.append(WorkoutObservationSegment(id: id, at: now)); return id
    }
    mutating func begin(id: UUID, at now: Date) throws {
        guard segments.last?.id == id else { throw TrainingError.invalidTransition }
        try segments[segments.count - 1].begin(at: now)
    }
    mutating func update(id: UUID, repetitions: [CurlRepetition], attempts: [PoseAttemptEvent], droppedAttempts: Int,
                         metrics: VisionMetrics, resetCounts: [String: Int], captureContext: VisionCaptureContext?, at now: Date) throws {
        guard segments.last?.id == id else { throw TrainingError.invalidTransition }
        var next = self
        try next.segments[next.segments.count - 1].update(repetitions: repetitions, attempts: attempts,
            droppedAttempts: droppedAttempts, metrics: metrics, resetCounts: resetCounts, captureContext: captureContext, at: now)
        try next.validate(); self = next
    }
    mutating func end(reason: WorkoutObservationInterruption, at now: Date) {
        if !segments.isEmpty { segments[segments.count - 1].end(reason: reason, at: now) }
    }
    mutating func useManual(reason: WorkoutManualReason, at now: Date) {
        fallbackReason = reason; end(reason: .cameraInterrupted, at: now)
    }

    public func validate() throws {
        try settings.validate()
        try PoseSessionSettings(configuration: configuration, runtimePolicy: runtimePolicy).validate()
        guard schema == "fox.workout_visual_evidence.v1", algorithm == settings.exercise.algorithm(runtimePolicy: runtimePolicy), !binding.exerciseId.isEmpty, binding.setIndex > 0,
              segments.count <= 200, Set(segments.map(\.id)).count == segments.count,
              automaticCount <= 1000 else { throw TrainingError.invalidRecord }
        var previousEnd: Date?
        for (index, segment) in segments.enumerated() {
            guard segment.preparedAt.timeIntervalSince1970.isFinite,
                  previousEnd.map({ segment.preparedAt >= $0 }) ?? true,
                  segment.startedAt.map({ $0 >= segment.preparedAt }) ?? true,
                  segment.updatedAt.map({ segment.startedAt != nil && $0 >= segment.startedAt! }) ?? true,
                  segment.endedAt.map({ $0 >= (segment.updatedAt ?? segment.startedAt ?? segment.preparedAt) }) ?? true,
                  (segment.interruption == nil) == (segment.endedAt == nil),
                  index == segments.count - 1 || segment.endedAt != nil,
                  segment.startedAt != nil || (segment.repetitions.isEmpty && segment.attempts.isEmpty && segment.metrics.processedFrames == 0),
                  segment.attempts.count <= 10000, segment.droppedAttempts >= 0 else { throw TrainingError.invalidRecord }
            if let resets = segment.resetCounts {
                guard resets.allSatisfy({ PoseFailureReason(rawValue: $0.key) != nil && $0.value >= 0 }),
                      resets.values.reduce(0.0, { $0 + Double($1) }) <= Double(segment.metrics.interruptions) else {
                    throw TrainingError.invalidRecord
                }
            }
            let diagnostics = PoseCounterDiagnostics(configuration: configuration, runtimePolicy: runtimePolicy)
            // Reuse the established report contract without storing joint traces in a workout record.
            let trial = VisionTrial(startedAt: segment.preparedAt, endedAt: segment.endedAt ?? segment.updatedAt ?? segment.startedAt ?? segment.preparedAt,
                device: "workout-summary", appVersion: "workout-evidence-v1", visionRevision: 1, source: source,
                camera: "front", arm: settings.arm, repetitions: segment.repetitions, manualAdjustment: 0,
                referenceCount: nil, metrics: segment.metrics, notes: "", exercise: settings.exercise, counterDiagnostics: diagnostics)
            try trial.validate()
            let duration = segment.startedAt.map { (segment.updatedAt ?? $0).timeIntervalSince($0) } ?? 0
            if let context = segment.captureContext {
                try context.validate(frontCamera: true, source: source)
                guard context.declaredBodyView == settings.bodyView,
                      context.samples.allSatisfy({ $0.elapsedSeconds <= duration + 0.25 && $0.automaticCount <= segment.repetitions.count }) else {
                    throw TrainingError.invalidRecord
                }
            }
            var previousCompletion = -1.0
            for rep in segment.repetitions {
                if settings.exercise == .latPulldown {
                    guard rep.completedAtSeconds <= duration + 0.25 else { throw TrainingError.invalidRecord }
                    continue // Peak facts and their separately linked returns were validated by VisionTrial.
                }
                guard let began = rep.startedAtSeconds, let peak = rep.peakAtSeconds, let bottom = rep.loweredAtSeconds,
                      let hold = rep.holdSeconds, let lower = rep.lowerSeconds,
                      began >= previousCompletion, rep.completedAtSeconds >= bottom,
                      rep.completedAtSeconds <= duration + 0.25,
                      abs((peak - began) - rep.liftSeconds) < 0.000001,
                      abs((bottom - began) - (rep.liftSeconds + hold + lower)) < 0.000001 else {
                    throw TrainingError.invalidRecord
                }
                previousCompletion = rep.completedAtSeconds
            }
            var previousAttempt = -1.0
            for attempt in segment.attempts {
                try attempt.validate()
                guard attempt.startedAtSeconds >= previousAttempt, attempt.endedAtSeconds <= duration + 0.25 else {
                    throw TrainingError.invalidRecord
                }
                previousAttempt = attempt.endedAtSeconds
            }
            let accepted = segment.attempts.filter { $0.outcome == .accepted }
            guard segment.metrics.processedFrames >= segment.repetitions.count * 4,
                  segment.droppedAttempts > 0 || accepted.count == segment.repetitions.count,
                  accepted.allSatisfy({ event in segment.repetitions.contains {
                      abs(($0.startedAtSeconds ?? -1) - event.startedAtSeconds) < 0.000001 &&
                      abs($0.completedAtSeconds - event.endedAtSeconds) < 0.000001
                  } }) else { throw TrainingError.invalidRecord }
            previousEnd = segment.endedAt
        }
    }
}

extension LocalSetRecord {
    var resolvedCountingMethod: String {
        guard let evidence = visualEvidence, evidence.hasObservedFrames else { return "manual" }
        guard let actual = sideRepetitions?.count(for: evidence.settings.arm) ?? reps else { return "unconfirmed" }
        if evidence.fallbackReason != nil { return "manual_with_visual" }
        return actual == evidence.automaticCount ? "vision_confirmed" : "vision_corrected"
    }
}

public enum WorkoutAssessmentStatus: String, Codable {
    case measured, estimated, notAssessed = "not_assessed", insufficientEvidence = "insufficient_evidence", notApplicable = "not_applicable"
}

public struct WorkoutPhaseObservation: Codable, Equatable {
    public let repetitionIndex: Int
    public let phase: String
    public let observedSeconds: Double
    public let targetSeconds: Double?
    public let trackingGapSeconds: Double?
    public let status: WorkoutAssessmentStatus
    public let deltaSeconds: Double?
}

public struct WorkoutRhythmAssessment: Codable, Equatable {
    public let method: String
    public let status: WorkoutAssessmentStatus
    public let score: Double?
    public let phases: [WorkoutPhaseObservation]

    private init(status: WorkoutAssessmentStatus, phases: [WorkoutPhaseObservation]) {
        method = "phase_duration_comparison_v1"; self.status = status; score = nil; self.phases = phases
    }

    public static func assess(repetitions: [CurlRepetition], tempo: [TempoPhase]) -> Self {
        let keys = ["lift", "peak", "lower"]
        let targets = keys.map { key in
            tempo.first(where: { $0.phase == key && $0.seconds.isFinite && $0.seconds > 0 })?.seconds
        }
        guard targets.contains(where: { $0 != nil }) else { return Self(status: .notApplicable, phases: []) }
        guard !repetitions.isEmpty else { return Self(status: .insufficientEvidence, phases: []) }
        var phases: [WorkoutPhaseObservation] = []
        for (index, rep) in repetitions.enumerated() {
            let estimated = (rep.trackingGapSeconds ?? 0) > 0 || (rep.geometryFallbackFrames ?? 0) > 0
            for (phase, observed) in [rep.liftSeconds, rep.holdSeconds, rep.lowerSeconds].enumerated() {
                guard let observed else { continue }
                let status: WorkoutAssessmentStatus = targets[phase] == nil ? .notApplicable : (estimated ? .estimated : .measured)
                phases.append(WorkoutPhaseObservation(repetitionIndex: index + 1, phase: keys[phase], observedSeconds: observed,
                    targetSeconds: targets[phase], trackingGapSeconds: rep.trackingGapSeconds, status: status,
                    deltaSeconds: status == .measured ? observed - targets[phase]! : nil))
            }
            if let observation = rep.precedingReturn, let seconds = observation.measurement.durationSeconds {
                // motion-strategy-lat-pulldown: observed return ends at a counting gate,
                // not full anatomical extension. Keep the interval but do not score a full-phase target.
                phases.append(WorkoutPhaseObservation(repetitionIndex: index, phase: "lower",
                    observedSeconds: seconds, targetSeconds: targets[2], trackingGapSeconds: nil,
                    status: targets[2] == nil ? .notApplicable : .estimated,
                    deltaSeconds: nil))
            }
        }
        return Self(status: phases.contains(where: { $0.status == .estimated }) ? .estimated : .measured, phases: phases)
    }
}

public struct WorkoutFormAssessment: Codable, Equatable {
    public let method: String
    public let status: WorkoutAssessmentStatus
    public let score: Double?
    public init() { method = "not_enabled_part_1"; status = .notAssessed; score = nil }
}

extension TrainingPlan {
    public static func realExerciseDay1Draft() throws -> TrainingPlan {
        guard let url = Bundle.module.url(forResource: "real-exercise-day-1-draft", withExtension: "json") else {
            throw TrainingError.invalidPlan
        }
        let plan = try JSONDecoder().decode(TrainingPlan.self, from: Data(contentsOf: url))
        try plan.validate()
        return plan
    }

    public static func nextTrainingTrialDraft() throws -> TrainingPlan {
        guard let url = Bundle.module.url(forResource: "next-training-trial-draft", withExtension: "json") else {
            throw TrainingError.invalidPlan
        }
        let plan = try JSONDecoder().decode(TrainingPlan.self, from: Data(contentsOf: url))
        try plan.validate()
        return plan
    }

    func validateSchedule() throws {
        guard (scheduledDate == nil) == (scheduledTimeZone == nil) else { throw TrainingError.invalidPlan }
        guard let date = scheduledDate, let zone = scheduledTimeZone else { return }
        guard let timeZone = TimeZone(identifier: zone), date.count == 10,
              date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { throw TrainingError.invalidPlan }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else { throw TrainingError.invalidPlan }
    }
}
