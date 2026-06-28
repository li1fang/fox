import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import type { AddressInfo } from "node:net";
import type { Server } from "node:http";
import { afterEach, describe, expect, it } from "vitest";
import { createTemplateAiProvider, getCurrentTarget } from "@fox/core";
import type { DailyCheckIn, SetRecord, WorkoutSession } from "@fox/core";
import { createWorkoutRepository, type WorkoutRepository } from "../src/repository";
import { createFoxServer } from "../src/server";

const checkIn: DailyCheckIn = {
  sleep: "ok",
  fatigue: "medium",
  hunger: "not_hungry",
  stress: "low",
  painAreas: [],
  availableMinutes: 40
};

const tempDirs: string[] = [];
const servers: Server[] = [];

function createTempRepository(): { dir: string; repository: WorkoutRepository } {
  const dir = mkdtempSync(join(tmpdir(), "fox-api-server-test-"));
  tempDirs.push(dir);
  return { dir, repository: createWorkoutRepository(join(dir, "fox.sqlite")) };
}

function listen(server: Server): Promise<string> {
  servers.push(server);
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const address = server.address() as AddressInfo;
      resolve(`http://127.0.0.1:${address.port}`);
    });
  });
}

async function request<T>(baseUrl: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${baseUrl}${path}`, {
    ...init,
    headers: {
      "content-type": "application/json",
      ...init?.headers
    }
  });
  if (!response.ok) {
    throw new Error(await response.text());
  }
  return (await response.json()) as T;
}

function defaultRecord(
  session: WorkoutSession,
  overrides: Partial<Omit<SetRecord, "setIndex" | "plannedSetIndex">> = {}
): Omit<SetRecord, "setIndex" | "plannedSetIndex"> {
  const target = getCurrentTarget(session);
  return {
    status: "completed",
    reps: target?.targetReps,
    durationSeconds: target?.targetDurationSeconds,
    weight: target?.targetWeight,
    weightUnit: target?.weightUnit,
    pain: false,
    countingMethod: target?.targetDurationSeconds ? "timer" : "manual",
    ...overrides
  };
}

function seedConfirmedWorkoutWithHardFirstSet(repository: WorkoutRepository): WorkoutSession {
  let session = repository.createFreshSession("2026-06-20T10:00:00.000Z");
  session = repository.applyEventToCurrentSession({ type: "SUBMIT_CHECK_IN", checkIn, at: "2026-06-20T10:01:00.000Z" });
  session = repository.applyEventToCurrentSession({ type: "ACCEPT_PLAN", at: "2026-06-20T10:02:00.000Z" });

  let feedbackCount = 0;
  while (session.status !== "summary_pending") {
    if (session.status === "active_exercise") {
      const hardFirstSet =
        feedbackCount === 0
          ? { status: "partial" as const, reps: 6, weight: 10, weightUnit: "kg" as const, notes: "太重了，没跟上。" }
          : {};
      session = repository.applyEventToCurrentSession({
        type: "SET_FINISHED",
        record: defaultRecord(session, hardFirstSet),
        at: "2026-06-20T10:03:00.000Z"
      });
    } else if (session.status === "feedback") {
      session = repository.applyEventToCurrentSession({
        type: "SUBMIT_FEEDBACK",
        kind: feedbackCount === 0 ? "too_hard" : "completed",
        message: feedbackCount === 0 ? "太重了" : "完成",
        at: "2026-06-20T10:04:00.000Z"
      });
      feedbackCount += 1;
    } else if (session.status === "rest_timer") {
      session = repository.applyEventToCurrentSession({ type: "REST_FINISHED", at: "2026-06-20T10:05:00.000Z" });
    } else {
      throw new Error(`Unexpected status ${session.status}`);
    }
  }

  return repository.applyEventToCurrentSession({ type: "CONFIRM_SUMMARY", at: "2026-06-20T10:30:00.000Z" });
}

afterEach(async () => {
  await Promise.all(
    servers.splice(0).map(
      (server) =>
        new Promise<void>((resolve, reject) => {
          server.close((error) => (error ? reject(error) : resolve()));
        })
    )
  );
  for (const dir of tempDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("fox api server", () => {
  it("saves and returns the equipment inventory profile", async () => {
    const { repository } = createTempRepository();
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    const initial = await request<{ equipmentInventory: { notes?: string; items: Array<{ name: string; maxWeight?: number }> } }>(
      baseUrl,
      "/profile/equipment"
    );
    expect(initial.equipmentInventory.items.length).toBeGreaterThan(0);

    const edited = {
      ...initial.equipmentInventory,
      notes: "家庭健身房器材已初步确认。",
      items: initial.equipmentInventory.items.map((item, index) => (index === 0 ? { ...item, maxWeight: 30 } : item))
    };
    const saved = await request<{ equipmentInventory: typeof edited }>(baseUrl, "/profile/equipment", {
      method: "PATCH",
      body: JSON.stringify({ equipmentInventory: edited })
    });
    const restored = await request<{ equipmentInventory: typeof edited }>(baseUrl, "/profile/equipment");

    expect(saved.equipmentInventory.notes).toBe("家庭健身房器材已初步确认。");
    expect(restored.equipmentInventory.items[0]?.maxWeight).toBe(30);
  });

  it("saves and returns the user body profile", async () => {
    const { repository } = createTempRepository();
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    const empty = await request<{ userProfile: null }>(baseUrl, "/profile/user");
    expect(empty.userProfile).toBeNull();

    const saved = await request<{ userProfile: { heightCm?: number; weightKg?: number; measurements?: Array<{ value: number }> } }>(
      baseUrl,
      "/profile/user",
      {
        method: "PATCH",
        body: JSON.stringify({
          userProfile: {
            sex: "male",
            birthYear: 1993,
            ethnicity: "Asian",
            heightCm: 183,
            weightKg: 70,
            preferredWeightUnit: "kg",
            measurements: [{ kind: "shoulder_width", label: "肩宽", value: 43.5, unit: "cm", measuredAt: "2026-06-28T00:00:00.000Z" }]
          }
        })
      }
    );
    const restored = await request<{ userProfile: { heightCm?: number; weightKg?: number; measurements?: Array<{ value: number }> } }>(
      baseUrl,
      "/profile/user"
    );

    expect(saved.userProfile.heightCm).toBe(183);
    expect(restored.userProfile.measurements?.[0]?.value).toBe(43.5);
  });

  it("drafts an AI plan from check-in, equipment, and confirmed workout history", async () => {
    const { repository } = createTempRepository();
    const confirmed = seedConfirmedWorkoutWithHardFirstSet(repository);
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    const payload = await request<{
      draft: {
        recommendations: Array<{ exerciseId: string; source: string; weight?: number; rationale: string }>;
      };
      audit: { kind: string; status: string };
      session: WorkoutSession;
    }>(baseUrl, "/sessions/current/ai/plan-draft", {
      method: "POST",
      body: JSON.stringify({ checkIn })
    });

    const shoulderPress = payload.draft.recommendations.find((item) => item.exerciseId === "dumbbell_shoulder_press");
    expect(payload.audit.kind).toBe("plan_draft");
    expect(payload.audit.status).toBe("accepted_for_display");
    expect(payload.session.status).toBe("awaiting_approval");
    expect(payload.session.id).not.toBe(confirmed.id);
    expect(payload.session.aiAudits).toHaveLength(1);
    expect(shoulderPress?.source).toBe("history");
    expect(shoulderPress?.weight).toBeLessThan(10);
    expect(shoulderPress?.rationale).toContain("保守");
  });
});
