import Foundation

public struct GuidanceContext: Codable, Equatable {
    public var sessionID: String
    public var attemptID: String
    public var observationID: String
    public var executionGeneration: String?
    public init(sessionID: String, attemptID: String, observationID: String, executionGeneration: String? = nil) {
        self.sessionID = sessionID; self.attemptID = attemptID; self.observationID = observationID; self.executionGeneration = executionGeneration
    }
    public var key: String { "\(sessionID)/\(attemptID)/\(observationID)" + (executionGeneration.map { "/\($0)" } ?? "") }
}

public enum GuidanceMode: String, Codable, CaseIterable { case observed, planned, off }
public enum GuidanceStage: String, Codable { case idle, ready, preparing, countdown, active, paused, feedback, rest, summary, confirmed }
public enum GuidanceSource: String, Codable { case observed, planned, unavailable }
public enum GuidanceCueKind: String, Codable { case count, lifecycle, phase, encouragement }

/// Snapshot of evidence available NOW. No completed-repetition backfill is accepted here.
public struct MotionObservation: Codable {
    public var observedAt: Double
    public var phase: CurlPhase
    public var quality: PoseQuality
    public var tracking: PoseTrackingState
    public var returnPhase: PoseReturnPhaseObservation?
    public init(observedAt: Double, snapshot: CurlSnapshot) {
        self.observedAt = observedAt; phase = snapshot.phase; quality = snapshot.quality; tracking = snapshot.trackingState
        returnPhase = snapshot.returnPhaseObservation
    }
    public func isFresh(at time: Double) -> Bool {
        observedAt.isFinite && time >= observedAt && time - observedAt <= 0.35 && quality == .valid && tracking == .tracking &&
            returnPhase?.status != .unavailable
    }
    public var guidancePhase: CurlPhase {
        (phase == .top || phase == .lowering) && returnPhase?.status == .returning ? .lowering : phase
    }
}

public struct GuidanceInput: Codable {
    public var context: GuidanceContext
    /// Monotonic host seconds, also used by the speech scheduler. Video time is mapped at the adapter.
    public var time: Double
    public var stage: GuidanceStage
    public var exercise: VisionExercise?
    public var mode: GuidanceMode
    /// Committed count for this attempt, not a peak detector or a UI manual correction.
    public var count: Int
    public var targetReps: Int?
    public var motion: MotionObservation?
    public var tempo: [TempoPhase]
    public var elapsed: Double
    public var countdown: Int?
    public var remainingSets: Int?
    public var restRemainingSeconds: Double?
    /// Missing in legacy replay inputs; nil preserves their original weight prompt.
    public var requiresWeightConfirmation: Bool?
    /// Stops the planned cue loop, not the workout or its actual repetition count.
    public var plannedCycleLimit: Int?
    public init(context: GuidanceContext, time: Double, stage: GuidanceStage, exercise: VisionExercise?,
                mode: GuidanceMode, count: Int, targetReps: Int?, motion: MotionObservation?,
                tempo: [TempoPhase], elapsed: Double, countdown: Int? = nil, remainingSets: Int? = nil, restRemainingSeconds: Double? = nil,
                requiresWeightConfirmation: Bool = true, plannedCycleLimit: Int? = nil) {
        self.context = context; self.time = time; self.stage = stage; self.exercise = exercise; self.mode = mode
        self.count = count; self.targetReps = targetReps; self.motion = motion; self.tempo = tempo
        self.elapsed = elapsed; self.countdown = countdown; self.remainingSets = remainingSets
        self.restRemainingSeconds = restRemainingSeconds
        self.requiresWeightConfirmation = requiresWeightConfirmation; self.plannedCycleLimit = plannedCycleLimit
    }
}

public struct GuidancePresentation: Codable, Equatable {
    public var source: GuidanceSource
    public var label: String
    public var scale: Double
    public var isMoving: Bool
    public var phaseToken: String?
    public static let unavailable = GuidancePresentation(source: .unavailable, label: "等待有效观察", scale: 0.8, isMoving: false)
}

public struct GuidanceCue: Codable, Equatable, Identifiable {
    public var schema = "fox.guidance_cue.v1"
    public var id: String
    public var context: GuidanceContext
    public var kind: GuidanceCueKind
    public var stage: GuidanceStage
    public var text: String
    public var createdAt: Double
    /// Expiration is a START deadline, not permission to keep talking after context changes.
    public var expiresAt: Double
    public var phaseToken: String?
    public var requiresObservation: Bool? = nil
    public init(id: String, context: GuidanceContext, kind: GuidanceCueKind, stage: GuidanceStage,
                text: String, createdAt: Double, expiresAt: Double, phaseToken: String? = nil, requiresObservation: Bool? = nil) {
        self.id = id; self.context = context; self.kind = kind; self.stage = stage; self.text = text
        self.createdAt = createdAt; self.expiresAt = expiresAt; self.phaseToken = phaseToken
        self.requiresObservation = requiresObservation
    }
    public var priority: Int {
        switch kind { case .count: return 100; case .lifecycle: return 80; case .phase: return 50; case .encouragement: return 10 }
    }
    public func isValid(at time: Double, context: GuidanceContext, stage: GuidanceStage, phaseToken: String?, observationAvailable: Bool? = nil) -> Bool {
        time.isFinite && time >= createdAt && time <= expiresAt &&
            isCurrent(context: context, stage: stage, phaseToken: phaseToken, observationAvailable: observationAvailable)
    }
    public func isCurrent(context: GuidanceContext, stage: GuidanceStage, phaseToken: String?, observationAvailable: Bool? = nil) -> Bool {
        self.context == context && self.stage == stage &&
            (requiresObservation == nil || requiresObservation == observationAvailable) &&
            (self.phaseToken == nil || self.phaseToken == phaseToken)
    }
}

public struct GuidanceUpdate: Equatable {
    public var presentation: GuidancePresentation
    public var cues: [GuidanceCue]
}
