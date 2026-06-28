import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import {
  createSession,
  createTemplateAiProvider,
  draftAdjustmentSuggestionWithFallback,
  draftFeedbackOptionsWithFallback,
  draftPlanWithFallback
} from "@fox/core";
import type { AiProvider, DailyCheckIn, EquipmentInventory, ExerciseHistorySnapshot, FeedbackKind, UserProfile, WorkoutEvent } from "@fox/core";
import { createWorkoutRepository, defaultDatabasePath, type EntryRecord, type WorkoutRepository } from "./repository.js";

const port = Number(process.env.FOX_API_PORT ?? 4177);
const host = process.env.FOX_API_HOST;

export interface FoxServerDependencies {
  repository: WorkoutRepository;
  aiProvider: AiProvider;
}

export function createDefaultDependencies(): FoxServerDependencies {
  return {
    repository: createWorkoutRepository(process.env.FOX_DB_PATH ?? defaultDatabasePath()),
    aiProvider: createTemplateAiProvider()
  };
}

function sendJson(response: ServerResponse, status: number, payload: unknown): void {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(payload));
}

function readJson<T>(request: IncomingMessage): Promise<T> {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", (chunk) => {
      body += chunk;
    });
    request.on("end", () => {
      try {
        resolve(body ? (JSON.parse(body) as T) : ({} as T));
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function recentRiskAreas(entries: EntryRecord[]): string[] {
  const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const areas = new Set<string>();
  for (const entry of entries) {
    if (new Date(entry.occurredAt).getTime() < sevenDaysAgo) {
      continue;
    }
    const feedbackEvents = entry.payload.feedbackEvents;
    if (!Array.isArray(feedbackEvents)) {
      continue;
    }
    for (const feedback of feedbackEvents) {
      if (!feedback || typeof feedback !== "object") {
        continue;
      }
      const event = feedback as Record<string, unknown>;
      if (event.kind !== "pain") {
        continue;
      }
      const exerciseName = String(event.exerciseName ?? "").toLowerCase();
      if (exerciseName.includes("shoulder") || exerciseName.includes("press") || exerciseName.includes("raise")) {
        areas.add("肩");
      } else {
        areas.add("recent pain");
      }
    }
  }
  return [...areas];
}

function enrichWorkoutEventWithHistory(event: WorkoutEvent, repository: WorkoutRepository): WorkoutEvent {
  if (event.type !== "SUBMIT_CHECK_IN") {
    return event;
  }
  const riskAreas = recentRiskAreas(repository.listEntries());
  if (riskAreas.length === 0) {
    return event;
  }
  return {
    ...event,
    checkIn: {
      ...event.checkIn,
      painAreas: [...new Set([...event.checkIn.painAreas, ...riskAreas])]
    }
  };
}

function entryFeedbackEvents(entry: EntryRecord): Array<Record<string, unknown>> {
  return Array.isArray(entry.payload.feedbackEvents)
    ? (entry.payload.feedbackEvents.filter((item) => item && typeof item === "object") as Array<Record<string, unknown>>)
    : [];
}

function buildExerciseHistory(entries: EntryRecord[]): ExerciseHistorySnapshot[] {
  const history: ExerciseHistorySnapshot[] = [];
  for (const entry of entries) {
    const plan = entry.payload.plan;
    if (!plan || typeof plan !== "object" || !Array.isArray((plan as { exercises?: unknown }).exercises)) {
      continue;
    }
    const feedbackEvents = entryFeedbackEvents(entry);
    for (const exercise of (plan as { exercises: Array<Record<string, unknown>> }).exercises) {
      const sets = Array.isArray(exercise.completedSets) ? exercise.completedSets : [];
      if (sets.length === 0) {
        continue;
      }
      const exerciseName = String(exercise.name ?? "Unknown exercise");
      history.push({
        exerciseId: typeof exercise.exerciseId === "string" ? exercise.exerciseId : undefined,
        exerciseName,
        occurredAt: entry.occurredAt,
        sets: sets as ExerciseHistorySnapshot["sets"],
        feedbackKinds: feedbackEvents
          .filter((event) => String(event.exerciseName ?? "") === exerciseName)
          .map((event) => event.kind as FeedbackKind)
      });
    }
  }
  return history;
}

function buildRiskSignals(entries: EntryRecord[]): string[] {
  const signals = new Set<string>();
  for (const entry of entries) {
    for (const event of entryFeedbackEvents(entry)) {
      const kind = String(event.kind ?? "");
      if (kind === "pain" || kind === "too_hard" || kind === "not_followed" || kind === "skip") {
        signals.add(`${String(event.exerciseName ?? "unknown")}: ${kind}`);
      }
    }
  }
  return [...signals].slice(0, 12);
}

function isTerminalSession(status: string): boolean {
  return status === "confirmed" || status === "cancelled" || status === "aborted";
}

function ensureOpenPlanningSession(repository: WorkoutRepository): void {
  const current = repository.getCurrentSession();
  if (current && isTerminalSession(current.status)) {
    repository.createFreshSession();
  }
}

export async function route(request: IncomingMessage, response: ServerResponse, dependencies: FoxServerDependencies): Promise<void> {
  const { repository, aiProvider } = dependencies;
  const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "localhost"}`);
  const pathname = url.pathname.replace(/^\/api/, "") || "/";

  response.setHeader("Access-Control-Allow-Origin", "*");
  response.setHeader("Access-Control-Allow-Headers", "content-type");
  response.setHeader("Access-Control-Allow-Methods", "GET,POST,PATCH,OPTIONS");

  if (request.method === "OPTIONS") {
    response.writeHead(204);
    response.end();
    return;
  }

  if (request.method === "GET" && pathname === "/health") {
    sendJson(response, 200, { ok: true, service: "fox-api" });
    return;
  }

  if (request.method === "GET" && pathname === "/demo/session") {
    sendJson(response, 200, createSession());
    return;
  }

  if (request.method === "GET" && pathname === "/sessions/current") {
    const session = repository.getCurrentSession() ?? repository.createFreshSession();
    sendJson(response, 200, { session });
    return;
  }

  if (request.method === "GET" && pathname === "/profile/equipment") {
    sendJson(response, 200, { equipmentInventory: repository.getEquipmentInventory() });
    return;
  }

  if (request.method === "PATCH" && pathname === "/profile/equipment") {
    const body = await readJson<{ equipmentInventory?: EquipmentInventory }>(request);
    if (!body.equipmentInventory?.items) {
      sendJson(response, 400, { error: "equipment_inventory_required" });
      return;
    }
    sendJson(response, 200, { equipmentInventory: repository.saveEquipmentInventory(body.equipmentInventory) });
    return;
  }

  if (request.method === "GET" && pathname === "/profile/user") {
    sendJson(response, 200, { userProfile: repository.getUserProfile() });
    return;
  }

  if (request.method === "PATCH" && pathname === "/profile/user") {
    const body = await readJson<{ userProfile?: UserProfile }>(request);
    if (!body.userProfile || typeof body.userProfile !== "object") {
      sendJson(response, 400, { error: "user_profile_required" });
      return;
    }
    sendJson(response, 200, { userProfile: repository.saveUserProfile(body.userProfile) });
    return;
  }

  if (request.method === "POST" && pathname === "/sessions") {
    const session = repository.createFreshSession();
    sendJson(response, 201, { session });
    return;
  }

  if (request.method === "POST" && pathname === "/sessions/current/events") {
    const event = await readJson<WorkoutEvent>(request);
    if (!event.type) {
      sendJson(response, 400, { error: "event_type_required" });
      return;
    }
    if (event.type === "SUBMIT_CHECK_IN" || event.type === "LOAD_PLAN_DRAFT") {
      ensureOpenPlanningSession(repository);
    }
    const session = repository.applyEventToCurrentSession(enrichWorkoutEventWithHistory(event, repository));
    sendJson(response, 200, { session });
    return;
  }

  if (request.method === "POST" && pathname === "/sessions/current/plan-draft") {
    const body = await readJson<Extract<WorkoutEvent, { type: "LOAD_PLAN_DRAFT" }>>(request);
    if (!body.plan) {
      sendJson(response, 400, { error: "plan_required" });
      return;
    }
    ensureOpenPlanningSession(repository);
    const session = repository.applyEventToCurrentSession({
      type: "LOAD_PLAN_DRAFT",
      plan: body.plan,
      checkIn: body.checkIn,
      source: body.source ?? "ai",
      message: body.message
    });
    sendJson(response, 200, { session });
    return;
  }

  if (request.method === "POST" && pathname === "/sessions/current/ai/plan-draft") {
    const body = await readJson<{ checkIn?: DailyCheckIn }>(request);
    if (!body.checkIn) {
      sendJson(response, 400, { error: "check_in_required" });
      return;
    }
    const entries = repository.listEntries();
    ensureOpenPlanningSession(repository);
    const result = await draftPlanWithFallback(aiProvider, {
      checkIn: body.checkIn,
      equipmentInventory: repository.getEquipmentInventory(),
      exerciseHistory: buildExerciseHistory(entries),
      recentRiskSignals: buildRiskSignals(entries)
    });
    repository.applyEventToCurrentSession({
      type: "LOAD_PLAN_DRAFT",
      plan: result.value.plan,
      checkIn: body.checkIn,
      source: "ai",
      message: result.value.coachMessage
    });
    const auditedSession = repository.applyEventToCurrentSession({ type: "RECORD_AI_AUDIT", audit: result.audit });
    sendJson(response, 200, { draft: result.value, audit: result.audit, session: auditedSession });
    return;
  }

  if (request.method === "GET" && pathname === "/sessions/current/ai/feedback-options") {
    const session = repository.getCurrentSession() ?? repository.createFreshSession();
    const result = await draftFeedbackOptionsWithFallback(aiProvider, session);
    const auditedSession = repository.applyEventToCurrentSession({ type: "RECORD_AI_AUDIT", audit: result.audit });
    sendJson(response, 200, { options: result.value, audit: result.audit, session: auditedSession });
    return;
  }

  if (request.method === "GET" && pathname === "/sessions/current/ai/adjustment-suggestion") {
    const session = repository.getCurrentSession() ?? repository.createFreshSession();
    const result = await draftAdjustmentSuggestionWithFallback(aiProvider, session);
    const auditedSession = repository.applyEventToCurrentSession({ type: "RECORD_AI_AUDIT", audit: result.audit });
    sendJson(response, 200, { suggestion: result.value, audit: result.audit, session: auditedSession });
    return;
  }

  if (request.method === "GET" && pathname === "/entries") {
    sendJson(response, 200, { entries: repository.listEntries() });
    return;
  }

  const entryMatch = pathname.match(/^\/entries\/([^/]+)$/);
  if (request.method === "PATCH" && entryMatch) {
    const body = await readJson<{ userNote?: string }>(request);
    const entry = repository.updateEntryNote(entryMatch[1] ?? "", body.userNote ?? "");
    if (!entry) {
      sendJson(response, 404, { error: "entry_not_found" });
      return;
    }
    sendJson(response, 200, { entry });
    return;
  }

  const eventMatch = pathname.match(/^\/sessions\/([^/]+)\/events$/);
  if (request.method === "GET" && eventMatch) {
    sendJson(response, 200, { events: repository.listEvents(eventMatch[1] ?? "") });
    return;
  }

  sendJson(response, 404, { error: "not_found" });
}

export function createFoxServer(dependencies: FoxServerDependencies = createDefaultDependencies()): Server {
  return createServer((request, response) => {
    route(request, response, dependencies).catch((error: unknown) => {
      console.error(error);
      sendJson(response, 500, { error: "internal_server_error" });
    });
  });
}

if (process.env.NODE_ENV !== "test" && process.env.VITEST !== "true") {
  const server = createFoxServer();
  const onListening = () => {
    console.log(`fox api listening on http://${host ?? "localhost"}:${port}`);
  };
  if (host) {
    server.listen(port, host, onListening);
  } else {
    server.listen(port, onListening);
  }
}
