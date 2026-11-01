import Foundation

public enum CountOnlyPixelMirror: String, Codable { case unknown, knownUnmirrored = "known_unmirrored", knownMirrored = "known_mirrored" }

/// A new host run has its own source PTS origin. Runs never provide phase/period measurements.
public struct WorkoutCountOnlyRun: Codable, Equatable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public private(set) var updatedAt: Date
    public private(set) var endedAt: Date?
    public private(set) var endReason: WorkoutObservationInterruption?
    public private(set) var evidence: CountOnlyEvidence?
    /// The selected strategy is recorded before the first frame. Nil is the legacy 0.5 route.
    public let declaredStrategyID: String?
    public var resolvedStrategyID: String? { declaredStrategyID ?? evidence?.strategyID }
    public private(set) var appleRevision: Int?
    public var coordinateConvention = "vision-normalized-bottom-left-pixel-up-v1"
    public let pixelMirror: CountOnlyPixelMirror

    init(id: UUID, at time: Date, source: VisionInputSource, strategyID: String?) {
        self.id=id;startedAt=time;updatedAt=time;declaredStrategyID=strategyID
        pixelMirror=source == .camera ? .knownUnmirrored:.unknown
    }
    mutating func update(_ value: CountOnlyEvidence, revision: Int, at time: Date) throws {
        try value.validate()
        guard endedAt == nil, time >= updatedAt, revision > 0, value.strategyID == resolvedStrategyID else { throw TrainingError.invalidTransition }
        if let old=evidence {
            guard value.inputOriginSeconds == old.inputOriginSeconds,
                  value.formalStartSeconds == old.formalStartSeconds,
                  value.side == old.side, value.action == old.action, value.algorithm == old.algorithm, value.strategyID == old.strategyID, value.source == old.source,
                  value.events.starts(with: old.events),
                  (value.lastInputSeconds ?? -1) >= (old.lastInputSeconds ?? -1),
                  appleRevision == revision else { throw TrainingError.invalidTransition }
        }
        evidence=value; appleRevision=revision; updatedAt=time
    }
    mutating func end(_ reason: WorkoutObservationInterruption, at time: Date) {
        guard endedAt == nil else { return }
        endedAt=max(time,updatedAt);endReason=reason
    }
}

/// Product binding/persistence, separate from WorkoutVisualEvidence and manual confirmation.
public struct WorkoutCountOnlyEvidence: Codable, Equatable {
    public var schema = "fox.workout_count_only.v1"
    public let binding: WorkoutSetBinding
    public let side: ArmSide
    public let action: CountOnlyAction
    public let source: VisionInputSource
    public private(set) var runs: [WorkoutCountOnlyRun] = []
    public var automaticCount: Int { runs.reduce(0) { $0 + ($1.evidence?.observedCount ?? 0) } }
    public var suggestedCount: Int? { automaticCount > 0 ? automaticCount : nil }
    public var hasObservedFrames: Bool { runs.contains { $0.evidence?.lastInputSeconds != nil } }
    /// A received frame is not a usable observation. A valid segment may have zero events.
    public var observedCountIfValid: Int? {
        runs.contains { !($0.evidence?.segments.isEmpty ?? true) } ? automaticCount : nil
    }
    public var isSquatTrial: Bool { action == .squat && runs.contains { $0.resolvedStrategyID == "squat-side-joint-floor-25-h1-v1" } }
    public var phaseStatus: String { "not_provided" }
    public init(binding: WorkoutSetBinding, side: ArmSide, source: VisionInputSource, action: CountOnlyAction = .curl) {
        self.binding=binding; self.side=side; self.source=source; self.action=action
    }
    mutating func begin(at now: Date, strategyID: String? = nil) throws -> UUID {
        guard now.timeIntervalSince1970.isFinite, runs.last?.endedAt != nil || runs.isEmpty,
              runs.last.map({ now >= ($0.endedAt ?? $0.updatedAt) }) ?? true else { throw TrainingError.invalidTransition }
        if let strategyID {
            guard action == .squat, strategyID == "squat-side-joint-floor-25-h1-v1" else { throw TrainingError.invalidTransition }
        }
        let id=UUID();runs.append(WorkoutCountOnlyRun(id:id,at:now,source:source,strategyID:strategyID));return id
    }
    mutating func update(id: UUID, evidence: CountOnlyEvidence, revision: Int, at now: Date) throws {
        guard let i=runs.indices.last, runs[i].id == id, evidence.side == side, evidence.action == action,
              evidence.source == (source == .camera ? .cameraPose : .cachedPose) else { throw TrainingError.invalidTransition }
        try runs[i].update(evidence,revision:revision,at:now)
    }
    mutating func end(_ reason: WorkoutObservationInterruption, at now: Date) {
        if let i=runs.indices.last { runs[i].end(reason,at:now) }
    }
    public func validate() throws {
        guard schema == "fox.workout_count_only.v1", Set(runs.map(\.id)).count == runs.count else { throw TrainingError.corruptArchive }
        var end: Date?
        for (i,run) in runs.enumerated() {
            guard run.startedAt.timeIntervalSince1970.isFinite, run.updatedAt.timeIntervalSince1970.isFinite,
                  run.updatedAt >= run.startedAt, end.map({ run.startedAt >= $0 }) ?? true,
                  (run.endedAt == nil) == (run.endReason == nil),
                  run.endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= run.updatedAt }) ?? (i == runs.count-1),
                  run.coordinateConvention == "vision-normalized-bottom-left-pixel-up-v1",
                  (run.evidence == nil) == (run.appleRevision == nil) else { throw TrainingError.corruptArchive }
            if let strategyID=run.declaredStrategyID {
                guard action == .squat, strategyID == "squat-side-joint-floor-25-h1-v1" else { throw TrainingError.corruptArchive }
            }
            if let value=run.evidence {
                try value.validate()
                guard value.strategyID == run.resolvedStrategyID else { throw TrainingError.corruptArchive }
                guard value.side == side, value.action == action, value.source == (source == .camera ? .cameraPose : .cachedPose),
                      (run.appleRevision ?? 0) > 0 else { throw TrainingError.corruptArchive }
            }
            end=run.endedAt
        }
    }
}

extension TrainingSession {
    public var observedAutomaticCount: Int { currentAssistedEvidence?.automaticCount ?? currentVisualEvidence?.automaticCount ?? 0 }
    public var suggestedAutomaticCount: Int? { currentAssistedEvidence?.suggestedCount ?? currentVisualEvidence?.suggestedCount }
    public var observedSide: ArmSide? { currentAssistedEvidence?.side ?? currentVisualEvidence?.settings.arm }
}


extension CountOnlyAction {
    func isCompatible(with exercise: Exercise) -> Bool {
        self == .curl ? exercise.visualObservation?.exercise == .curl : exercise.exerciseId == "bodyweight_squat"
    }
}
