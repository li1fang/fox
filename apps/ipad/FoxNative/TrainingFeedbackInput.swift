import FoxTrainingCore

enum TrainingFeedbackInput {
    static func initialDraft(session: TrainingSession, saved: TrainingFeedbackDraft?) -> TrainingFeedbackDraft {
        if let saved { return saved }
        var draft = TrainingFeedbackDraft()
        draft.weight = session.currentWeight
        if session.currentAssistedEvidence?.isSquatTrial == true { return draft }
        if let side=session.observedSide, let count=session.suggestedAutomaticCount {
            if session.exercise.repetitionBasis == .perSide {
                if side == .left { draft.leftReps = String(count) }
                else { draft.rightReps = String(count) }
            } else { draft.reps = String(count) }
        }
        return draft
    }
}
