import type {
  EquipmentInventory,
  ExerciseBlock,
  ExerciseHistorySnapshot,
  SetTarget,
  WeightRecommendation,
  WorkoutPlan
} from "./types.js";

export function createDefaultEquipmentInventory(now = new Date().toISOString()): EquipmentInventory {
  return {
    updatedAt: now,
    notes: "待和用户确认家庭健身房器材。",
    items: [
      {
        id: "adjustable_dumbbells",
        name: "Adjustable Dumbbells",
        kind: "dumbbell",
        available: true,
        weightUnit: "kg",
        minWeight: 2.5,
        maxWeight: 20,
        increment: 2.5,
        notes: "默认占位；需要按实际器材修正。"
      },
      {
        id: "exercise_mat",
        name: "Exercise Mat",
        kind: "mat",
        available: true
      }
    ]
  };
}

function roundToIncrement(weight: number, increment: number | undefined, preferDown = false): number {
  if (!increment || increment <= 0) {
    return Number(weight.toFixed(1));
  }
  const units = preferDown ? Math.floor(weight / increment) : Math.round(weight / increment);
  return Number((units * increment).toFixed(1));
}

function clampToEquipment(weight: number, exercise: ExerciseBlock, inventory: EquipmentInventory, preferDown = false): number {
  const dumbbell = inventory.items.find((item) => item.available && item.kind === "dumbbell");
  if (!dumbbell || exercise.targetSets.every((set) => set.weightUnit !== "kg")) {
    return Number(weight.toFixed(1));
  }
  const min = dumbbell.minWeight ?? weight;
  const max = dumbbell.maxWeight ?? weight;
  return Math.min(max, Math.max(min, roundToIncrement(weight, dumbbell.increment, preferDown)));
}

function isNegativeFeedback(kind: string): boolean {
  return kind === "pain" || kind === "not_followed" || kind === "too_hard" || kind === "skip";
}

export function recommendWeightForExercise(params: {
  exercise: ExerciseBlock;
  history: ExerciseHistorySnapshot[];
  inventory: EquipmentInventory;
}): WeightRecommendation {
  const { exercise, history, inventory } = params;
  const matching = history
    .filter((item) => item.exerciseId === exercise.exerciseId || item.exerciseName.toLowerCase() === exercise.name.toLowerCase())
    .sort((a, b) => new Date(b.occurredAt).getTime() - new Date(a.occurredAt).getTime());
  const latest = matching[0];
  const templateTarget = exercise.targetSets.find((target) => target.targetWeight !== undefined);

  if (!latest) {
    return {
      exerciseId: exercise.exerciseId,
      exerciseName: exercise.name,
      weight: templateTarget?.targetWeight,
      weightUnit: templateTarget?.weightUnit,
      reps: templateTarget?.targetReps,
      confidence: "low",
      source: "template",
      rationale: "没有同动作历史，先使用模板重量。"
    };
  }

  const lastWeightedSet = [...latest.sets].reverse().find((set) => set.weight !== undefined);
  const lastRepSet = [...latest.sets].reverse().find((set) => set.reps !== undefined);
  const hadNegativeFeedback = latest.feedbackKinds.some(isNegativeFeedback);
  const baseWeight = lastWeightedSet?.weight ?? templateTarget?.targetWeight;
  const suggested =
    baseWeight === undefined ? undefined : clampToEquipment(hadNegativeFeedback ? baseWeight * 0.9 : baseWeight, exercise, inventory, hadNegativeFeedback);

  return {
    exerciseId: exercise.exerciseId,
    exerciseName: exercise.name,
    weight: suggested,
    weightUnit: lastWeightedSet?.weightUnit ?? templateTarget?.weightUnit,
    reps: hadNegativeFeedback ? Math.max(1, Math.floor((lastRepSet?.reps ?? templateTarget?.targetReps ?? 8) * 0.9)) : lastRepSet?.reps ?? templateTarget?.targetReps,
    confidence: matching.length >= 3 ? "high" : "medium",
    source: "history",
    rationale: hadNegativeFeedback ? "最近同动作有风险反馈，推荐略微保守。" : "根据最近同动作完成情况推荐。"
  };
}

function applyRecommendationToTarget(target: SetTarget, recommendation: WeightRecommendation): SetTarget {
  return {
    ...target,
    targetReps: recommendation.reps ?? target.targetReps,
    targetWeight: recommendation.weight ?? target.targetWeight,
    weightUnit: recommendation.weightUnit ?? target.weightUnit,
    intensityNote: recommendation.rationale
  };
}

export function applyWeightRecommendations(
  plan: WorkoutPlan,
  recommendations: WeightRecommendation[]
): WorkoutPlan {
  const recommendationByExercise = new Map(recommendations.map((recommendation) => [recommendation.exerciseId, recommendation]));
  return {
    ...plan,
    exercises: plan.exercises.map((exercise) => {
      const recommendation = recommendationByExercise.get(exercise.exerciseId);
      if (!recommendation) {
        return exercise;
      }
      return {
        ...exercise,
        targetSets: exercise.targetSets.map((target) => applyRecommendationToTarget(target, recommendation))
      };
    })
  };
}
