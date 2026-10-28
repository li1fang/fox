import Foundation

public enum TrainingExecutionStart: String, Codable { case notStarted, started, unknown }

public struct TrainingFeedbackDraft: Codable, Equatable {
    public var reps = "", leftReps = "", rightReps = "", note = "", information = "", softwareIssue = ""
    public var weight: Double?
    public var selected: Set<SetFeedback> = []
    public init() {}
}

public struct TrainingClientState: Codable, Equatable {
    public var manual = false
    public var summary = ""
    public var nextActivity: String?
    public var selectedArms: [String: ArmSide] = [:]
    public var feedback: [String: TrainingFeedbackDraft] = [:]
    public init() {}
}

public struct TrainingExecutionToken: Hashable {
    public let sessionID: UUID
    public let attemptID: UUID?
    public let generation: UUID
    public init(sessionID: UUID, attemptID: UUID?, generation: UUID) {
        self.sessionID = sessionID; self.attemptID = attemptID; self.generation = generation
    }
}

public struct TrainingSessionCommand: Codable, Equatable {
    public enum Target: Codable, Equatable { case existing(UUID), new(TrainingPlan) }
    public let id: UUID
    public let target: Target
    public init(id: UUID = UUID(), target: Target) { self.id = id; self.target = target }
}

public struct TrainingSessionReceipt: Codable, Equatable {
    public let command: TrainingSessionCommand
    public let sessionID: UUID
}

extension TrainingSession {
    public var executionStart: TrainingExecutionStart {
        if evidencedExecutionStart != nil { return .started }
        return executionStartKnown == true ? .notStarted : .unknown
    }
    // Legacy creation/skip timestamps and preparation frames are not execution evidence.
    public var evidencedExecutionStart: Date? {
        ([actualStartedAt, setStartedAt].compactMap { $0 }
         + records.filter { $0.status != "skipped" }.compactMap(\.startedAt)
         + (currentVisualEvidence?.segments.compactMap(\.startedAt) ?? [])
         + records.flatMap { $0.visualEvidence?.segments.compactMap(\.startedAt) ?? [] }).min()
    }
    public var entryTitle: String {
        if stage == .feedback || stage == .summary { return "核对训练记录" }
        switch executionStart {
        case .notStarted: return "打开训练准备"
        case .started: return "继续训练"
        case .unknown: return "打开未结束记录"
        }
    }
}

// Constructed only by the repository; the source revision and original facts are immutable.
public struct TrainingSwitchSnapshot {
    public var session: TrainingSession
    let original: TrainingSession
    let revision: Int
}
