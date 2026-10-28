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
            copy.exercises[index].visualObservation = WorkoutObservationSettings(exercise: exercise, arm: item.targetSide ?? .left,
                bodyView: exercise.recommendedBodyView)
            copy.exercises[index].repetitionBasis = basis
        }
        return copy
    }

    static func trial(_ activity: TrainingActivity = .curl, arm: ArmSide = .left) -> TrainingPlan {
        var item = Exercise(id: activity.exerciseID, name: activity.label,
            sets: [SetTarget(setIndex: 1, reps: 5)], notes: "重量由你确认；不舒服时停止。")
        if activity == .kegel {
            item.targetSets[0].weightUnit = "bodyweight"
            item.repetitionBasis = .total
            item.tempo = [.init("contract", seconds: 3, visual: "expand"), .init("relax", seconds: 6, visual: "shrink")]
            item.notes = "轻轻收缩，完全放松，正常呼吸。不舒服时停止；有盆底症状或不确定是否适合时，请先咨询专业人员。"
        }
        var plan = prepared(TrainingPlan(focus: "试练一组 · \(activity.label)", exercises: [item]))
        plan.isQuickPractice = true
        plan.exercises[0].visualObservation?.arm = arm
        if plan.exercises[0].repetitionBasis == .perSide {
            // One observed side is not evidence that both sides completed the target.
            let side = arm
            plan.exercises[0].targetSide = side
            plan.exercises[0].visualObservation?.arm = side
        }
        return plan
    }
}
