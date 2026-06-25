import type { ProgressSnapshot, WorkoutPlan } from "./types.js";

export function getMainTrainingProgress(plan: WorkoutPlan | undefined): ProgressSnapshot {
  if (!plan) {
    return { completedMainSets: 0, handledMainSets: 0, totalMainSets: 0, percentComplete: 0 };
  }

  const mainExercises = plan.exercises.filter((exercise) => exercise.category !== "mobility");
  const totalMainSets = mainExercises.reduce((total, exercise) => total + exercise.targetSets.length, 0);
  const completedMainSets = mainExercises.reduce(
    (total, exercise) => total + exercise.completedSets.filter((set) => set.status === "completed").length,
    0
  );
  const handledMainSets = mainExercises.reduce((total, exercise) => total + exercise.completedSets.length, 0);

  return {
    completedMainSets,
    handledMainSets,
    totalMainSets,
    percentComplete: totalMainSets === 0 ? 0 : Math.round((completedMainSets / totalMainSets) * 100)
  };
}
