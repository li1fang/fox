import type { SetTarget, TempoPhase } from "./types.js";

const fallbackRepSeconds = 4;

export function estimateSetTimerSeconds(target: SetTarget | undefined, tempo: TempoPhase[] = []): number | undefined {
  if (!target) {
    return undefined;
  }
  if (typeof target.targetDurationSeconds === "number") {
    return Math.max(1, Math.round(target.targetDurationSeconds));
  }
  if (typeof target.targetReps !== "number") {
    return undefined;
  }
  const tempoSeconds = tempo.reduce((total, phase) => total + phase.seconds, 0) || fallbackRepSeconds;
  return Math.max(1, Math.round(target.targetReps * tempoSeconds));
}
