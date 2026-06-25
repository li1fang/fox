import type { Adjustment, CoachMessage, FeedbackEvent, SetTarget, WorkoutPlan } from "./types.js";

function clonePlan(plan: WorkoutPlan): WorkoutPlan {
  return structuredClone(plan) as WorkoutPlan;
}

function reduceTarget(target: SetTarget): SetTarget {
  return {
    ...target,
    targetReps: target.targetReps === undefined ? undefined : Math.max(1, Math.floor(target.targetReps * 0.8)),
    targetDurationSeconds:
      target.targetDurationSeconds === undefined ? undefined : Math.max(10, Math.floor(target.targetDurationSeconds * 0.85)),
    targetWeight: target.targetWeight === undefined ? undefined : Math.max(0, Number((target.targetWeight * 0.9).toFixed(1))),
    restSeconds: target.restSeconds + 30,
    intensityNote: "Reduced after feedback."
  };
}

function increaseTargetGently(target: SetTarget): SetTarget {
  return {
    ...target,
    targetReps: target.targetReps === undefined ? undefined : target.targetReps + 1,
    targetDurationSeconds: target.targetDurationSeconds === undefined ? undefined : target.targetDurationSeconds + 5,
    intensityNote: "Small increase after easy feedback."
  };
}

function coachMessage(at: string, text: string): CoachMessage {
  return {
    id: `msg_${Date.now()}`,
    at,
    role: "coach",
    state: "adapting",
    text,
    source: "template"
  };
}

export function applyFeedbackRules(params: {
  plan: WorkoutPlan;
  feedback: FeedbackEvent;
  exerciseIndex: number;
  setIndex: number;
  at: string;
}): { plan: WorkoutPlan; adjustments: Adjustment[]; coachMessages: CoachMessage[]; shouldAbort: boolean } {
  const { feedback, exerciseIndex, setIndex, at } = params;
  const plan = clonePlan(params.plan);
  const exercise = plan.exercises[exerciseIndex];
  const futureTargets = exercise.targetSets.filter((target) => target.setIndex > setIndex);

  if (feedback.kind === "pain") {
    return {
      plan,
      shouldAbort: true,
      coachMessages: [coachMessage(at, "疼痛优先。本次训练先停下来，下次计划会更保守。")],
      adjustments: [
        {
          id: `adj_${Date.now()}`,
          at,
          reason: "pain",
          decidedBy: "rules",
          target: exercise.name,
          before: { status: "continue" },
          after: { status: "stop_current_movement" }
        }
      ]
    };
  }

  if (futureTargets.length === 0) {
    if (feedback.kind === "not_followed" || feedback.kind === "too_hard" || feedback.kind === "too_easy") {
      return {
        plan,
        adjustments: [],
        coachMessages: [coachMessage(at, "这个动作已经到最后一组，我只记录这次反馈，不改已经结束的计划。")],
        shouldAbort: false
      };
    }
    return { plan, adjustments: [], coachMessages: [], shouldAbort: false };
  }

  if (feedback.kind === "not_followed" || feedback.kind === "too_hard") {
    const before = futureTargets.map((target) => ({ ...target }));
    exercise.targetSets = exercise.targetSets.map((target) => (target.setIndex > setIndex ? reduceTarget(target) : target));
    const after = exercise.targetSets.filter((target) => target.setIndex > setIndex);
    return {
      plan,
      shouldAbort: false,
      coachMessages: [coachMessage(at, "后续同动作先降一点强度，并多休息 30 秒。目标是动作稳定，不追错过的次数。")],
      adjustments: [
        {
          id: `adj_${Date.now()}`,
          at,
          reason: feedback.kind,
          decidedBy: "rules",
          target: exercise.name,
          before: { targetSets: before },
          after: { targetSets: after }
        }
      ]
    };
  }

  if (feedback.kind === "too_easy") {
    const [nextTarget] = futureTargets;
    const before: Record<string, unknown> = { ...nextTarget };
    exercise.targetSets = exercise.targetSets.map((target) =>
      target.setIndex === nextTarget.setIndex ? increaseTargetGently(target) : target
    );
    const after = exercise.targetSets.find((target) => target.setIndex === nextTarget.setIndex);
    return {
      plan,
      shouldAbort: false,
      coachMessages: [coachMessage(at, "下一组只小幅增加一点。今天先保持稳，不做激进加码。")],
      adjustments: [
        {
          id: `adj_${Date.now()}`,
          at,
          reason: "too_easy",
          decidedBy: "rules",
          target: `${exercise.name} set ${nextTarget.setIndex}`,
          before,
          after: after ? { ...after } : {}
        }
      ]
    };
  }

  return { plan, adjustments: [], coachMessages: [], shouldAbort: false };
}
