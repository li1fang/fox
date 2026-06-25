import { describe, expect, it } from "vitest";
import { createConservativePlan, createSession, dispatchWorkoutEvent, getCurrentTarget, getProgress } from "../src";
import type { DailyCheckIn, SetRecord, WorkoutSession } from "../src";

const checkIn: DailyCheckIn = {
  sleep: "ok",
  fatigue: "medium",
  hunger: "not_hungry",
  stress: "low",
  painAreas: [],
  availableMinutes: 45
};

function startSession(): WorkoutSession {
  let session = createSession("2026-06-26T10:00:00.000Z");
  session = dispatchWorkoutEvent(session, { type: "SUBMIT_CHECK_IN", checkIn, at: "2026-06-26T10:01:00.000Z" });
  session = dispatchWorkoutEvent(session, { type: "ACCEPT_PLAN", at: "2026-06-26T10:02:00.000Z" });
  return session;
}

function finishSet(overrides: Partial<Omit<SetRecord, "setIndex" | "plannedSetIndex">> = {}) {
  return {
    status: "completed" as const,
    reps: 10,
    weight: 7.5,
    weightUnit: "kg" as const,
    pain: false,
    countingMethod: "manual" as const,
    ...overrides
  };
}

describe("workout state machine", () => {
  it("walks through a complete fixed workout and confirms the summary", () => {
    let session = startSession();
    expect(session.status).toBe("active_exercise");

    while (session.status === "active_exercise" || session.status === "rest_timer" || session.status === "feedback") {
      if (session.status === "active_exercise") {
        session = dispatchWorkoutEvent(session, { type: "SET_FINISHED", record: finishSet(), at: "2026-06-26T10:03:00.000Z" });
      }
      if (session.status === "feedback") {
        session = dispatchWorkoutEvent(session, { type: "SUBMIT_FEEDBACK", kind: "completed", at: "2026-06-26T10:04:00.000Z" });
      }
      if (session.status === "rest_timer") {
        session = dispatchWorkoutEvent(session, { type: "REST_FINISHED", at: "2026-06-26T10:05:00.000Z" });
      }
    }

    expect(session.status).toBe("summary_pending");
    expect(session.summary).toContain("今日训练完成");
    expect(getProgress(session).completedMainSets).toBe(getProgress(session).totalMainSets);

    session = dispatchWorkoutEvent(session, { type: "CONFIRM_SUMMARY", at: "2026-06-26T10:30:00.000Z" });
    expect(session.status).toBe("confirmed");
  });

  it("reduces future targets when the user does not keep up early", () => {
    let session = startSession();
    const firstTarget = getCurrentTarget(session);
    expect(firstTarget?.targetReps).toBe(10);

    session = dispatchWorkoutEvent(session, {
      type: "SET_FINISHED",
      record: finishSet({ status: "partial", reps: 6, notes: "Could not keep pace." }),
      at: "2026-06-26T10:03:00.000Z"
    });
    session = dispatchWorkoutEvent(session, {
      type: "SUBMIT_FEEDBACK",
      kind: "not_followed",
      message: "Only reached 6 reps.",
      at: "2026-06-26T10:04:00.000Z"
    });

    expect(session.adjustments).toHaveLength(1);
    expect(session.status).toBe("rest_timer");
    expect(session.plan?.exercises[0].targetSets[1].targetReps).toBe(8);
    expect(session.plan?.exercises[0].targetSets[1].restSeconds).toBe(120);
    expect(session.coachMessages.at(-1)?.text).toContain("降一点强度");
  });

  it("records actual set duration from active set timestamps when the UI does not supply it", () => {
    let session = startSession();
    session = dispatchWorkoutEvent(session, {
      type: "SET_FINISHED",
      record: finishSet({ durationSeconds: undefined }),
      at: "2026-06-26T10:03:10.000Z"
    });

    expect(session.status).toBe("feedback");
    expect(session.pendingSet?.startedAt).toBe("2026-06-26T10:02:00.000Z");
    expect(session.pendingSet?.finishedAt).toBe("2026-06-26T10:03:10.000Z");
    expect(session.pendingSet?.record.durationSeconds).toBe(70);
  });

  it("can load an external plan draft for human confirmation", () => {
    let session = createSession("2026-06-26T10:00:00.000Z");
    const plan = { ...createConservativePlan(checkIn), focus: "AI drafted home gym plan" };

    session = dispatchWorkoutEvent(session, {
      type: "LOAD_PLAN_DRAFT",
      plan,
      checkIn,
      source: "ai",
      message: "我根据历史和器材草拟了计划，请确认。",
      at: "2026-06-26T10:01:00.000Z"
    });

    expect(session.status).toBe("awaiting_approval");
    expect(session.plan?.focus).toBe("AI drafted home gym plan");
    expect(session.coachMessages.at(-1)?.source).toBe("ai");
  });

  it("records fatigue without changing a finished exercise when the last set is missed", () => {
    let session = startSession();
    session = dispatchWorkoutEvent(session, {
      type: "SET_FINISHED",
      record: finishSet(),
      at: "2026-06-26T10:03:00.000Z"
    });
    session = dispatchWorkoutEvent(session, { type: "SUBMIT_FEEDBACK", kind: "completed", at: "2026-06-26T10:04:00.000Z" });
    session = dispatchWorkoutEvent(session, { type: "REST_FINISHED", at: "2026-06-26T10:05:00.000Z" });
    session = dispatchWorkoutEvent(session, {
      type: "SET_FINISHED",
      record: finishSet({ status: "partial", reps: 5 }),
      at: "2026-06-26T10:06:00.000Z"
    });
    session = dispatchWorkoutEvent(session, { type: "SUBMIT_FEEDBACK", kind: "not_followed", at: "2026-06-26T10:07:00.000Z" });

    expect(session.adjustments).toHaveLength(0);
    expect(session.status).toBe("rest_timer");
    expect(session.currentExerciseIndex).toBe(1);
    expect(session.coachMessages.at(-1)?.text).toContain("不改已经结束的计划");
  });

  it("records transition feedback and extends rest when the user has not recovered", () => {
    let session = startSession();
    session = dispatchWorkoutEvent(session, {
      type: "SET_FINISHED",
      record: finishSet(),
      at: "2026-06-26T10:03:00.000Z"
    });
    session = dispatchWorkoutEvent(session, { type: "SUBMIT_FEEDBACK", kind: "completed", at: "2026-06-26T10:04:00.000Z" });
    const originalRest = session.restTimer?.durationSeconds;

    session = dispatchWorkoutEvent(session, {
      type: "SUBMIT_TRANSITION_FEEDBACK",
      kind: "not_followed",
      message: "还没恢复",
      at: "2026-06-26T10:04:20.000Z"
    });

    expect(session.status).toBe("rest_timer");
    expect(session.feedbackEvents.at(-1)?.state).toBe("rest_timer");
    expect(session.restTimer?.durationSeconds).toBe((originalRest ?? 0) + 30);
  });

  it("only increases the next target gently when the user says it is too easy", () => {
    let session = startSession();
    session = dispatchWorkoutEvent(session, {
      type: "SET_FINISHED",
      record: finishSet({ reps: 12 }),
      at: "2026-06-26T10:03:00.000Z"
    });
    session = dispatchWorkoutEvent(session, { type: "SUBMIT_FEEDBACK", kind: "too_easy", at: "2026-06-26T10:04:00.000Z" });

    expect(session.adjustments).toHaveLength(1);
    expect(session.plan?.exercises[0].targetSets[1].targetReps).toBe(11);
    expect(session.plan?.exercises[0].targetSets[1].targetWeight).toBe(7.5);
    expect(session.coachMessages.at(-1)?.text).toContain("小幅增加");
  });

  it("creates a conservative plan when the check-in is poor", () => {
    let session = createSession("2026-06-26T10:00:00.000Z");
    session = dispatchWorkoutEvent(session, {
      type: "SUBMIT_CHECK_IN",
      checkIn: { ...checkIn, sleep: "poor", fatigue: "high" },
      at: "2026-06-26T10:01:00.000Z"
    });

    expect(session.plan?.exercises[0].targetSets[0].targetReps).toBe(8);
    expect(session.plan?.exercises[0].targetSets[0].restSeconds).toBe(120);
  });

  it("aborts on pain feedback", () => {
    let session = startSession();
    session = dispatchWorkoutEvent(session, {
      type: "SET_FINISHED",
      record: finishSet({ status: "failed", reps: 2, pain: true, notes: "Shoulder pain." }),
      at: "2026-06-26T10:03:00.000Z"
    });
    session = dispatchWorkoutEvent(session, {
      type: "SUBMIT_FEEDBACK",
      kind: "pain",
      message: "Sharp shoulder pain.",
      at: "2026-06-26T10:04:00.000Z"
    });

    expect(session.status).toBe("aborted");
    expect(session.adjustments[0]?.reason).toBe("pain");
    expect(session.coachMessages.at(-1)?.text).toContain("疼痛优先");
    expect(session.summary).toContain("提前中止");
  });

  it("does not advance a confirmed session", () => {
    let session = startSession();
    session = { ...session, status: "confirmed" };
    const result = dispatchWorkoutEvent(session, {
      type: "SET_FINISHED",
      record: finishSet(),
      at: "2026-06-26T10:03:00.000Z"
    });

    expect(result).toBe(session);
    expect(result.status).toBe("confirmed");
  });
});
