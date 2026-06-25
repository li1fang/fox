import { describe, expect, it } from "vitest";
import { createConservativePlan, createDefaultEquipmentInventory, recommendWeightForExercise } from "../src";
import type { DailyCheckIn, ExerciseHistorySnapshot } from "../src";

const checkIn: DailyCheckIn = {
  sleep: "ok",
  fatigue: "medium",
  hunger: "not_hungry",
  stress: "low",
  painAreas: [],
  availableMinutes: 40
};

describe("planning helpers", () => {
  it("recommends a conservative weight when recent history had negative feedback", () => {
    const plan = createConservativePlan(checkIn);
    const exercise = plan.exercises[0];
    const history: ExerciseHistorySnapshot[] = [
      {
        exerciseId: exercise.exerciseId,
        exerciseName: exercise.name,
        occurredAt: "2026-06-20T10:00:00.000Z",
        feedbackKinds: ["too_hard"],
        sets: [
          {
            setIndex: 1,
            plannedSetIndex: 1,
            status: "partial",
            reps: 8,
            weight: 10,
            weightUnit: "kg",
            pain: false,
            countingMethod: "manual"
          }
        ]
      }
    ];

    const recommendation = recommendWeightForExercise({
      exercise,
      history,
      inventory: createDefaultEquipmentInventory()
    });

    expect(recommendation.source).toBe("history");
    expect(recommendation.weight).toBeLessThan(10);
    expect(recommendation.rationale).toContain("保守");
  });
});
