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
  it("keeps the home equipment profile readable for AI planning", () => {
    const inventory = createDefaultEquipmentInventory("2026-06-28T00:00:00.000Z");
    const multiPress = inventory.items.find((item) => item.id === "multi_press_machine");
    const latPulldown = inventory.items.find((item) => item.id === "lat_pulldown_machine");

    expect(inventory.notes).toContain("两台主要固定器械");
    expect(multiPress?.functions?.map((fn) => fn.nameCn)).toEqual(["坐姿胸推", "上斜推举", "坐姿肩推"]);
    expect(multiPress?.adjustments?.backPadPositions).toBe(5);
    expect(latPulldown?.constraints).toContain("仅支持垂直下拉。");
    expect(latPulldown?.constraints).toContain("不支持标准水平划船。");
    expect(inventory.items.some((item) => item.id === "swimming" && item.available)).toBe(true);
    expect(inventory.items.some((item) => item.id === "push_up_bodyweight" && item.available)).toBe(true);
  });

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
