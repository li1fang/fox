import { describe, expect, it } from "vitest";
import {
  createSession,
  dispatchWorkoutEvent,
  draftAdjustmentSuggestionWithFallback,
  draftFeedbackOptionsWithFallback,
  getCurrentTarget,
  type AiProvider,
  type DailyCheckIn,
  type SetRecord,
  type WorkoutSession
} from "../src";

const checkIn: DailyCheckIn = {
  sleep: "ok",
  fatigue: "medium",
  hunger: "not_hungry",
  stress: "low",
  painAreas: [],
  availableMinutes: 45
};

function finishSet(session: WorkoutSession): Omit<SetRecord, "setIndex" | "plannedSetIndex"> {
  const target = getCurrentTarget(session);
  return {
    status: "partial",
    reps: target?.targetReps ? target.targetReps - 2 : undefined,
    durationSeconds: target?.targetDurationSeconds,
    weight: target?.targetWeight,
    weightUnit: target?.weightUnit,
    pain: false,
    countingMethod: target?.targetDurationSeconds ? "timer" : "manual"
  };
}

function sessionAfterFeedback(): WorkoutSession {
  let session = createSession("2026-06-26T10:00:00.000Z");
  session = dispatchWorkoutEvent(session, { type: "SUBMIT_CHECK_IN", checkIn, at: "2026-06-26T10:01:00.000Z" });
  session = dispatchWorkoutEvent(session, { type: "ACCEPT_PLAN", at: "2026-06-26T10:02:00.000Z" });
  session = dispatchWorkoutEvent(session, {
    type: "SET_FINISHED",
    record: finishSet(session),
    at: "2026-06-26T10:03:00.000Z"
  });
  return dispatchWorkoutEvent(session, { type: "SUBMIT_FEEDBACK", kind: "not_followed", at: "2026-06-26T10:04:00.000Z" });
}

describe("AI suggestion boundary", () => {
  it("falls back when feedback option output is not valid schema", async () => {
    const provider: AiProvider = {
      name: "bad-provider",
      draftPlan: () => ({ nope: true }),
      draftFeedbackOptions: () => ({ nope: true }),
      draftAdjustmentSuggestion: () => ({ nope: true })
    };

    const result = await draftFeedbackOptionsWithFallback(provider, sessionAfterFeedback());

    expect(result.audit.status).toBe("fallback_used");
    expect(result.audit.validationErrors.length).toBeGreaterThan(0);
    expect(result.value.length).toBeGreaterThan(0);
  });

  it("rejects aggressive adjustment suggestions and falls back to the rule result", async () => {
    const provider: AiProvider = {
      name: "reckless-provider",
      draftPlan: () => ({ nope: true }),
      draftFeedbackOptions: () => [],
      draftAdjustmentSuggestion: () => ({
        kind: "adjustment_suggestion",
        reason: "not_followed",
        target: { exerciseName: "Dumbbell Shoulder Press", setIndex: 2 },
        suggestedChange: { reps: 99, weight: 99, restSeconds: 10 },
        coachMessage: "Go much harder."
      })
    };

    const result = await draftAdjustmentSuggestionWithFallback(provider, sessionAfterFeedback());

    expect(result.audit.status).toBe("fallback_used");
    expect(result.audit.validationErrors).toContain("reps increase is too aggressive");
    expect(result.value.suggestedChange.reps).toBe(8);
    expect(result.value.coachMessage).toContain("降一点强度");
  });
});
