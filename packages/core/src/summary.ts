import { getMainTrainingProgress } from "./progress.js";
import { estimateSetTimerSeconds } from "./timing.js";
import type { FeedbackEvent, SetRecord, WorkoutSession } from "./types.js";

function feedbackKinds(event: FeedbackEvent): string {
  return (event.kinds?.length ? event.kinds : [event.kind]).join("/");
}

function feedbackMessages(event: FeedbackEvent): string[] {
  return event.messages?.length ? event.messages : event.message ? [event.message] : [];
}

function setLabel(set: SetRecord): string {
  if (typeof set.reps === "number" && typeof set.weight === "number") {
    return `${set.reps} 次 x ${set.weight}${set.weightUnit === "kg" ? "kg" : ""}`;
  }
  if (typeof set.reps === "number") {
    return `${set.reps} 次`;
  }
  if (typeof set.durationSeconds === "number") {
    return `${set.durationSeconds} 秒`;
  }
  return set.status;
}

export function draftWorkoutSummary(session: WorkoutSession): string {
  const progress = getMainTrainingProgress(session.plan);
  const painAreas = session.checkIn?.painAreas.filter((area) => area.trim()) ?? [];
  const exerciseSummary =
    session.plan?.exercises
      .filter((exercise) => exercise.category !== "mobility")
      .map((exercise) => {
        const completed = exercise.completedSets.length;
        const total = exercise.targetSets.length;
        const details = exercise.completedSets.map((set) => `第 ${set.setIndex} 组 ${set.status} ${setLabel(set)}`).join("；");
        return `${exercise.name}: ${completed}/${total}${details ? `（${details}）` : ""}`;
      }) ?? [];
  const timingNotes =
    session.plan?.exercises.flatMap((exercise) =>
      exercise.completedSets.flatMap((set) => {
        const target = exercise.targetSets.find((candidate) => candidate.setIndex === set.plannedSetIndex);
        const expected = estimateSetTimerSeconds(target, exercise.tempo);
        if (!expected || typeof set.durationSeconds !== "number") {
          return [];
        }
        if (expected >= 5 && set.durationSeconds > expected * 2) {
          return [`${exercise.name} 第 ${set.setIndex} 组记录时长 ${set.durationSeconds} 秒，明显长于计划 ${expected} 秒`];
        }
        if (expected >= 5 && set.durationSeconds < Math.round(expected * 0.4)) {
          return [`${exercise.name} 第 ${set.setIndex} 组记录时长 ${set.durationSeconds} 秒，明显短于计划 ${expected} 秒`];
        }
        return [];
      })
    ) ?? [];
  const feedbackSummary = session.feedbackEvents
    .filter((event) => event.kind !== "completed" || feedbackMessages(event).length > 0)
    .map((event) => {
      const messages = feedbackMessages(event);
      return `${event.exerciseName} 第 ${event.setIndex} 组：${feedbackKinds(event)}${messages.length ? `，${messages.join("；")}` : ""}`;
    });

  const lines = [
    `今日训练完成 ${progress.completedMainSets}/${progress.totalMainSets} 个主训练组。`,
    `已处理 ${progress.handledMainSets} 个主训练组，拉伸不计入进度。`
  ];

  if (session.plan?.focus) {
    lines.push(`训练主题：${session.plan.focus}。`);
  }

  if (painAreas.length > 0) {
    lines.push(`开始前注意：${painAreas.join("、")}。`);
  }

  if (exerciseSummary.length > 0) {
    lines.push(`完成明细：${exerciseSummary.join("；")}。`);
  }

  if (session.adjustments.length > 0) {
    lines.push(`训练中进行了 ${session.adjustments.length} 次强度调整。`);
  }

  if (timingNotes.length > 0) {
    lines.push(`计时异常：${timingNotes.join("；")}。`);
  }

  if (feedbackSummary.length > 0) {
    lines.push(`反馈与备注：${feedbackSummary.join("；")}。`);
  }

  if (session.status === "aborted") {
    lines.push("本次训练提前中止，下次计划应更保守。");
  }

  return lines.join("\n");
}
