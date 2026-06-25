import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { afterEach, describe, expect, it } from "vitest";
import { getCurrentTarget } from "@fox/core";
import type { DailyCheckIn, SetRecord, WorkoutSession } from "@fox/core";
import { createWorkoutRepository, type WorkoutRepository } from "../src/repository";

const checkIn: DailyCheckIn = {
  sleep: "ok",
  fatigue: "medium",
  hunger: "not_hungry",
  stress: "low",
  painAreas: [],
  availableMinutes: 20
};

const tempDirs: string[] = [];

function createTempRepository(): { dir: string; repository: WorkoutRepository } {
  const dir = mkdtempSync(join(tmpdir(), "fox-api-test-"));
  tempDirs.push(dir);
  return { dir, repository: createWorkoutRepository(join(dir, "fox.sqlite")) };
}

function defaultRecord(session: WorkoutSession): Omit<SetRecord, "setIndex" | "plannedSetIndex"> {
  const target = getCurrentTarget(session);
  return {
    status: "completed",
    reps: target?.targetReps,
    durationSeconds: target?.targetDurationSeconds,
    weight: target?.targetWeight,
    weightUnit: target?.weightUnit,
    pain: false,
    countingMethod: target?.targetDurationSeconds ? "timer" : "manual"
  };
}

afterEach(() => {
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("workout repository", () => {
  it("persists workout events, restores current session, and creates a confirmed entry", () => {
    const { dir, repository } = createTempRepository();
    const initial = repository.createFreshSession("2026-06-26T00:00:00.000Z");
    expect(initial.status).toBe("idle");

    let session = repository.applyEventToCurrentSession({ type: "SUBMIT_CHECK_IN", checkIn });
    session = repository.applyEventToCurrentSession({ type: "ACCEPT_PLAN" });

    while (session.status !== "summary_pending") {
      if (session.status === "active_exercise") {
        session = repository.applyEventToCurrentSession({ type: "SET_FINISHED", record: defaultRecord(session) });
      } else if (session.status === "feedback") {
        session = repository.applyEventToCurrentSession({ type: "SUBMIT_FEEDBACK", kind: "completed", message: "正常完成" });
      } else if (session.status === "rest_timer") {
        session = repository.applyEventToCurrentSession({ type: "REST_FINISHED" });
      } else {
        throw new Error(`Unexpected status ${session.status}`);
      }
    }

    session = repository.applyEventToCurrentSession({ type: "CONFIRM_SUMMARY" });
    expect(session.status).toBe("confirmed");
    expect(session.entryId).toMatch(/^entry_/);
    expect(repository.listEntries()).toHaveLength(1);
    expect(repository.listEvents(session.id).length).toBeGreaterThan(4);
    repository.close();

    const restored = createWorkoutRepository(join(dir, "fox.sqlite"));
    expect(restored.getCurrentSession()?.status).toBe("confirmed");
    expect(restored.listEntries()[0]?.payload.summary).toContain("今日训练完成");
    restored.close();
  });
});
