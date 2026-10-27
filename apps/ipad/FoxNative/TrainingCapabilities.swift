import FoxTrainingCore

// Compatibility is explicit and applies only to new sessions. Never infer TRX or a new
// movement from its display name, or retrofit visual facts into a saved session.
enum TrainingCapabilities {
    static func prepared(_ plan: TrainingPlan) -> TrainingPlan {
        var copy = plan
        for index in copy.exercises.indices {
            let item = copy.exercises[index]
            guard item.visualObservation == nil, item.targetSets.allSatisfy({ $0.targetReps != nil }) else { continue }
            let exercise: VisionExercise
            switch item.exerciseId {
            case "dumbbell_curl": exercise = .curl
            case "lateral_raise": exercise = .lateralRaise
            case "lat_pulldown": exercise = .latPulldown
            default: continue
            }
            let basis: RepetitionBasis = exercise == .latPulldown ? .total : .perSide
            guard item.repetitionBasis == nil || item.repetitionBasis == basis else { continue }
            copy.exercises[index].visualObservation = WorkoutObservationSettings(exercise: exercise, arm: .left,
                bodyView: exercise.recommendedBodyView)
            copy.exercises[index].repetitionBasis = basis
        }
        return copy
    }

    static func trial(_ exercise: VisionExercise = .curl) -> TrainingPlan {
        let id = exercise == .curl ? "dumbbell_curl" : exercise == .lateralRaise ? "lateral_raise" : "lat_pulldown"
        let name = exercise.label
        return prepared(TrainingPlan(focus: "试练一组 · \(name)", exercises: [
            Exercise(id: id, name: name, sets: [SetTarget(setIndex: 1, reps: 5)], notes: "重量由你确认；不舒服时停止。")
        ]))
    }
}
