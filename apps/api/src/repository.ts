import { mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { randomUUID } from "node:crypto";
import { createDefaultEquipmentInventory, createSession, dispatchWorkoutEvent } from "@fox/core";
import type { EquipmentInventory, UserProfile, WorkoutEvent, WorkoutSession } from "@fox/core";

export interface EntryRecord {
  id: string;
  domain: "fitness";
  kind: "workout";
  title: string;
  status: "confirmed";
  occurredAt: string;
  payload: Record<string, unknown>;
  sourceSessionId: string;
  createdAt: string;
  updatedAt: string;
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
  listEntries: () => EntryRecord[];
  updateEntryNote: (entryId: string, userNote: string) => EntryRecord | null;
  getEquipmentInventory: () => EquipmentInventory;
  saveEquipmentInventory: (inventory: EquipmentInventory) => EquipmentInventory;
  getUserProfile: () => UserProfile | null;
  saveUserProfile: (profile: UserProfile) => UserProfile;
  listEvents: (sessionId: string) => StoredEventRecord[];
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

    CREATE INDEX IF NOT EXISTS idx_workout_sessions_updated_at ON workout_sessions(updated_at);
    CREATE INDEX IF NOT EXISTS idx_workout_events_session_id ON workout_events(session_id);
    CREATE INDEX IF NOT EXISTS idx_entries_occurred_at ON entries(occurred_at);
  `);

  const parseSession = (row: Row | undefined): WorkoutSession | null => {
    if (!row) {
      return null;
    }
    return JSON.parse(String(row.current_json)) as WorkoutSession;
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

  const listEntries = (): EntryRecord[] => {
    const rows = database
      .prepare(
        `SELECT id, domain, kind, title, status, occurred_at, payload_json, source_session_id, created_at, updated_at
         FROM entries
         ORDER BY datetime(occurred_at) DESC`
      )
      .all() as Row[];
    return rows.map((row) => ({
      id: String(row.id),
      domain: "fitness",
      kind: "workout",
      title: String(row.title),
      status: "confirmed",
      occurredAt: String(row.occurred_at),
      payload: JSON.parse(String(row.payload_json)) as Record<string, unknown>,
      sourceSessionId: String(row.source_session_id),
      createdAt: String(row.created_at),
      updatedAt: String(row.updated_at)
    }));
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

    return {
      id: String(row.id),
      domain: "fitness",
      kind: "workout",
      title: String(row.title),
      status: "confirmed",
      occurredAt: String(row.occurred_at),
      payload,
      sourceSessionId: String(row.source_session_id),
      createdAt: String(row.created_at),
      updatedAt
    };
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
    close: () => database.close()
  };
}
