import Foundation

public struct SetTarget: Codable, Equatable {
    public var setIndex: Int
    public var targetReps: Int?
    public var targetDurationSeconds: Double?
    public var targetWeight: Double?
    public var weightUnit: String?
    public var restSeconds: Double

    public init(setIndex: Int, reps: Int? = 10, duration: Double? = nil, weight: Double? = nil, rest: Double = 90) {
        self.setIndex = setIndex
        targetReps = duration == nil ? reps : nil
        targetDurationSeconds = duration
        targetWeight = weight
        weightUnit = "kg"
        restSeconds = rest
    }
}

public struct TempoPhase: Codable, Equatable {
    public var phase: String
    public var seconds: Double
    public var visual: String

    public init(_ phase: String, seconds: Double, visual: String) {
        self.phase = phase
        self.seconds = seconds
        self.visual = visual
    }
}

public struct Exercise: Codable, Equatable, Identifiable {
    public var exerciseId: String
    public var name: String
    public var targetSets: [SetTarget]
    public var tempo: [TempoPhase]
    public var notes: String?
    public var visualObservation: WorkoutObservationSettings? = nil
    public var repetitionBasis: RepetitionBasis? = nil
    public var id: String { exerciseId }

    public init(id: String = UUID().uuidString, name: String, sets: [SetTarget], notes: String? = nil) {
        exerciseId = id
        self.name = name
        targetSets = sets
        tempo = [TempoPhase("lift", seconds: 2, visual: "expand"), TempoPhase("peak", seconds: 1, visual: "vibrate"), TempoPhase("lower", seconds: 3, visual: "shrink")]
        self.notes = notes
    }
}

public struct TrainingPlan: Codable, Equatable {
    public var focus: String
    public var warmup: String
    public var cooldown: String
    public var safetyNotes: String
    public var exercises: [Exercise]
    public var scheduledDate: String? = nil
    public var scheduledTimeZone: String? = nil
    public var totalSets: Int { exercises.reduce(0) { $0 + $1.targetSets.count } }

    public init(focus: String, exercises: [Exercise]) {
        self.focus = focus
        self.exercises = exercises
        warmup = "按自己的习惯热身后开始。"
        cooldown = "结束后按需要放松。"
        safetyNotes = "不舒服时停止，重量和次数在开始前确认。"
    }

    public static var starter: TrainingPlan {
        TrainingPlan(focus: "我的哑铃训练", exercises: [
            Exercise(id: "dumbbell_curl", name: "哑铃弯举", sets: [SetTarget(setIndex: 1), SetTarget(setIndex: 2)]),
            Exercise(id: "lateral_raise", name: "哑铃侧平举", sets: [SetTarget(setIndex: 1), SetTarget(setIndex: 2)])
        ])
    }

    public func validate() throws {
        try validateSchedule()
        guard !focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !exercises.isEmpty, exercises.count <= 50, totalSets <= 200,
              Set(exercises.map(\.exerciseId)).count == exercises.count else { throw TrainingError.invalidPlan }
        for exercise in exercises {
            try exercise.visualObservation?.validate()
            let visualBasis: RepetitionBasis = exercise.visualObservation?.exercise == .latPulldown ? .total : .perSide
            guard exercise.visualObservation == nil || (exercise.repetitionBasis == visualBasis && exercise.targetSets.allSatisfy { $0.targetReps != nil }) else {
                throw TrainingError.invalidPlan
            }
            guard !exercise.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !exercise.targetSets.isEmpty else { throw TrainingError.invalidPlan }
            for (index, target) in exercise.targetSets.enumerated() {
                guard target.setIndex == index + 1, target.restSeconds.isFinite,
                      (0...3600).contains(target.restSeconds),
                      target.weightUnit == nil || ["kg", "lb", "bodyweight", "machine_level"].contains(target.weightUnit!),
                      (target.targetReps != nil) != (target.targetDurationSeconds != nil) else { throw TrainingError.invalidPlan }
                if let reps = target.targetReps, !(1...1000).contains(reps) { throw TrainingError.invalidPlan }
                if let duration = target.targetDurationSeconds, !duration.isFinite || !(1...7200).contains(duration) { throw TrainingError.invalidPlan }
                if let weight = target.targetWeight, !weight.isFinite || !(0...1000).contains(weight) { throw TrainingError.invalidPlan }
            }
            guard exercise.tempo.allSatisfy({ $0.seconds.isFinite && $0.seconds > 0 && $0.seconds <= 60 }) else { throw TrainingError.invalidPlan }
        }
    }
}

public enum TrainingStage: String, Codable {
    case ready, active, paused, feedback, rest, summary, confirmed
}

public enum SetFeedback: String, Codable, CaseIterable {
    case comfortable, tooHard, tooEasy, notFollowed, uncertain, pain
    public var label: String {
        switch self {
        case .comfortable: return "合适"
        case .tooHard: return "太重 / 太难"
        case .tooEasy: return "太轻松"
        case .notFollowed: return "没跟上节奏"
        case .uncertain: return "不确定动作"
        case .pain: return "疼痛 / 不舒服"
        }
    }
}

public struct LocalSetRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var exerciseId: String
    public var exerciseName: String
    public var target: SetTarget
    public var status: String
    public var reps: Int?
    public var weight: Double?
    public var durationSeconds: Double
    public var feedback: [SetFeedback]
    public var notes: String
    public var startedAt: Date?
    public var endedAt: Date
    public var countingMethod = "manual"
    public var repetitionBasis: RepetitionBasis? = nil
    public var sideRepetitions: SideRepetitions? = nil
    public var visualEvidence: WorkoutVisualEvidence? = nil
    public var correctionReason: String? = nil
    public var rhythmAssessment: WorkoutRhythmAssessment? = nil
    public var formAssessment: WorkoutFormAssessment? = nil
    public var weightConfirmation: WeightConfirmation? = nil
    public var trialReview: TrialReview? = nil
}

public enum TrainingError: LocalizedError {
    case invalidPlan, invalidTransition, invalidRecord, activeSessionExists, corruptArchive, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: return "计划不完整，或次数、时长、重量超出范围。"
        case .invalidTransition: return "当前训练状态不允许这个操作。"
        case .invalidRecord: return "请确认实际次数和重量；它们不能为负数。"
        case .activeSessionExists: return "还有一份未结束的训练，请先继续或结束它。"
        case .corruptArchive: return "本地记录无法读取。原文件已保留，请导出文件后检查。"
        case .unsupportedVersion: return "这份记录来自不同版本，原文件已保留。"
        }
    }
}

public struct TrainingSession: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var plan: TrainingPlan
    public private(set) var stage: TrainingStage = .ready
    public private(set) var exerciseIndex = 0
    public private(set) var setIndex = 0
    public private(set) var records: [LocalSetRecord] = []
    public private(set) var startedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var confirmedAt: Date?
    public private(set) var setStartedAt: Date?
    public private(set) var segmentStartedAt: Date?
    public private(set) var lastCheckpointAt: Date
    public private(set) var accumulatedSeconds: Double = 0
    public private(set) var restDeadline: Date?
    public private(set) var restDurationSeconds: Double = 0
    public private(set) var currentWeight: Double?
    public private(set) var currentWeightConfirmation: WeightConfirmation? = nil
    public private(set) var endedEarly = false
    public var summaryNote = ""
    public private(set) var currentSetAttemptId: UUID? = UUID()
    public private(set) var currentObservationId: UUID? = nil
    public private(set) var currentVisualEvidence: WorkoutVisualEvidence? = nil
    public var currentSetBinding: WorkoutSetBinding? {
        currentSetAttemptId.map { WorkoutSetBinding(sessionId: id, exerciseId: exercise.exerciseId,
            setIndex: target.setIndex, attemptId: $0) }
    }

    public var exercise: Exercise { plan.exercises[exerciseIndex] }
    public var target: SetTarget { exercise.targetSets[setIndex] }
    public var isFinished: Bool { stage == .confirmed }
    public var progress: Double { Double(records.count) / Double(max(1, plan.totalSets)) }

    public init(plan: TrainingPlan, now: Date) throws {
        try plan.validate()
        self.plan = plan
        startedAt = now
        lastCheckpointAt = now
        let firstTarget = plan.exercises[0].targetSets[0]
        currentWeight = firstTarget.weightUnit == "bodyweight" ? nil : firstTarget.targetWeight
    }

    public func elapsed(at now: Date) -> Double {
        accumulatedSeconds + (segmentStartedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    public func restRemaining(at now: Date) -> Double {
        max(0, restDeadline?.timeIntervalSince(now) ?? 0)
    }

    public mutating func setWeight(_ weight: Double?) throws {
        guard stage == .ready || stage == .feedback else { throw TrainingError.invalidTransition }
        guard target.weightUnit != "bodyweight" || weight == nil else { throw TrainingError.invalidRecord }
        if let weight, !weight.isFinite || !(0...1000).contains(weight) { throw TrainingError.invalidRecord }
        if currentWeight != weight { currentWeightConfirmation = nil }
        currentWeight = weight
    }

    public mutating func confirmCurrentWeight(binding: WorkoutSetBinding, at now: Date) throws {
        guard stage == .ready, binding == currentSetBinding, now.timeIntervalSince1970.isFinite else { throw TrainingError.invalidTransition }
        guard currentWeightConfirmation == nil else { return }
        currentWeightConfirmation = WeightConfirmation(attemptID: binding.attemptId, weight: currentWeight,
            unit: target.weightUnit, source: .beforeSet, confirmedAt: now)
    }

    public mutating func startSet(at now: Date) throws {
        guard currentObservationId == nil else { throw TrainingError.invalidTransition }
        try startTimedSet(at: now)
        if currentVisualEvidence != nil { currentVisualEvidence?.useManual(reason: .userChoice, at: now) }
    }

    private mutating func startTimedSet(at now: Date) throws {
        guard stage == .ready || stage == .paused else { throw TrainingError.invalidTransition }
        if currentSetAttemptId == nil { currentSetAttemptId = UUID() }
        if stage == .ready {
            accumulatedSeconds = 0
            setStartedAt = now
        }
        stage = .active
        segmentStartedAt = now
        lastCheckpointAt = now
    }

    @discardableResult
    public mutating func prepareVisual(settings: WorkoutObservationSettings, configuration: PoseCounterConfiguration,
                                       runtimePolicy: PoseRuntimePolicy, source: VisionInputSource, at now: Date) throws -> UUID {
        guard stage == .ready || stage == .paused, currentObservationId == nil,
              exercise.visualObservation?.exercise == settings.exercise, target.targetReps != nil else {
            throw TrainingError.invalidTransition
        }
        var next = self
        if next.currentSetAttemptId == nil { next.currentSetAttemptId = UUID() }
        if let existing = next.currentVisualEvidence {
            guard existing.settings == settings, existing.configuration == configuration,
                  existing.runtimePolicy == runtimePolicy, existing.source == source, existing.fallbackReason == nil else {
                throw TrainingError.invalidTransition
            }
        } else {
            next.currentVisualEvidence = try WorkoutVisualEvidence(binding: next.currentSetBinding!, settings: settings,
                configuration: configuration, runtimePolicy: runtimePolicy, source: source)
        }
        let id = try next.currentVisualEvidence!.prepare(at: now)
        next.currentObservationId = id
        self = next
        return id
    }

    public mutating func beginVisual(observationId: UUID, at now: Date) throws {
        guard observationId == currentObservationId, currentVisualEvidence != nil else { throw TrainingError.invalidTransition }
        var next = self
        try next.currentVisualEvidence!.begin(id: observationId, at: now)
        try next.startTimedSet(at: now)
        self = next
    }

    public mutating func updateVisual(binding: WorkoutSetBinding, observationId: UUID,
                                     repetitions: [CurlRepetition], attempts: [PoseAttemptEvent], droppedAttempts: Int = 0,
                                     metrics: VisionMetrics, resetCounts: [String: Int] = [:], captureContext: VisionCaptureContext? = nil, at now: Date) throws {
        guard stage == .active, binding == currentSetBinding, observationId == currentObservationId,
              currentVisualEvidence?.binding == binding else { throw TrainingError.invalidTransition }
        try currentVisualEvidence!.update(id: observationId, repetitions: repetitions, attempts: attempts,
            droppedAttempts: droppedAttempts, metrics: metrics, resetCounts: resetCounts, captureContext: captureContext, at: now)
        lastCheckpointAt = now
    }

    public mutating func useManualCounting(reason: WorkoutManualReason, at now: Date) throws {
        guard stage == .ready || stage == .active || stage == .paused else { throw TrainingError.invalidTransition }
        currentVisualEvidence?.useManual(reason: reason, at: now)
        currentObservationId = nil
    }

    public mutating func cancelVisualPreparation(at now: Date) throws {
        guard stage == .ready || stage == .paused, currentObservationId != nil else { throw TrainingError.invalidTransition }
        currentVisualEvidence?.end(reason: .pause, at: now)
        currentObservationId = nil
    }

    mutating func invalidateVisualAfterRestart() {
        currentVisualEvidence?.end(reason: .restart, at: lastCheckpointAt)
        currentObservationId = nil
    }

    public mutating func checkpoint(at now: Date) {
        if stage == .active { lastCheckpointAt = now }
    }

    public mutating func pause(at now: Date) throws {
        guard stage == .active else { throw TrainingError.invalidTransition }
        accumulatedSeconds = elapsed(at: now)
        segmentStartedAt = nil
        lastCheckpointAt = now
        stage = .paused
        currentVisualEvidence?.end(reason: .pause, at: now)
        currentObservationId = nil
    }

    public mutating func finishSet(at now: Date) throws {
        guard stage == .active || stage == .paused else { throw TrainingError.invalidTransition }
        accumulatedSeconds = elapsed(at: now)
        segmentStartedAt = nil
        lastCheckpointAt = now
        stage = .feedback
        currentVisualEvidence?.end(reason: .userFinished, at: now)
        currentObservationId = nil
    }

    public mutating func submit(reps: Int?, sideRepetitions: SideRepetitions? = nil, feedback: [SetFeedback], notes: String, at now: Date, review: TrialReview? = nil) throws {
        guard stage == .feedback else { throw TrainingError.invalidTransition }
        try review?.validate()
        guard now.timeIntervalSince1970.isFinite else { throw TrainingError.invalidRecord }
        if let reps, !(0...1000).contains(reps) { throw TrainingError.invalidRecord }
        try sideRepetitions?.validate()
        guard sideRepetitions == nil || (exercise.repetitionBasis == .perSide && target.targetReps != nil),
              sideRepetitions == nil || reps == nil || sideRepetitions!.commonCount == reps,
              target.targetReps == nil || reps != nil || sideRepetitions != nil else { throw TrainingError.invalidRecord }
        let sides = sideRepetitions ?? (exercise.repetitionBasis == .perSide && reps != nil ? SideRepetitions(left: reps, right: reps) : nil)
        let actual = sides.map(\.commonCount) ?? reps
        let reached = target.targetReps.map { expected in
            sides.map { ($0.left ?? -1) >= expected && ($0.right ?? -1) >= expected } ?? ((actual ?? 0) >= expected)
        } ?? (accumulatedSeconds >= (target.targetDurationSeconds ?? 0))
        let status = feedback.contains(.pain) || !reached ? "partial" : "completed"
        // This command confirms the complete review form, including an explicitly unknown weight.
        if currentSetAttemptId == nil { currentSetAttemptId = UUID() }
        currentWeightConfirmation = WeightConfirmation(attemptID: currentSetAttemptId!, weight: currentWeight,
            unit: target.weightUnit, source: .setReview, confirmedAt: now)
        appendRecord(reps: target.targetReps == nil ? nil : actual, sides: sides, feedback: feedback, notes: notes, status: status, at: now)
        records[records.count - 1].trialReview = review
        if feedback.contains(.pain) {
            endedEarly = true
            close(at: now)
        } else {
            advance(at: now)
        }
    }

    public mutating func skip(at now: Date) throws {
        guard stage == .ready else { throw TrainingError.invalidTransition }
        appendRecord(reps: nil, feedback: [], notes: "跳过本组", status: "skipped", at: now)
        advance(at: now)
    }

    public mutating func readyAfterRest(at now: Date) throws {
        guard stage == .rest else { throw TrainingError.invalidTransition }
        restDeadline = nil
        stage = .ready
        lastCheckpointAt = now
    }

    public mutating func extendRest(by seconds: Double, at now: Date) throws {
        guard stage == .rest, seconds > 0, seconds <= 3600 else { throw TrainingError.invalidTransition }
        restDurationSeconds = restRemaining(at: now) == 0 ? seconds : restDurationSeconds + seconds
        restDeadline = max(restDeadline ?? now, now).addingTimeInterval(seconds)
    }

    public mutating func reviseRecord(id: UUID, reps: Int?, weight: Double?, notes: String, sideRepetitions: SideRepetitions? = nil, at now: Date = Date()) throws {
        guard stage == .summary, let index = records.firstIndex(where: { $0.id == id }),
              records[index].status != "skipped" else { throw TrainingError.invalidTransition }
        if let reps, !(0...1000).contains(reps) { throw TrainingError.invalidRecord }
        if let weight, !weight.isFinite || !(0...1000).contains(weight) { throw TrainingError.invalidRecord }
        let target = records[index].target
        guard now.timeIntervalSince1970.isFinite, target.weightUnit != "bodyweight" || weight == nil else { throw TrainingError.invalidRecord }
        try sideRepetitions?.validate()
        guard sideRepetitions == nil || (records[index].repetitionBasis == .perSide && target.targetReps != nil),
              sideRepetitions == nil || reps == nil || sideRepetitions!.commonCount == reps else { throw TrainingError.invalidRecord }
        let sides = sideRepetitions ?? (records[index].repetitionBasis == .perSide && reps != nil
            ? SideRepetitions(left: reps, right: reps) : records[index].sideRepetitions)
        guard target.targetReps == nil || reps != nil || sides != nil else { throw TrainingError.invalidRecord }
        records[index].sideRepetitions = sides
        records[index].reps = target.targetReps == nil ? nil : (sides.map(\.commonCount) ?? reps)
        records[index].weight = weight
        records[index].weightConfirmation = WeightConfirmation(attemptID: id, weight: weight, unit: target.weightUnit,
            source: .summaryCorrection, confirmedAt: now)
        records[index].notes = notes
        if let expected = target.targetReps {
            let reached = sides.map { ($0.left ?? -1) >= expected && ($0.right ?? -1) >= expected } ?? ((reps ?? 0) >= expected)
            records[index].status = reached && !records[index].feedback.contains(.pain) ? "completed" : "partial"
        }
        var revised = records[index]
        applyCountingSource(to: &revised)
        records[index] = revised
    }

    public mutating func endEarly(at now: Date) throws {
        guard stage != .confirmed && stage != .summary else { throw TrainingError.invalidTransition }
        if stage == .active || stage == .paused || stage == .feedback {
            accumulatedSeconds = elapsed(at: now)
            segmentStartedAt = nil
            currentVisualEvidence?.end(reason: .userFinished, at: now)
            appendRecord(reps: nil, feedback: [], notes: "提前结束；实际次数未确认", status: "partial", at: now)
        }
        endedEarly = true
        close(at: now)
    }

    public mutating func confirm(note: String, at now: Date) throws {
        guard stage == .summary else { throw TrainingError.invalidTransition }
        summaryNote = note
        confirmedAt = now
        stage = .confirmed
    }

    private mutating func appendRecord(reps: Int?, sides: SideRepetitions? = nil, feedback: [SetFeedback], notes: String, status: String, at now: Date) {
        currentVisualEvidence?.end(reason: .userFinished, at: now)
        var record = LocalSetRecord(id: currentSetAttemptId ?? UUID(), exerciseId: exercise.exerciseId, exerciseName: exercise.name,
            target: target, status: status, reps: reps, weight: status == "skipped" ? nil : currentWeightConfirmation?.weight, durationSeconds: accumulatedSeconds,
            feedback: Set(feedback).sorted { $0.rawValue < $1.rawValue }, notes: notes,
            startedAt: setStartedAt, endedAt: stage == .feedback ? lastCheckpointAt : now)
        record.repetitionBasis = exercise.repetitionBasis; record.sideRepetitions = sides
        record.weightConfirmation = status == "skipped" ? nil : currentWeightConfirmation
        record.visualEvidence = currentVisualEvidence
        if let evidence = currentVisualEvidence {
            record.rhythmAssessment = WorkoutRhythmAssessment.assess(repetitions: evidence.repetitions, tempo: exercise.tempo)
            record.formAssessment = WorkoutFormAssessment()
        }
        applyCountingSource(to: &record)
        records.append(record)
        currentVisualEvidence = nil; currentObservationId = nil
    }

    private func applyCountingSource(to record: inout LocalSetRecord) {
        record.countingMethod = record.resolvedCountingMethod
        guard let evidence = record.visualEvidence, evidence.hasObservedFrames else { return }
        guard let actual = record.sideRepetitions?.count(for: evidence.settings.arm) ?? record.reps else {
            return
        }
        record.correctionReason = actual == evidence.automaticCount ? nil : (record.notes.isEmpty ? "人工核对" : record.notes)
    }

    private mutating func close(at now: Date) {
        endedAt = now
        restDeadline = nil
        stage = .summary
        currentVisualEvidence?.end(reason: .userFinished, at: now)
        currentObservationId = nil
    }

    private mutating func advance(at now: Date) {
        let previousExercise = exerciseIndex
        let previousTarget = target
        let rest = target.restSeconds
        if setIndex + 1 < exercise.targetSets.count {
            setIndex += 1
        } else if exerciseIndex + 1 < plan.exercises.count {
            exerciseIndex += 1
            setIndex = 0
        } else {
            close(at: now)
            return
        }
        if exerciseIndex != previousExercise || target.targetWeight != previousTarget.targetWeight || target.weightUnit != previousTarget.weightUnit {
            currentWeight = target.weightUnit == "bodyweight" ? nil : target.targetWeight
        }
        accumulatedSeconds = 0
        setStartedAt = nil
        segmentStartedAt = nil
        restDeadline = now.addingTimeInterval(rest)
        restDurationSeconds = rest
        stage = .rest
        currentSetAttemptId = UUID()
        currentWeightConfirmation = nil
    }
}

public struct TrainingArchive: Codable, Equatable {
    public var schemaVersion = 1
    public var plan = TrainingPlan.starter
    public var sessions: [TrainingSession] = []
    public init() {}
    public var currentSession: TrainingSession? { sessions.last(where: { !$0.isFinished }) }

    public func validate() throws {
        guard schemaVersion == 1 else { throw TrainingError.unsupportedVersion }
        try plan.validate()
        guard sessions.filter({ !$0.isFinished }).count <= 1,
              Set(sessions.map(\.id)).count == sessions.count else { throw TrainingError.corruptArchive }
        for session in sessions {
            try session.plan.validate()
            guard session.plan.exercises.indices.contains(session.exerciseIndex),
                  session.exercise.targetSets.indices.contains(session.setIndex),
                  session.records.count <= session.plan.totalSets,
                  session.accumulatedSeconds.isFinite, session.accumulatedSeconds >= 0,
                  session.stage != .active || session.segmentStartedAt != nil,
                  session.stage != .confirmed || session.confirmedAt != nil,
                  Set(session.records.map(\.id)).count == session.records.count else { throw TrainingError.corruptArchive }
            if let evidence = session.currentVisualEvidence {
                try evidence.validate()
                guard evidence.binding == session.currentSetBinding,
                      evidence.settings.exercise == session.exercise.visualObservation?.exercise,
                      session.currentObservationId == nil || (evidence.segments.last?.id == session.currentObservationId && evidence.segments.last?.endedAt == nil) else {
                    throw TrainingError.corruptArchive
                }
            } else if session.currentObservationId != nil { throw TrainingError.corruptArchive }
            if let confirmation = session.currentWeightConfirmation {
                guard let attemptID = session.currentSetAttemptId else { throw TrainingError.corruptArchive }
                try confirmation.validate(attemptID: attemptID, weight: session.currentWeight, unit: session.target.weightUnit)
            }
            for record in session.records {
                guard ["completed", "partial", "skipped"].contains(record.status),
                      record.durationSeconds.isFinite, record.durationSeconds >= 0,
                      record.reps.map({ (0...1000).contains($0) }) ?? true,
                      record.weight.map({ $0.isFinite && (0...1000).contains($0) }) ?? true else { throw TrainingError.corruptArchive }
                try record.sideRepetitions?.validate()
                try record.trialReview?.validate()
                try record.weightConfirmation?.validate(attemptID: record.id, weight: record.weight, unit: record.target.weightUnit)
                guard record.sideRepetitions == nil || (record.repetitionBasis == .perSide && record.reps == record.sideRepetitions?.commonCount) else {
                    throw TrainingError.corruptArchive
                }
                if let evidence = record.visualEvidence {
                    try evidence.validate()
                    guard let exercise = session.plan.exercises.first(where: { $0.exerciseId == record.exerciseId }),
                          evidence.binding.sessionId == session.id, evidence.binding.exerciseId == record.exerciseId,
                          evidence.binding.attemptId == record.id, evidence.binding.setIndex == record.target.setIndex,
                          evidence.settings.exercise == exercise.visualObservation?.exercise,
                          evidence.segments.allSatisfy({ $0.endedAt != nil }),
                          record.rhythmAssessment == WorkoutRhythmAssessment.assess(repetitions: evidence.repetitions, tempo: exercise.tempo),
                          record.formAssessment == WorkoutFormAssessment(),
                          record.countingMethod == record.resolvedCountingMethod else {
                        throw TrainingError.corruptArchive
                    }
                } else if record.rhythmAssessment != nil || record.formAssessment != nil { throw TrainingError.corruptArchive }
            }
        }
    }
}

public final class LocalTrainingRepository {
    public let fileURL: URL
    public private(set) var archive: TrainingArchive
    private let writer: (Data, URL) throws -> Void

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        let whole = ISO8601DateFormatter()
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let timestamp = date.timeIntervalSince1970
            // Keep old whole-second dates stable; visual checkpoints retain millisecond precision.
            try value.encode(abs(timestamp - timestamp.rounded()) < 0.000001 ? whole.string(from: date) : precise.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let whole = ISO8601DateFormatter()
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            let text = try value.decode(String.self)
            guard let date = precise.date(from: text) ?? whole.date(from: text) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid ISO-8601 date")
            }
            return date
        }
        return decoder
    }

    public init(fileURL: URL, writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        self.fileURL = fileURL
        self.writer = writer
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                archive = try Self.decoder().decode(TrainingArchive.self, from: Data(contentsOf: fileURL))
            } catch { throw TrainingError.corruptArchive }
            try archive.validate()
        } else {
            archive = TrainingArchive()
        }
        // A terminated process cannot establish how long the user kept exercising.
        if let index = archive.sessions.lastIndex(where: { $0.stage == .active || $0.currentObservationId != nil }) {
            var recovered = archive
            recovered.sessions[index].invalidateVisualAfterRestart()
            if recovered.sessions[index].stage == .active {
                try recovered.sessions[index].pause(at: recovered.sessions[index].lastCheckpointAt)
            }
            try persist(recovered)
        }
    }

    public func update(_ mutate: (inout TrainingArchive) throws -> Void) throws {
        var next = archive
        try mutate(&next)
        try next.validate()
        try persist(next)
    }

    private func persist(_ next: TrainingArchive) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writer(Self.encoder().encode(next), fileURL)
        archive = next
    }

    public func start(plan: TrainingPlan, at now: Date) throws {
        try update { archive in
            guard archive.currentSession == nil else { throw TrainingError.activeSessionExists }
            archive.plan = plan
            archive.sessions.append(try TrainingSession(plan: plan, now: now))
        }
    }

    public func updateCurrent(_ mutate: (inout TrainingSession) throws -> Void) throws {
        try update { archive in
            guard let index = archive.sessions.lastIndex(where: { !$0.isFinished }) else { throw TrainingError.invalidTransition }
            try mutate(&archive.sessions[index])
        }
    }
}
