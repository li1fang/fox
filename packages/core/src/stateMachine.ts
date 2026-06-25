import { createConservativePlan, createInitialSession } from "./fixtures.js";
import { getMainTrainingProgress } from "./progress.js";
import { applyFeedbackRules } from "./rules.js";
import { draftWorkoutSummary } from "./summary.js";
import type {
  FeedbackEvent,
  RestTimer,
  SetRecord,
  TimerEvent,
  WorkoutEvent,
  WorkoutPlan,
  WorkoutSession
} from "./types.js";

function nowIso(at?: string): string {
  return at ?? new Date().toISOString();
}

function addSeconds(iso: string, seconds: number): string {
  return new Date(new Date(iso).getTime() + seconds * 1000).toISOString();
}

function secondsBetween(start: string | undefined, end: string): number | undefined {
  if (!start) {
    return undefined;
  }
  return Math.max(0, Math.round((new Date(end).getTime() - new Date(start).getTime()) / 1000));
}

function withUpdate(session: WorkoutSession, patch: Partial<WorkoutSession>, at: string): WorkoutSession {
  return { ...session, ...patch, updatedAt: at };
}

function currentExercise(plan: WorkoutPlan, session: WorkoutSession) {
  return plan.exercises[session.currentExerciseIndex];
}

function currentTarget(plan: WorkoutPlan, session: WorkoutSession) {
  return currentExercise(plan, session).targetSets[session.currentSetIndex];
}

function nextPosition(plan: WorkoutPlan, exerciseIndex: number, setIndex: number): { exerciseIndex: number; setIndex: number } | null {
  const exercise = plan.exercises[exerciseIndex];
  if (setIndex + 1 < exercise.targetSets.length) {
    return { exerciseIndex, setIndex: setIndex + 1 };
  }
  if (exerciseIndex + 1 < plan.exercises.length) {
    return { exerciseIndex: exerciseIndex + 1, setIndex: 0 };
  }
  return null;
}

function createRestTimer(plan: WorkoutPlan, exerciseIndex: number, setIndex: number, at: string): RestTimer {
  const exercise = plan.exercises[exerciseIndex];
  const target = exercise.targetSets[setIndex];
  const durationSeconds = target.restSeconds || exercise.restSeconds;
  return {
    startedAt: at,
    endsAt: addSeconds(at, durationSeconds),
    durationSeconds,
    target: `${exercise.name} set ${target.setIndex}`
  };
}

function createTimerEvent(kind: TimerEvent["kind"], timer: RestTimer, at: string): TimerEvent {
  return {
    id: `timer_${Date.now()}`,
    at,
    kind,
    durationSeconds: timer.durationSeconds,
    target: timer.target
  };
}

function appendCompletedSet(plan: WorkoutPlan, pending: WorkoutSession["pendingSet"]): WorkoutPlan {
  if (!pending) {
    return plan;
  }
  const nextPlan = structuredClone(plan) as WorkoutPlan;
  nextPlan.exercises[pending.exerciseIndex].completedSets.push(pending.record);
  return nextPlan;
}

function terminalStatus(status: WorkoutSession["status"]): boolean {
  return status === "confirmed" || status === "cancelled" || status === "aborted";
}

export function createSession(now = new Date().toISOString()): WorkoutSession {
  return createInitialSession(now);
}

export function dispatchWorkoutEvent(session: WorkoutSession, event: WorkoutEvent): WorkoutSession {
  const at = nowIso(event.at);

  if (terminalStatus(session.status) && event.type !== "CONFIRM_SUMMARY" && event.type !== "RECORD_AI_AUDIT") {
    return session;
  }

  switch (event.type) {
    case "SUBMIT_CHECK_IN": {
      const plan = createConservativePlan(event.checkIn);
      return withUpdate(
        session,
        {
          status: "awaiting_approval",
          checkIn: event.checkIn,
          plan,
          coachMessages: [
            ...session.coachMessages,
            {
              id: `msg_${Date.now()}`,
              at,
              role: "coach",
              state: "awaiting_approval",
              text: `今日计划偏保守：${plan.focus}。先确认，再开始。`,
              source: "template"
            }
          ]
        },
        at
      );
    }
    case "LOAD_PLAN_DRAFT": {
      if (session.status !== "idle" && session.status !== "planning" && session.status !== "awaiting_approval") {
        return session;
      }
      return withUpdate(
        session,
        {
          status: "awaiting_approval",
          checkIn: event.checkIn ?? session.checkIn,
          plan: event.plan,
          currentExerciseIndex: 0,
          currentSetIndex: 0,
          activeSetStartedAt: undefined,
          pendingSet: undefined,
          restTimer: undefined,
          coachMessages: [
            ...session.coachMessages,
            {
              id: `msg_${Date.now()}`,
              at,
              role: "coach",
              state: "awaiting_approval",
              text: event.message ?? `${event.source === "ai" ? "AI" : "外部"}计划草稿已载入，请确认后开始。`,
              source: event.source === "ai" ? "ai" : "template"
            }
          ]
        },
        at
      );
    }
    case "ACCEPT_PLAN": {
      if (session.status !== "awaiting_approval" || !session.plan) {
        return session;
      }
      return withUpdate(
        session,
        { status: "active_exercise", startedAt: at, activeSetStartedAt: at, currentExerciseIndex: 0, currentSetIndex: 0 },
        at
      );
    }
    case "REJECT_PLAN":
    case "CANCEL": {
      return withUpdate(session, { status: "cancelled", endedAt: at, activeSetStartedAt: undefined }, at);
    }
    case "SET_FINISHED": {
      if (session.status !== "active_exercise" || !session.plan) {
        return session;
      }
      const target = currentTarget(session.plan, session);
      const elapsedSeconds = secondsBetween(session.activeSetStartedAt, at);
      const record: SetRecord = {
        ...event.record,
        durationSeconds: event.record.durationSeconds ?? elapsedSeconds,
        setIndex: target.setIndex,
        plannedSetIndex: target.setIndex,
        pain: event.record.pain,
        countingMethod: event.record.countingMethod
      };
      return withUpdate(
        session,
        {
          status: "feedback",
          pendingSet: {
            exerciseIndex: session.currentExerciseIndex,
            setIndex: session.currentSetIndex,
            startedAt: session.activeSetStartedAt ?? at,
            finishedAt: at,
            record
          }
        },
        at
      );
    }
    case "UPDATE_PENDING_SET": {
      if (session.status !== "feedback" || !session.pendingSet) {
        return session;
      }
      return withUpdate(
        session,
        {
          pendingSet: {
            ...session.pendingSet,
            record: {
              ...session.pendingSet.record,
              ...event.record
            }
          }
        },
        at
      );
    }
    case "SUBMIT_FEEDBACK": {
      if (session.status !== "feedback" || !session.plan || !session.pendingSet) {
        return session;
      }

      const pending = session.pendingSet;
      const exercise = session.plan.exercises[pending.exerciseIndex];
      const feedback: FeedbackEvent = {
        id: `fb_${Date.now()}`,
        at,
        state: "feedback",
        kind: event.kind,
        exerciseName: exercise.name,
        setIndex: pending.record.setIndex,
        message: event.message
      };
      const withSet = appendCompletedSet(session.plan, pending);
      const ruleResult = applyFeedbackRules({
        plan: withSet,
        feedback,
        exerciseIndex: pending.exerciseIndex,
        setIndex: pending.record.setIndex,
        at
      });
      const feedbackEvents = [...session.feedbackEvents, feedback];
      const adjustments = [...session.adjustments, ...ruleResult.adjustments];
      const coachMessages = [...session.coachMessages, ...ruleResult.coachMessages];

      if (ruleResult.shouldAbort) {
        const abortedSession = withUpdate(
          session,
          {
            status: "aborted",
            plan: ruleResult.plan,
            pendingSet: undefined,
            activeSetStartedAt: undefined,
            feedbackEvents,
            adjustments,
            coachMessages,
            endedAt: at
          },
          at
        );
        return { ...abortedSession, summary: draftWorkoutSummary(abortedSession) };
      }

      const next = nextPosition(ruleResult.plan, pending.exerciseIndex, pending.setIndex);
      if (!next) {
        const summarySession = withUpdate(
          session,
          {
            status: "summary_pending",
            plan: ruleResult.plan,
            pendingSet: undefined,
            activeSetStartedAt: undefined,
            feedbackEvents,
            adjustments,
            coachMessages,
            endedAt: at
          },
          at
        );
        return { ...summarySession, summary: draftWorkoutSummary(summarySession) };
      }

      const restTimer = createRestTimer(ruleResult.plan, next.exerciseIndex, next.setIndex, at);
      return withUpdate(
        session,
        {
          status: "rest_timer",
          plan: ruleResult.plan,
          pendingSet: undefined,
          currentExerciseIndex: next.exerciseIndex,
          currentSetIndex: next.setIndex,
          activeSetStartedAt: undefined,
          restTimer,
          feedbackEvents,
          adjustments,
          coachMessages,
          timerEvents: [...session.timerEvents, createTimerEvent("rest_timer_started", restTimer, at)]
        },
        at
      );
    }
    case "SUBMIT_TRANSITION_FEEDBACK": {
      if (session.status !== "rest_timer" || !session.plan) {
        return session;
      }
      const exercise = currentExercise(session.plan, session);
      const target = currentTarget(session.plan, session);
      const feedback: FeedbackEvent = {
        id: `fb_${Date.now()}`,
        at,
        state: "rest_timer",
        kind: event.kind,
        exerciseName: exercise.name,
        setIndex: target.setIndex,
        message: event.message
      };
      const shouldExtendRest = event.kind === "too_hard" || event.kind === "not_followed";
      const restTimer =
        shouldExtendRest && session.restTimer
          ? {
              ...session.restTimer,
              durationSeconds: session.restTimer.durationSeconds + 30,
              endsAt: addSeconds(session.restTimer.endsAt, 30)
            }
          : session.restTimer;
      const timerEvents =
        shouldExtendRest && restTimer
          ? [...session.timerEvents, createTimerEvent("timer_extended", restTimer, at)]
          : session.timerEvents;
      return withUpdate(
        session,
        {
          restTimer,
          timerEvents,
          feedbackEvents: [...session.feedbackEvents, feedback],
          coachMessages: [
            ...session.coachMessages,
            {
              id: `msg_${Date.now()}`,
              at,
              role: "coach",
              state: "rest_timer",
              text: shouldExtendRest ? "收到，休息先多加 30 秒，下一组保持动作稳。" : "已记录这条组间反馈。",
              source: "template"
            }
          ]
        },
        at
      );
    }
    case "REST_FINISHED": {
      if (session.status !== "rest_timer") {
        return session;
      }
      const timer = session.restTimer;
      return withUpdate(
        session,
        {
          status: "active_exercise",
          activeSetStartedAt: at,
          restTimer: undefined,
          timerEvents: timer ? [...session.timerEvents, createTimerEvent("rest_timer_finished", timer, at)] : session.timerEvents
        },
        at
      );
    }
    case "REST_EXTENDED": {
      if (session.status !== "rest_timer" || !session.restTimer) {
        return session;
      }
      const restTimer: RestTimer = {
        ...session.restTimer,
        durationSeconds: session.restTimer.durationSeconds + event.seconds,
        endsAt: addSeconds(session.restTimer.endsAt, event.seconds)
      };
      return withUpdate(
        session,
        {
          restTimer,
          timerEvents: [...session.timerEvents, createTimerEvent("timer_extended", restTimer, at)]
        },
        at
      );
    }
    case "EMERGENCY_STOP": {
      const abortedSession = withUpdate(
        session,
        {
          status: "aborted",
          endedAt: at,
          activeSetStartedAt: undefined,
          coachMessages: [
            ...session.coachMessages,
            {
              id: `msg_${Date.now()}`,
              at,
              role: "system",
              state: "aborted",
              text: event.message ?? "训练已因紧急停止而中止。",
              source: "system"
            }
          ]
        },
        at
      );
      return { ...abortedSession, summary: draftWorkoutSummary(abortedSession) };
    }
    case "CONFIRM_SUMMARY": {
      if (session.status !== "summary_pending" && session.status !== "aborted") {
        return session;
      }
      return withUpdate(session, { status: "confirmed", endedAt: session.endedAt ?? at }, at);
    }
    case "RECORD_AI_AUDIT": {
      return withUpdate(
        session,
        {
          aiAudits: [
            ...(session.aiAudits ?? []),
            {
              id: `audit_${Date.now()}`,
              at,
              ...event.audit
            }
          ]
        },
        at
      );
    }
    default:
      return session;
  }
}

export function getCurrentExercise(session: WorkoutSession) {
  return session.plan ? currentExercise(session.plan, session) : undefined;
}

export function getCurrentTarget(session: WorkoutSession) {
  return session.plan ? currentTarget(session.plan, session) : undefined;
}

export function getProgress(session: WorkoutSession) {
  return getMainTrainingProgress(session.plan);
}
