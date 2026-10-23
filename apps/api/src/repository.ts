import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { createHash, randomUUID } from "node:crypto";
import { createDefaultEquipmentInventory, createSession, dispatchWorkoutEvent } from "@fox/core";
import type { EquipmentInventory, UserProfile, WorkoutEvent, WorkoutSession } from "@fox/core";

export type EntryKind = "meal" | "medical" | "workout" | "expense" | "note";
export type EntrySource = "workout_session" | "voice_draft";
export type EntryStatus = "draft" | "extracted" | "needs_review" | "confirmed";

export interface EvidenceItem {
  id: string;
  kind: "image" | "pdf" | "audio" | "text" | "receipt" | "prescription";
  uri: string;
  mimeType?: string;
  sha256?: string;
  createdAt: string;
}

export interface EntryRecord {
  id: string;
  domain: "fitness" | "life";
  kind: EntryKind;
  title: string;
  status: EntryStatus;
  occurredAt: string;
  timezone?: string;
  rawText?: string;
  evidence?: EvidenceItem[];
  extractedJson?: Record<string, unknown>;
  confirmedJson?: Record<string, unknown>;
  extractionConfidence?: number;
  payload: Record<string, unknown>;
  source: EntrySource;
  sourceSessionId?: string;
  sourceDraftId?: string;
  createdAt: string;
  updatedAt: string;
}

export interface EntryFilters {
  kind?: EntryKind;
  source?: EntrySource;
}

export interface VoiceAsrResult {
  schema: "fox.say_asr_result.v0";
  id: string;
  captureId: string;
  provider: string;
  transcript: string;
  language?: string;
  confidence?: number;
  segments?: unknown;
  rawResult?: unknown;
  receivedAt: string;
  createdAt: string;
  rawAudioCommitted: false;
}

export type VoiceAsrJobStatus = "queued" | "running" | "succeeded" | "failed";

export interface VoiceAsrJob {
  schema: "fox.say_asr_job.v0";
  id: string;
  captureId: string;
  status: VoiceAsrJobStatus;
  attempt: number;
  asrResultId?: string;
  errorCode?: string;
  errorMessage?: string;
  requestedAt: string;
  startedAt?: string;
  completedAt?: string;
  createdAt: string;
  updatedAt: string;
}

export type VoiceMacInputJobStatus = "queued" | "claimed" | "completed" | "failed";

export interface VoiceMacInputJob {
  schema: "fox.say_mac_input_job.v0";
  id: string;
  asrResultId: string;
  captureId: string;
  target: "clipboard";
  status: VoiceMacInputJobStatus;
  textSha256: string;
  textCharacters: number;
  errorCode?: string;
  errorMessage?: string;
  requestedAt: string;
  claimedAt?: string;
  completedAt?: string;
  createdAt: string;
  updatedAt: string;
}

export interface VoiceDraft {
  schema: "fox.voice_draft.v0";
  id: string;
  asrResultId: string;
  captureId: string;
  entryType: EntryKind;
  title: string;
  status: "needs_review" | "confirmed" | "discarded";
  rawText: string;
  evidence: EvidenceItem[];
  extractedJson: Record<string, unknown>;
  extractionConfidence: number;
  createdAt: string;
  updatedAt: string;
  confirmedEntryId?: string;
}

export interface CreateVoiceAsrResultInput {
  captureId: string;
  provider: string;
  transcript: string;
  language?: string;
  confidence?: number;
  segments?: unknown;
  rawResult?: unknown;
}

export interface CreateVoiceDraftInput {
  asrResultId: string;
  captureId: string;
  entryType: EntryKind;
  title: string;
  rawText: string;
  evidence: EvidenceItem[];
  extractedJson: Record<string, unknown>;
  extractionConfidence: number;
}

export interface ConfirmVoiceDraftInput {
  title?: string;
  occurredAt?: string;
  timezone?: string;
  confirmedJson?: Record<string, unknown>;
}

export interface UpdateVoiceDraftInput {
  entryType?: EntryKind;
  title?: string;
  status?: "needs_review" | "discarded";
  extractedJson?: Record<string, unknown>;
  extractionConfidence?: number;
}

export interface CreateVoiceMacInputJobInput {
  asrResultId: string;
  captureId: string;
  text: string;
  target: "clipboard";
}

export interface StoredEventRecord {
  id: number;
  sessionId: string;
  eventType: WorkoutEvent["type"];
  at: string;
  beforeStatus: WorkoutSession["status"];
  afterStatus: WorkoutSession["status"];
  payload: WorkoutEvent;
}

interface Row {
  [key: string]: unknown;
}

export interface WorkoutRepository {
  createFreshSession: (now?: string) => WorkoutSession;
  getCurrentSession: () => WorkoutSession | null;
  getSession: (id: string) => WorkoutSession | null;
  applyEventToCurrentSession: (event: WorkoutEvent) => WorkoutSession;
  listEntries: (filters?: EntryFilters) => EntryRecord[];
  updateEntryNote: (entryId: string, userNote: string) => EntryRecord | null;
  getEquipmentInventory: () => EquipmentInventory;
  saveEquipmentInventory: (inventory: EquipmentInventory) => EquipmentInventory;
  getUserProfile: () => UserProfile | null;
  saveUserProfile: (profile: UserProfile) => UserProfile;
  listEvents: (sessionId: string) => StoredEventRecord[];
  createVoiceAsrResult: (input: CreateVoiceAsrResultInput) => VoiceAsrResult;
  getVoiceAsrResult: (id: string) => VoiceAsrResult | null;
  listVoiceAsrResults: (captureId?: string) => VoiceAsrResult[];
  createOrReuseVoiceAsrJob: (captureId: string) => { job: VoiceAsrJob; reused: boolean };
  getVoiceAsrJob: (id: string) => VoiceAsrJob | null;
  listVoiceAsrJobs: (captureId?: string) => VoiceAsrJob[];
  claimNextVoiceAsrJob: () => VoiceAsrJob | null;
  succeedVoiceAsrJob: (id: string, asrResultId: string) => VoiceAsrJob | null;
  succeedActiveVoiceAsrJobForCapture: (captureId: string, asrResultId: string) => VoiceAsrJob | null;
  failVoiceAsrJob: (id: string, errorCode: string, errorMessage?: string) => VoiceAsrJob | null;
  createOrReuseVoiceMacInputJob: (input: CreateVoiceMacInputJobInput) => { job: VoiceMacInputJob; reused: boolean };
  getVoiceMacInputJob: (id: string) => VoiceMacInputJob | null;
  listVoiceMacInputJobs: (asrResultId?: string) => VoiceMacInputJob[];
  claimNextVoiceMacInputJob: () => { job: VoiceMacInputJob; text: string } | null;
  completeVoiceMacInputJob: (id: string) => VoiceMacInputJob | null;
  failVoiceMacInputJob: (id: string, errorCode: string, errorMessage?: string) => VoiceMacInputJob | null;
  createVoiceDraft: (input: CreateVoiceDraftInput) => VoiceDraft;
  getVoiceDraft: (id: string) => VoiceDraft | null;
  listVoiceDrafts: () => VoiceDraft[];
  updateVoiceDraft: (id: string, input: UpdateVoiceDraftInput) => VoiceDraft | null;
  confirmVoiceDraft: (id: string, input: ConfirmVoiceDraftInput) => { draft: VoiceDraft; entry: EntryRecord } | null;
  close: () => void;
}

export function defaultDatabasePath(): string {
  return resolve(process.cwd(), ".data", "fox.sqlite");
}

export function createWorkoutRepository(dbPath = defaultDatabasePath()): WorkoutRepository {
  mkdirSync(dirname(dbPath), { recursive: true });
  const database = new DatabaseSync(dbPath);
  database.exec("PRAGMA journal_mode = WAL;");
  database.exec("PRAGMA foreign_keys = ON;");
  database.exec(`
    CREATE TABLE IF NOT EXISTS workout_sessions (
      id TEXT PRIMARY KEY,
      status TEXT NOT NULL,
      current_json TEXT NOT NULL,
      entry_id TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS workout_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL,
      event_type TEXT NOT NULL,
      at TEXT NOT NULL,
      before_status TEXT NOT NULL,
      after_status TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      FOREIGN KEY (session_id) REFERENCES workout_sessions(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS entries (
      id TEXT PRIMARY KEY,
      domain TEXT NOT NULL,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      status TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      source_session_id TEXT NOT NULL UNIQUE,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (source_session_id) REFERENCES workout_sessions(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS profile_records (
      key TEXT PRIMARY KEY,
      payload_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS say_asr_results (
      id TEXT PRIMARY KEY,
      capture_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      transcript TEXT NOT NULL,
      language TEXT,
      confidence REAL,
      segments_json TEXT,
      raw_result_json TEXT,
      received_at TEXT NOT NULL,
      created_at TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS say_asr_jobs (
      id TEXT PRIMARY KEY,
      capture_id TEXT NOT NULL,
      status TEXT NOT NULL,
      attempt INTEGER NOT NULL,
      asr_result_id TEXT,
      error_code TEXT,
      error_message TEXT,
      requested_at TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (asr_result_id) REFERENCES say_asr_results(id) ON DELETE SET NULL
    );

    CREATE TABLE IF NOT EXISTS say_mac_input_jobs (
      id TEXT PRIMARY KEY,
      asr_result_id TEXT NOT NULL,
      capture_id TEXT NOT NULL,
      target TEXT NOT NULL,
      status TEXT NOT NULL,
      text_sha256 TEXT NOT NULL,
      text_characters INTEGER NOT NULL,
      error_code TEXT,
      error_message TEXT,
      requested_at TEXT NOT NULL,
      claimed_at TEXT,
      completed_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (asr_result_id) REFERENCES say_asr_results(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS say_voice_drafts (
      id TEXT PRIMARY KEY,
      asr_result_id TEXT NOT NULL,
      capture_id TEXT NOT NULL,
      entry_type TEXT NOT NULL,
      title TEXT NOT NULL,
      status TEXT NOT NULL,
      raw_text TEXT NOT NULL,
      evidence_json TEXT NOT NULL,
      extracted_json TEXT NOT NULL,
      extraction_confidence REAL NOT NULL,
      confirmed_entry_id TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      FOREIGN KEY (asr_result_id) REFERENCES say_asr_results(id) ON DELETE CASCADE
    );

    CREATE TABLE IF NOT EXISTS life_entries (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      status TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      timezone TEXT NOT NULL,
      raw_text TEXT,
      evidence_json TEXT NOT NULL,
      extracted_json TEXT,
      confirmed_json TEXT,
      extraction_confidence REAL,
      source TEXT NOT NULL,
      source_draft_id TEXT UNIQUE,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_workout_sessions_updated_at ON workout_sessions(updated_at);
    CREATE INDEX IF NOT EXISTS idx_workout_events_session_id ON workout_events(session_id);
    CREATE INDEX IF NOT EXISTS idx_entries_occurred_at ON entries(occurred_at);
    CREATE INDEX IF NOT EXISTS idx_life_entries_occurred_at ON life_entries(occurred_at);
    CREATE INDEX IF NOT EXISTS idx_life_entries_source ON life_entries(source);
    CREATE INDEX IF NOT EXISTS idx_say_asr_results_capture_id ON say_asr_results(capture_id);
    CREATE INDEX IF NOT EXISTS idx_say_asr_jobs_capture_status ON say_asr_jobs(capture_id, status, requested_at);
    CREATE INDEX IF NOT EXISTS idx_say_mac_input_jobs_result_status ON say_mac_input_jobs(asr_result_id, status, requested_at);
    CREATE INDEX IF NOT EXISTS idx_say_voice_drafts_updated_at ON say_voice_drafts(updated_at);
  `);

  const recoveryNow = new Date().toISOString();
  database
    .prepare(
      `UPDATE say_asr_jobs
       SET status = 'failed',
           error_code = 'asr_job_interrupted',
           error_message = 'Fox API restarted before this ASR job completed.',
           completed_at = ?,
           updated_at = ?
       WHERE status IN ('queued', 'running')`
    )
    .run(recoveryNow, recoveryNow);
  database
    .prepare(
      `UPDATE say_mac_input_jobs
       SET status = 'queued',
           claimed_at = NULL,
           updated_at = ?
       WHERE status = 'claimed'`
    )
    .run(recoveryNow);

  const parseSession = (row: Row | undefined): WorkoutSession | null => {
    if (!row) {
      return null;
    }
    return JSON.parse(String(row.current_json)) as WorkoutSession;
  };

  const parseJsonValue = <T>(value: unknown, fallback: T): T => {
    if (value === null || value === undefined || value === "") {
      return fallback;
    }
    return JSON.parse(String(value)) as T;
  };

  const matchesEntryFilters = (entry: EntryRecord, filters?: EntryFilters): boolean => {
    if (filters?.kind && entry.kind !== filters.kind) {
      return false;
    }
    if (filters?.source && entry.source !== filters.source) {
      return false;
    }
    return true;
  };

  const parseWorkoutEntry = (row: Row): EntryRecord => {
    const payload = JSON.parse(String(row.payload_json)) as Record<string, unknown>;
    return {
      id: String(row.id),
      domain: "fitness",
      kind: "workout",
      title: String(row.title),
      status: "confirmed",
      occurredAt: String(row.occurred_at),
      timezone: "Asia/Bangkok",
      evidence: [],
      extractedJson: payload,
      confirmedJson: payload,
      payload,
      source: "workout_session",
      sourceSessionId: String(row.source_session_id),
      createdAt: String(row.created_at),
      updatedAt: String(row.updated_at)
    };
  };

  const parseLifeEntry = (row: Row): EntryRecord => {
    const confirmedJson = parseJsonValue<Record<string, unknown> | undefined>(row.confirmed_json, undefined);
    const extractedJson = parseJsonValue<Record<string, unknown> | undefined>(row.extracted_json, undefined);
    const payload = confirmedJson ?? extractedJson ?? {};
    const kind = row.kind as EntryKind;
    return {
      id: String(row.id),
      domain: kind === "workout" ? "fitness" : "life",
      kind,
      title: String(row.title),
      status: row.status as EntryStatus,
      occurredAt: String(row.occurred_at),
      timezone: String(row.timezone),
      rawText: row.raw_text === null || row.raw_text === undefined ? undefined : String(row.raw_text),
      evidence: parseJsonValue<EvidenceItem[]>(row.evidence_json, []),
      extractedJson,
      confirmedJson,
      extractionConfidence: row.extraction_confidence === null || row.extraction_confidence === undefined ? undefined : Number(row.extraction_confidence),
      payload,
      source: row.source as EntrySource,
      sourceDraftId: row.source_draft_id === null || row.source_draft_id === undefined ? undefined : String(row.source_draft_id),
      createdAt: String(row.created_at),
      updatedAt: String(row.updated_at)
    };
  };

  const parseVoiceAsrResult = (row: Row | undefined): VoiceAsrResult | null => {
    if (!row) {
      return null;
    }
    return {
      schema: "fox.say_asr_result.v0",
      id: String(row.id),
      captureId: String(row.capture_id),
      provider: String(row.provider),
      transcript: String(row.transcript),
      language: row.language === null || row.language === undefined ? undefined : String(row.language),
      confidence: row.confidence === null || row.confidence === undefined ? undefined : Number(row.confidence),
      segments: parseJsonValue<unknown | undefined>(row.segments_json, undefined),
      rawResult: parseJsonValue<unknown | undefined>(row.raw_result_json, undefined),
      receivedAt: String(row.received_at),
      createdAt: String(row.created_at),
      rawAudioCommitted: false
    };
  };

  const parseVoiceAsrJob = (row: Row | undefined): VoiceAsrJob | null => {
    if (!row) {
      return null;
    }
    return {
      schema: "fox.say_asr_job.v0",
      id: String(row.id),
      captureId: String(row.capture_id),
      status: row.status as VoiceAsrJobStatus,
      attempt: Number(row.attempt),
      asrResultId: row.asr_result_id === null || row.asr_result_id === undefined ? undefined : String(row.asr_result_id),
      errorCode: row.error_code === null || row.error_code === undefined ? undefined : String(row.error_code),
      errorMessage: row.error_message === null || row.error_message === undefined ? undefined : String(row.error_message),
      requestedAt: String(row.requested_at),
      startedAt: row.started_at === null || row.started_at === undefined ? undefined : String(row.started_at),
      completedAt: row.completed_at === null || row.completed_at === undefined ? undefined : String(row.completed_at),
      createdAt: String(row.created_at),
      updatedAt: String(row.updated_at)
    };
  };

  const parseVoiceMacInputJob = (row: Row | undefined): VoiceMacInputJob | null => {
    if (!row) {
      return null;
    }
    return {
      schema: "fox.say_mac_input_job.v0",
      id: String(row.id),
      asrResultId: String(row.asr_result_id),
      captureId: String(row.capture_id),
      target: row.target as "clipboard",
      status: row.status as VoiceMacInputJobStatus,
      textSha256: String(row.text_sha256),
      textCharacters: Number(row.text_characters),
      errorCode: row.error_code === null || row.error_code === undefined ? undefined : String(row.error_code),
      errorMessage: row.error_message === null || row.error_message === undefined ? undefined : String(row.error_message),
      requestedAt: String(row.requested_at),
      claimedAt: row.claimed_at === null || row.claimed_at === undefined ? undefined : String(row.claimed_at),
      completedAt: row.completed_at === null || row.completed_at === undefined ? undefined : String(row.completed_at),
      createdAt: String(row.created_at),
      updatedAt: String(row.updated_at)
    };
  };

  const parseVoiceDraft = (row: Row | undefined): VoiceDraft | null => {
    if (!row) {
      return null;
    }
    return {
      schema: "fox.voice_draft.v0",
      id: String(row.id),
      asrResultId: String(row.asr_result_id),
      captureId: String(row.capture_id),
      entryType: row.entry_type as EntryKind,
      title: String(row.title),
      status: row.status as VoiceDraft["status"],
      rawText: String(row.raw_text),
      evidence: parseJsonValue<EvidenceItem[]>(row.evidence_json, []),
      extractedJson: parseJsonValue<Record<string, unknown>>(row.extracted_json, {}),
      extractionConfidence: Number(row.extraction_confidence),
      createdAt: String(row.created_at),
      updatedAt: String(row.updated_at),
      confirmedEntryId: row.confirmed_entry_id === null || row.confirmed_entry_id === undefined ? undefined : String(row.confirmed_entry_id)
    };
  };

  const saveSession = (session: WorkoutSession): WorkoutSession => {
    database
      .prepare(
        `INSERT INTO workout_sessions (id, status, current_json, entry_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           status = excluded.status,
           current_json = excluded.current_json,
           entry_id = excluded.entry_id,
           updated_at = excluded.updated_at`
      )
      .run(session.id, session.status, JSON.stringify(session), session.entryId ?? null, session.createdAt, session.updatedAt);
    return session;
  };

  const upsertEntryForConfirmedSession = (session: WorkoutSession): WorkoutSession => {
    if (session.status !== "confirmed") {
      return session;
    }

    const existing = database
      .prepare("SELECT id FROM entries WHERE source_session_id = ?")
      .get(session.id) as { id: string } | undefined;
    const entryId = existing?.id ?? session.entryId ?? `entry_${randomUUID()}`;
    const occurredAt = session.startedAt ?? session.endedAt ?? session.updatedAt;
    const title = `健身记录 ${occurredAt.slice(0, 10)}`;
    const payload = {
      kind: "workout",
      sessionId: session.id,
      status: session.status,
      checkIn: session.checkIn,
      plan: session.plan,
      feedbackEvents: session.feedbackEvents,
      timerEvents: session.timerEvents,
      adjustments: session.adjustments,
      coachMessages: session.coachMessages,
      aiAudits: session.aiAudits,
      summary: session.summary,
      startedAt: session.startedAt,
      endedAt: session.endedAt,
      confirmedAt: session.updatedAt
    };
    const sessionWithEntry = { ...session, entryId };

    database
      .prepare(
        `INSERT INTO entries (id, domain, kind, title, status, occurred_at, payload_json, source_session_id, created_at, updated_at)
         VALUES (?, 'fitness', 'workout', ?, 'confirmed', ?, ?, ?, ?, ?)
         ON CONFLICT(source_session_id) DO UPDATE SET
           title = excluded.title,
           status = excluded.status,
           occurred_at = excluded.occurred_at,
           payload_json = excluded.payload_json,
           updated_at = excluded.updated_at`
      )
      .run(entryId, title, occurredAt, JSON.stringify(payload), session.id, session.createdAt, session.updatedAt);

    return saveSession(sessionWithEntry);
  };

  const insertEvent = (sessionId: string, event: WorkoutEvent, before: WorkoutSession, after: WorkoutSession) => {
    const at = "at" in event && event.at ? event.at : after.updatedAt;
    database
      .prepare(
        `INSERT INTO workout_events (session_id, event_type, at, before_status, after_status, payload_json, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`
      )
      .run(sessionId, event.type, at, before.status, after.status, JSON.stringify(event), after.updatedAt);
  };

  const getCurrentSession = (): WorkoutSession | null => {
    const row = database
      .prepare("SELECT current_json FROM workout_sessions ORDER BY datetime(updated_at) DESC, rowid DESC LIMIT 1")
      .get() as Row | undefined;
    return parseSession(row);
  };

  const getSession = (id: string): WorkoutSession | null => {
    const row = database.prepare("SELECT current_json FROM workout_sessions WHERE id = ?").get(id) as Row | undefined;
    return parseSession(row);
  };

  const createFreshSession = (now?: string): WorkoutSession => {
    return saveSession(createSession(now));
  };

  const applyEventToCurrentSession = (event: WorkoutEvent): WorkoutSession => {
    const before = getCurrentSession() ?? createFreshSession();
    const after = dispatchWorkoutEvent(before, event);
    const persisted = upsertEntryForConfirmedSession(saveSession(after));
    insertEvent(before.id, event, before, persisted);
    return persisted;
  };

  const listEntries = (filters?: EntryFilters): EntryRecord[] => {
    const workoutRows = database
      .prepare(
        `SELECT id, domain, kind, title, status, occurred_at, payload_json, source_session_id, created_at, updated_at
         FROM entries`
      )
      .all() as Row[];
    const lifeRows = database
      .prepare(
        `SELECT id, kind, title, status, occurred_at, timezone, raw_text, evidence_json, extracted_json,
                confirmed_json, extraction_confidence, source, source_draft_id, created_at, updated_at
         FROM life_entries`
      )
      .all() as Row[];

    return [...workoutRows.map(parseWorkoutEntry), ...lifeRows.map(parseLifeEntry)]
      .filter((entry) => matchesEntryFilters(entry, filters))
      .sort((left, right) => new Date(right.occurredAt).getTime() - new Date(left.occurredAt).getTime());
  };

  const updateEntryNote = (entryId: string, userNote: string): EntryRecord | null => {
    const row = database
      .prepare(
        `SELECT id, domain, kind, title, status, occurred_at, payload_json, source_session_id, created_at, updated_at
         FROM entries
         WHERE id = ?`
      )
      .get(entryId) as Row | undefined;
    if (!row) {
      return null;
    }

    const updatedAt = new Date().toISOString();
    const payload = JSON.parse(String(row.payload_json)) as Record<string, unknown>;
    payload.userNote = userNote;
    database
      .prepare("UPDATE entries SET payload_json = ?, updated_at = ? WHERE id = ?")
      .run(JSON.stringify(payload), updatedAt, entryId);

    return parseWorkoutEntry({ ...row, payload_json: JSON.stringify(payload), updated_at: updatedAt });
  };

  const listEvents = (sessionId: string): StoredEventRecord[] => {
    const rows = database
      .prepare(
        `SELECT id, session_id, event_type, at, before_status, after_status, payload_json
         FROM workout_events
         WHERE session_id = ?
         ORDER BY id ASC`
      )
      .all(sessionId) as Row[];
    return rows.map((row) => ({
      id: Number(row.id),
      sessionId: String(row.session_id),
      eventType: row.event_type as WorkoutEvent["type"],
      at: String(row.at),
      beforeStatus: row.before_status as WorkoutSession["status"],
      afterStatus: row.after_status as WorkoutSession["status"],
      payload: JSON.parse(String(row.payload_json)) as WorkoutEvent
    }));
  };

  const getEquipmentInventory = (): EquipmentInventory => {
    const row = database.prepare("SELECT payload_json FROM profile_records WHERE key = 'equipment_inventory'").get() as Row | undefined;
    if (!row) {
      const inventory = createDefaultEquipmentInventory();
      saveEquipmentInventory(inventory);
      return inventory;
    }
    return JSON.parse(String(row.payload_json)) as EquipmentInventory;
  };

  const saveEquipmentInventory = (inventory: EquipmentInventory): EquipmentInventory => {
    const now = new Date().toISOString();
    const nextInventory = { ...inventory, updatedAt: now };
    database
      .prepare(
        `INSERT INTO profile_records (key, payload_json, created_at, updated_at)
         VALUES ('equipment_inventory', ?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET
           payload_json = excluded.payload_json,
           updated_at = excluded.updated_at`
      )
      .run(JSON.stringify(nextInventory), inventory.updatedAt ?? now, now);
    return nextInventory;
  };

  const getUserProfile = (): UserProfile | null => {
    const row = database.prepare("SELECT payload_json FROM profile_records WHERE key = 'user_profile'").get() as Row | undefined;
    return row ? (JSON.parse(String(row.payload_json)) as UserProfile) : null;
  };

  const saveUserProfile = (profile: UserProfile): UserProfile => {
    const now = new Date().toISOString();
    const nextProfile = { ...profile, updatedAt: now };
    database
      .prepare(
        `INSERT INTO profile_records (key, payload_json, created_at, updated_at)
         VALUES ('user_profile', ?, ?, ?)
         ON CONFLICT(key) DO UPDATE SET
           payload_json = excluded.payload_json,
           updated_at = excluded.updated_at`
      )
      .run(JSON.stringify(nextProfile), profile.updatedAt ?? now, now);
    return nextProfile;
  };

  const createVoiceAsrResult = (input: CreateVoiceAsrResultInput): VoiceAsrResult => {
    const now = new Date().toISOString();
    const id = `asr_${Date.now()}_${randomUUID().slice(0, 8)}`;
    database
      .prepare(
        `INSERT INTO say_asr_results
           (id, capture_id, provider, transcript, language, confidence, segments_json, raw_result_json, received_at, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
      )
      .run(
        id,
        input.captureId,
        input.provider,
        input.transcript,
        input.language ?? null,
        input.confidence ?? null,
        input.segments === undefined ? null : JSON.stringify(input.segments),
        input.rawResult === undefined ? null : JSON.stringify(input.rawResult),
        now,
        now
      );
    const result = getVoiceAsrResult(id);
    if (!result) {
      throw new Error("asr_result_create_failed");
    }
    return result;
  };

  const getVoiceAsrResult = (id: string): VoiceAsrResult | null => {
    const row = database.prepare("SELECT * FROM say_asr_results WHERE id = ?").get(id) as Row | undefined;
    return parseVoiceAsrResult(row);
  };

  const listVoiceAsrResults = (captureId?: string): VoiceAsrResult[] => {
    const rows = captureId
      ? (database
          .prepare("SELECT * FROM say_asr_results WHERE capture_id = ? ORDER BY datetime(created_at) DESC, rowid DESC")
          .all(captureId) as Row[])
      : (database.prepare("SELECT * FROM say_asr_results ORDER BY datetime(created_at) DESC, rowid DESC").all() as Row[]);
    return rows.map((row) => parseVoiceAsrResult(row)).filter((result): result is VoiceAsrResult => Boolean(result));
  };

  const getVoiceAsrJob = (id: string): VoiceAsrJob | null => {
    const row = database.prepare("SELECT * FROM say_asr_jobs WHERE id = ?").get(id) as Row | undefined;
    return parseVoiceAsrJob(row);
  };

  const listVoiceAsrJobs = (captureId?: string): VoiceAsrJob[] => {
    const rows = captureId
      ? (database
          .prepare("SELECT * FROM say_asr_jobs WHERE capture_id = ? ORDER BY datetime(requested_at) DESC, rowid DESC")
          .all(captureId) as Row[])
      : (database.prepare("SELECT * FROM say_asr_jobs ORDER BY datetime(requested_at) DESC, rowid DESC").all() as Row[]);
    return rows.map((row) => parseVoiceAsrJob(row)).filter((job): job is VoiceAsrJob => Boolean(job));
  };

  const createOrReuseVoiceAsrJob = (captureId: string): { job: VoiceAsrJob; reused: boolean } => {
    const active = database
      .prepare("SELECT * FROM say_asr_jobs WHERE capture_id = ? AND status IN ('queued', 'running') ORDER BY datetime(requested_at) DESC, rowid DESC LIMIT 1")
      .get(captureId) as Row | undefined;
    const existing = parseVoiceAsrJob(active);
    if (existing) {
      return { job: existing, reused: true };
    }
    const previousAttempt = database
      .prepare("SELECT MAX(attempt) AS attempt FROM say_asr_jobs WHERE capture_id = ?")
      .get(captureId) as Row | undefined;
    const attempt = Number(previousAttempt?.attempt ?? 0) + 1;
    const now = new Date().toISOString();
    const id = `asrjob_${Date.now()}_${randomUUID().slice(0, 8)}`;
    database
      .prepare(
        `INSERT INTO say_asr_jobs
           (id, capture_id, status, attempt, asr_result_id, error_code, error_message, requested_at, started_at, completed_at, created_at, updated_at)
         VALUES (?, ?, 'queued', ?, NULL, NULL, NULL, ?, NULL, NULL, ?, ?)`
      )
      .run(id, captureId, attempt, now, now, now);
    const job = getVoiceAsrJob(id);
    if (!job) {
      throw new Error("asr_job_create_failed");
    }
    return { job, reused: false };
  };

  const claimNextVoiceAsrJob = (): VoiceAsrJob | null => {
    const candidate = database
      .prepare("SELECT id FROM say_asr_jobs WHERE status = 'queued' ORDER BY datetime(requested_at) ASC, rowid ASC LIMIT 1")
      .get() as Row | undefined;
    if (!candidate) {
      return null;
    }
    const now = new Date().toISOString();
    const result = database
      .prepare("UPDATE say_asr_jobs SET status = 'running', started_at = ?, updated_at = ? WHERE id = ? AND status = 'queued'")
      .run(now, now, String(candidate.id));
    if (Number(result.changes) !== 1) {
      return null;
    }
    return getVoiceAsrJob(String(candidate.id));
  };

  const succeedVoiceAsrJob = (id: string, asrResultId: string): VoiceAsrJob | null => {
    const job = getVoiceAsrJob(id);
    if (!job) {
      return null;
    }
    if (job.status === "succeeded") {
      return job;
    }
    if (job.status === "failed") {
      return job;
    }
    const now = new Date().toISOString();
    database
      .prepare(
        `UPDATE say_asr_jobs
         SET status = 'succeeded',
             asr_result_id = ?,
             error_code = NULL,
             error_message = NULL,
             completed_at = ?,
             updated_at = ?
         WHERE id = ? AND status IN ('queued', 'running')`
      )
      .run(asrResultId, now, now, id);
    return getVoiceAsrJob(id);
  };

  const succeedActiveVoiceAsrJobForCapture = (captureId: string, asrResultId: string): VoiceAsrJob | null => {
    const active = database
      .prepare("SELECT id FROM say_asr_jobs WHERE capture_id = ? AND status IN ('queued', 'running') ORDER BY datetime(requested_at) DESC, rowid DESC LIMIT 1")
      .get(captureId) as Row | undefined;
    return active ? succeedVoiceAsrJob(String(active.id), asrResultId) : null;
  };

  const failVoiceAsrJob = (id: string, errorCode: string, errorMessage?: string): VoiceAsrJob | null => {
    const job = getVoiceAsrJob(id);
    if (!job) {
      return null;
    }
    if (job.status === "succeeded" || job.status === "failed") {
      return job;
    }
    const now = new Date().toISOString();
    database
      .prepare(
        `UPDATE say_asr_jobs
         SET status = 'failed',
             error_code = ?,
             error_message = ?,
             completed_at = ?,
             updated_at = ?
         WHERE id = ? AND status IN ('queued', 'running')`
      )
      .run(errorCode, errorMessage?.slice(0, 2_000) ?? null, now, now, id);
    return getVoiceAsrJob(id);
  };

  const getVoiceMacInputJob = (id: string): VoiceMacInputJob | null => {
    const row = database.prepare("SELECT * FROM say_mac_input_jobs WHERE id = ?").get(id) as Row | undefined;
    return parseVoiceMacInputJob(row);
  };

  const listVoiceMacInputJobs = (asrResultId?: string): VoiceMacInputJob[] => {
    const rows = asrResultId
      ? (database
          .prepare("SELECT * FROM say_mac_input_jobs WHERE asr_result_id = ? ORDER BY datetime(requested_at) DESC, rowid DESC")
          .all(asrResultId) as Row[])
      : (database.prepare("SELECT * FROM say_mac_input_jobs ORDER BY datetime(requested_at) DESC, rowid DESC").all() as Row[]);
    return rows.map((row) => parseVoiceMacInputJob(row)).filter((job): job is VoiceMacInputJob => Boolean(job));
  };

  const createOrReuseVoiceMacInputJob = (input: CreateVoiceMacInputJobInput): { job: VoiceMacInputJob; reused: boolean } => {
    const active = database
      .prepare(
        "SELECT * FROM say_mac_input_jobs WHERE asr_result_id = ? AND target = ? AND status IN ('queued', 'claimed') ORDER BY datetime(requested_at) DESC, rowid DESC LIMIT 1"
      )
      .get(input.asrResultId, input.target) as Row | undefined;
    const existing = parseVoiceMacInputJob(active);
    if (existing) {
      return { job: existing, reused: true };
    }
    const now = new Date().toISOString();
    const id = `macjob_${Date.now()}_${randomUUID().slice(0, 8)}`;
    const textSha256 = createHash("sha256").update(input.text).digest("hex");
    database
      .prepare(
        `INSERT INTO say_mac_input_jobs
           (id, asr_result_id, capture_id, target, status, text_sha256, text_characters, error_code, error_message, requested_at, claimed_at, completed_at, created_at, updated_at)
         VALUES (?, ?, ?, ?, 'queued', ?, ?, NULL, NULL, ?, NULL, NULL, ?, ?)`
      )
      .run(id, input.asrResultId, input.captureId, input.target, textSha256, input.text.length, now, now, now);
    const job = getVoiceMacInputJob(id);
    if (!job) {
      throw new Error("mac_input_job_create_failed");
    }
    return { job, reused: false };
  };

  const claimNextVoiceMacInputJob = (): { job: VoiceMacInputJob; text: string } | null => {
    const staleThreshold = new Date(Date.now() - 60_000).toISOString();
    const now = new Date().toISOString();
    database
      .prepare(
        `UPDATE say_mac_input_jobs
         SET status = 'queued',
             claimed_at = NULL,
             updated_at = ?
         WHERE status = 'claimed' AND claimed_at IS NOT NULL AND claimed_at < ?`
      )
      .run(now, staleThreshold);

    const candidate = database
      .prepare("SELECT id FROM say_mac_input_jobs WHERE status = 'queued' ORDER BY datetime(requested_at) ASC, rowid ASC LIMIT 1")
      .get() as Row | undefined;
    if (!candidate) {
      return null;
    }
    const result = database
      .prepare("UPDATE say_mac_input_jobs SET status = 'claimed', claimed_at = ?, updated_at = ? WHERE id = ? AND status = 'queued'")
      .run(now, now, String(candidate.id));
    if (Number(result.changes) !== 1) {
      return null;
    }
    const row = database
      .prepare(
        `SELECT mac_job.*, asr_result.transcript AS transcript
         FROM say_mac_input_jobs AS mac_job
         INNER JOIN say_asr_results AS asr_result ON asr_result.id = mac_job.asr_result_id
         WHERE mac_job.id = ?`
      )
      .get(String(candidate.id)) as Row | undefined;
    const job = parseVoiceMacInputJob(row);
    const text = row?.transcript === undefined || row?.transcript === null ? "" : String(row.transcript);
    if (!job || !text) {
      if (job) {
        failVoiceMacInputJob(job.id, "mac_input_transcript_missing", "ASR text is missing for this Mac input job.");
      }
      return null;
    }
    return { job, text };
  };

  const completeVoiceMacInputJob = (id: string): VoiceMacInputJob | null => {
    const job = getVoiceMacInputJob(id);
    if (!job) {
      return null;
    }
    if (job.status === "completed") {
      return job;
    }
    if (job.status !== "claimed") {
      return job;
    }
    const now = new Date().toISOString();
    database
      .prepare(
        `UPDATE say_mac_input_jobs
         SET status = 'completed',
             error_code = NULL,
             error_message = NULL,
             completed_at = ?,
             updated_at = ?
         WHERE id = ? AND status = 'claimed'`
      )
      .run(now, now, id);
    return getVoiceMacInputJob(id);
  };

  const failVoiceMacInputJob = (id: string, errorCode: string, errorMessage?: string): VoiceMacInputJob | null => {
    const job = getVoiceMacInputJob(id);
    if (!job) {
      return null;
    }
    if (job.status === "completed" || job.status === "failed") {
      return job;
    }
    const now = new Date().toISOString();
    database
      .prepare(
        `UPDATE say_mac_input_jobs
         SET status = 'failed',
             error_code = ?,
             error_message = ?,
             updated_at = ?
         WHERE id = ? AND status IN ('queued', 'claimed')`
      )
      .run(errorCode, errorMessage?.slice(0, 2_000) ?? null, now, id);
    return getVoiceMacInputJob(id);
  };

  const createVoiceDraft = (input: CreateVoiceDraftInput): VoiceDraft => {
    const now = new Date().toISOString();
    const id = `draft_${Date.now()}_${randomUUID().slice(0, 8)}`;
    database
      .prepare(
        `INSERT INTO say_voice_drafts
           (id, asr_result_id, capture_id, entry_type, title, status, raw_text, evidence_json,
            extracted_json, extraction_confidence, confirmed_entry_id, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, 'needs_review', ?, ?, ?, ?, NULL, ?, ?)`
      )
      .run(
        id,
        input.asrResultId,
        input.captureId,
        input.entryType,
        input.title,
        input.rawText,
        JSON.stringify(input.evidence),
        JSON.stringify(input.extractedJson),
        input.extractionConfidence,
        now,
        now
      );
    const draft = getVoiceDraft(id);
    if (!draft) {
      throw new Error("voice_draft_create_failed");
    }
    return draft;
  };

  const getVoiceDraft = (id: string): VoiceDraft | null => {
    const row = database.prepare("SELECT * FROM say_voice_drafts WHERE id = ?").get(id) as Row | undefined;
    return parseVoiceDraft(row);
  };

  const listVoiceDrafts = (): VoiceDraft[] => {
    const rows = database.prepare("SELECT * FROM say_voice_drafts ORDER BY datetime(updated_at) DESC, rowid DESC").all() as Row[];
    return rows.map((row) => parseVoiceDraft(row)).filter((draft): draft is VoiceDraft => Boolean(draft));
  };

  const updateVoiceDraft = (id: string, input: UpdateVoiceDraftInput): VoiceDraft | null => {
    const draft = getVoiceDraft(id);
    if (!draft) {
      return null;
    }
    const now = new Date().toISOString();
    const extractionConfidence =
      typeof input.extractionConfidence === "number" && Number.isFinite(input.extractionConfidence)
        ? Math.max(0, Math.min(1, input.extractionConfidence))
        : draft.extractionConfidence;
    database
      .prepare(
        `UPDATE say_voice_drafts
         SET entry_type = ?,
             title = ?,
             status = ?,
             extracted_json = ?,
             extraction_confidence = ?,
             updated_at = ?
         WHERE id = ?`
      )
      .run(
        input.entryType ?? draft.entryType,
        input.title?.trim() || draft.title,
        input.status ?? draft.status,
        JSON.stringify(input.extractedJson ?? draft.extractedJson),
        extractionConfidence,
        now,
        id
      );
    return getVoiceDraft(id);
  };

  const confirmVoiceDraft = (id: string, input: ConfirmVoiceDraftInput): { draft: VoiceDraft; entry: EntryRecord } | null => {
    const draft = getVoiceDraft(id);
    if (!draft) {
      return null;
    }
    const now = new Date().toISOString();
    const existingEntryId = draft.confirmedEntryId;
    const entryId = existingEntryId ?? `entry_${randomUUID()}`;
    const title = input.title?.trim() || draft.title;
    const occurredAt = input.occurredAt ?? now;
    const timezone = input.timezone?.trim() || "Asia/Bangkok";
    const confirmedJson = input.confirmedJson ?? draft.extractedJson;

    database
      .prepare(
        `INSERT INTO life_entries
           (id, kind, title, status, occurred_at, timezone, raw_text, evidence_json, extracted_json,
            confirmed_json, extraction_confidence, source, source_draft_id, created_at, updated_at)
         VALUES (?, ?, ?, 'confirmed', ?, ?, ?, ?, ?, ?, ?, 'voice_draft', ?, ?, ?)
         ON CONFLICT(source_draft_id) DO UPDATE SET
           title = excluded.title,
           status = excluded.status,
           occurred_at = excluded.occurred_at,
           timezone = excluded.timezone,
           raw_text = excluded.raw_text,
           evidence_json = excluded.evidence_json,
           extracted_json = excluded.extracted_json,
           confirmed_json = excluded.confirmed_json,
           extraction_confidence = excluded.extraction_confidence,
           updated_at = excluded.updated_at`
      )
      .run(
        entryId,
        draft.entryType,
        title,
        occurredAt,
        timezone,
        draft.rawText,
        JSON.stringify(draft.evidence),
        JSON.stringify(draft.extractedJson),
        JSON.stringify(confirmedJson),
        draft.extractionConfidence,
        draft.id,
        draft.createdAt,
        now
      );

    database
      .prepare("UPDATE say_voice_drafts SET status = 'confirmed', confirmed_entry_id = ?, updated_at = ? WHERE id = ?")
      .run(entryId, now, draft.id);

    const updatedDraft = getVoiceDraft(draft.id);
    const entry = listEntries({ source: "voice_draft" }).find((candidate) => candidate.sourceDraftId === draft.id);
    if (!updatedDraft || !entry) {
      throw new Error("voice_draft_confirm_failed");
    }
    return { draft: updatedDraft, entry };
  };

  return {
    createFreshSession,
    getCurrentSession,
    getSession,
    applyEventToCurrentSession,
    listEntries,
    updateEntryNote,
    getEquipmentInventory,
    saveEquipmentInventory,
    getUserProfile,
    saveUserProfile,
    listEvents,
    createVoiceAsrResult,
    getVoiceAsrResult,
    listVoiceAsrResults,
    createOrReuseVoiceAsrJob,
    getVoiceAsrJob,
    listVoiceAsrJobs,
    claimNextVoiceAsrJob,
    succeedVoiceAsrJob,
    succeedActiveVoiceAsrJobForCapture,
    failVoiceAsrJob,
    createOrReuseVoiceMacInputJob,
    getVoiceMacInputJob,
    listVoiceMacInputJobs,
    claimNextVoiceMacInputJob,
    completeVoiceMacInputJob,
    failVoiceMacInputJob,
    createVoiceDraft,
    getVoiceDraft,
    listVoiceDrafts,
    updateVoiceDraft,
    confirmVoiceDraft,
    close: () => database.close()
  };
}
