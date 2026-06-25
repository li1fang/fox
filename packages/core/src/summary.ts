import { getMainTrainingProgress } from "./progress.js";
import type { WorkoutSession } from "./types.js";

export function draftWorkoutSummary(session: WorkoutSession): string {
  const progress = getMainTrainingProgress(session.plan);
  const feedbackSummary = session.feedbackEvents
    .filter((event) => event.kind !== "completed")
    .map((event) => `${event.exerciseName} 第 ${event.setIndex} 组：${event.kind}${event.message ? `，${event.message}` : ""}`);

  const lines = [
    `今日训练完成 ${progress.completedMainSets}/${progress.totalMainSets} 个主训练组。`,
    `已处理 ${progress.handledMainSets} 个主训练组，拉伸不计入进度。`
  ];

  if (session.adjustments.length > 0) {
    lines.push(`训练中进行了 ${session.adjustments.length} 次强度调整。`);
  }

  if (feedbackSummary.length > 0) {
    lines.push(`需要注意：${feedbackSummary.join("；")}。`);
  }

  if (session.status === "aborted") {
    lines.push("本次训练提前中止，下次计划应更保守。");
  }

  return lines.join("\n");
}
