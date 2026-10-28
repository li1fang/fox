import FoxTrainingCore

enum TrainingFeedbackInput {
    static func initialDraft(session: TrainingSession, saved: TrainingFeedbackDraft?) -> TrainingFeedbackDraft {
        if let saved { return saved }
        var draft = TrainingFeedbackDraft()
        draft.weight = session.currentWeight
        if let evidence = session.currentVisualEvidence, let count = evidence.suggestedCount {
            if session.exercise.repetitionBasis == .perSide {
                if evidence.settings.arm == .left { draft.leftReps = String(count) }
                else { draft.rightReps = String(count) }
            } else { draft.reps = String(count) }
        }
        return draft
    }
}
