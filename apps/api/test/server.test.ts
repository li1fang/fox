import { createHash } from "node:crypto";
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

async function requestResponse(baseUrl: string, path: string, init?: RequestInit): Promise<Response> {
  return fetch(`${baseUrl}${path}`, init);
}

async function waitFor<T>(read: () => Promise<T>, matches: (value: T) => boolean, timeoutMs = 5_000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let latest: T | undefined;
  while (Date.now() < deadline) {
    latest = await read();
    if (matches(latest)) {
      return latest;
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  throw new Error(`wait_for_timeout: ${JSON.stringify(latest)}`);
}

async function createSayCapture(baseUrl: string, audio = Buffer.from("fake-ipad-m4a-audio")) {
  const response = await requestResponse(baseUrl, "/say/capture", {
    method: "POST",
    headers: { "content-type": "audio/mp4" },
    body: audio
  });
  if (!response.ok) {
    throw new Error(await response.text());
  }
  return ((await response.json()) as { capture: { id: string; sha256: string; bytes: number } }).capture;
}

async function createLinuxAsrResult(baseUrl: string, captureId: string, transcript: string) {
  return request<{
    asrResult: {
      schema: string;
      id: string;
      captureId: string;
      provider: string;
      transcript: string;
      rawAudioCommitted: boolean;
    };
  }>(baseUrl, "/say/asr-results", {
    method: "POST",
    body: JSON.stringify({
      captureId,
      provider: "linux-sensevoice",
      language: "zh-CN",
      confidence: 0.91,
      transcript,
      rawResult: { evidence: "test-linux-asr" }
    })
  });
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
  it("captures Fox Say audio and exposes latest metadata plus audio replay", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    try {
      const audio = Buffer.from("fake-webm-audio");
      const response = await requestResponse(baseUrl, "/say/capture", {
        method: "POST",
        headers: { "content-type": "audio/webm" },
        body: audio
      });
      expect(response.status).toBe(201);
      const payload = (await response.json()) as {
        capture: { schema: string; id: string; bytes: number; sha256: string; audioPathShape: string; rawAudioCommitted: boolean };
      };

      expect(payload.capture.schema).toBe("fox.say_capture.v0");
      expect(payload.capture.bytes).toBe(audio.byteLength);
      expect(payload.capture.sha256).toBe(createHash("sha256").update(audio).digest("hex"));
      expect(payload.capture.audioPathShape).toContain(payload.capture.id);
      expect(payload.capture.rawAudioCommitted).toBe(false);

      const latest = await request<{ capture: { id: string; bytes: number } }>(baseUrl, "/say/captures/latest");
      expect(latest.capture.id).toBe(payload.capture.id);
      expect(latest.capture.bytes).toBe(audio.byteLength);

      const audioResponse = await requestResponse(baseUrl, `/say/captures/${payload.capture.id}/audio`);
      expect(audioResponse.status).toBe(200);
      expect(audioResponse.headers.get("content-type")).toBe("audio/webm");
      expect(Buffer.from(await audioResponse.arrayBuffer()).toString("utf8")).toBe("fake-webm-audio");
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("rejects empty Fox Say captures", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    try {
      const response = await requestResponse(baseUrl, "/say/capture", {
        method: "POST",
        headers: { "content-type": "audio/webm" },
        body: Buffer.alloc(0)
      });
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "empty_capture" });
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("saves Fox Say corpus sample manifests without exposing raw audio paths", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    const previousCorpusDir = process.env.FOX_SAY_CORPUS_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    process.env.FOX_SAY_CORPUS_DIR = join(dir, "say-corpus");
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    try {
      const audio = Buffer.from("fake-ipad-m4a-audio");
      const captureResponse = await requestResponse(baseUrl, "/say/capture", {
        method: "POST",
        headers: { "content-type": "audio/mp4" },
        body: audio
      });
      const { capture } = (await captureResponse.json()) as { capture: { id: string; sha256: string } };

      const sampleResponse = await requestResponse(baseUrl, "/say/corpus-samples", {
        method: "POST",
        body: JSON.stringify({
          captureId: capture.id,
          bucket: "short_command",
          expectedText: "完成本组",
          device: "iPad",
          environment: "quiet_room",
          noiseNotes: "near field",
          speakerProfile: "owner"
        })
      });
      expect(sampleResponse.status).toBe(201);
      const payload = (await sampleResponse.json()) as {
        sample: {
          schema: string;
          sampleId: string;
          sample_id: string;
          expectedText: string;
          expected_text: string;
          captureId: string;
          audioPath: string;
          audio_path: string;
          sha256: string;
          rawAudioCommitted: boolean;
          raw_audio_committed: boolean;
        };
        summary: { total: number; buckets: Record<string, number> };
      };

      expect(payload.sample.schema).toBe("fox.say_corpus_sample.v0");
      expect(payload.sample.sampleId).toBe("fox-say-0001");
      expect(payload.sample.sample_id).toBe("fox-say-0001");
      expect(payload.sample.expectedText).toBe("完成本组");
      expect(payload.sample.expected_text).toBe("完成本组");
      expect(payload.sample.captureId).toBe(capture.id);
      expect(payload.sample.sha256).toBe(capture.sha256);
      expect(payload.sample.audioPath).toContain("runtime-only/");
      expect(payload.sample.audio_path).toContain("runtime-only/");
      expect(payload.sample.audioPath).not.toContain(dir);
      expect(payload.sample.rawAudioCommitted).toBe(false);
      expect(payload.sample.raw_audio_committed).toBe(false);
      expect(payload.summary.total).toBe(1);
      expect(payload.summary.buckets.short_command).toBe(1);

      const listed = await request<{ samples: Array<{ sampleId: string }>; summary: { total: number } }>(baseUrl, "/say/corpus-samples");
      expect(listed.samples[0]?.sampleId).toBe("fox-say-0001");
      expect(listed.summary.total).toBe(1);
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
      if (previousCorpusDir === undefined) {
        delete process.env.FOX_SAY_CORPUS_DIR;
      } else {
        process.env.FOX_SAY_CORPUS_DIR = previousCorpusDir;
      }
    }
  });

  it("ingests Linux ASR results without creating entries or mutating workout state", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    try {
      const before = await request<{ session: WorkoutSession }>(baseUrl, "/sessions/current");
      const capture = await createSayCapture(baseUrl);
      const { asrResult } = await createLinuxAsrResult(baseUrl, capture.id, "今天跑步五分钟，配速五公里每小时，平板支撑没做。");

      expect(asrResult.schema).toBe("fox.say_asr_result.v0");
      expect(asrResult.captureId).toBe(capture.id);
      expect(asrResult.provider).toBe("linux-sensevoice");
      expect(asrResult.transcript).toContain("跑步五分钟");
      expect(asrResult.rawAudioCommitted).toBe(false);

      const voiceEntries = await request<{ entries: unknown[] }>(baseUrl, "/entries?source=voice_draft");
      const after = await request<{ session: WorkoutSession }>(baseUrl, "/sessions/current");
      expect(voiceEntries.entries).toHaveLength(0);
      expect(after.session.id).toBe(before.session.id);
      expect(after.session.status).toBe(before.session.status);
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("creates a reviewable Fox draft from a Linux ASR result", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    try {
      const capture = await createSayCapture(baseUrl);
      const { asrResult } = await createLinuxAsrResult(baseUrl, capture.id, "今天跑步五分钟，配速五公里每小时，平板支撑没做。");
      const payload = await request<{
        draft: {
          schema: string;
          id: string;
          asrResultId: string;
          captureId: string;
          entryType: string;
          status: string;
          rawText: string;
          evidence: Array<{ kind: string; uri: string; sha256?: string }>;
          extractedJson: { notes?: string; status?: string };
        };
      }>(baseUrl, "/say/drafts", {
        method: "POST",
        body: JSON.stringify({ asrResultId: asrResult.id })
      });

      expect(payload.draft.schema).toBe("fox.voice_draft.v0");
      expect(payload.draft.asrResultId).toBe(asrResult.id);
      expect(payload.draft.captureId).toBe(capture.id);
      expect(payload.draft.entryType).toBe("workout");
      expect(payload.draft.status).toBe("needs_review");
      expect(payload.draft.rawText).toBe(asrResult.transcript);
      expect(payload.draft.evidence[0]?.kind).toBe("audio");
      expect(payload.draft.evidence[0]?.uri).toBe(`fox-say-capture:${capture.id}`);
      expect(payload.draft.evidence[0]?.sha256).toBe(capture.sha256);
      expect(payload.draft.extractedJson.notes).toContain("跑步五分钟");
      expect(JSON.stringify(payload.draft)).not.toContain(dir);
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("confirms a Fox Say draft into a confirmed Entry after user review", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    try {
      const before = await request<{ session: WorkoutSession }>(baseUrl, "/sessions/current");
      const capture = await createSayCapture(baseUrl);
      const { asrResult } = await createLinuxAsrResult(baseUrl, capture.id, "今天跑步五分钟，配速五公里每小时，平板支撑没做。");
      const { draft } = await request<{ draft: { id: string } }>(baseUrl, "/say/drafts", {
        method: "POST",
        body: JSON.stringify({ asrResultId: asrResult.id })
      });

      const confirmed = await request<{
        draft: { id: string; status: string; confirmedEntryId: string };
        entry: {
          id: string;
          kind: string;
          status: string;
          source: string;
          sourceDraftId: string;
          rawText: string;
          evidence: Array<{ uri: string }>;
          confirmedJson: { notes?: string; status?: string; user_confirmation_status?: string };
        };
      }>(baseUrl, `/say/drafts/${draft.id}/confirm`, {
        method: "POST",
        body: JSON.stringify({
          title: "语音训练记录",
          occurredAt: "2026-07-02T10:00:00.000Z",
          timezone: "Asia/Bangkok",
          confirmedJson: {
            notes: "跑步机 5 分钟，速度 5km/h；平板支撑未完成。",
            status: "completed",
            user_confirmation_status: "confirmed"
          }
        })
      });

      expect(confirmed.draft.status).toBe("confirmed");
      expect(confirmed.draft.confirmedEntryId).toBe(confirmed.entry.id);
      expect(confirmed.entry.kind).toBe("workout");
      expect(confirmed.entry.status).toBe("confirmed");
      expect(confirmed.entry.source).toBe("voice_draft");
      expect(confirmed.entry.sourceDraftId).toBe(draft.id);
      expect(confirmed.entry.rawText).toContain("平板支撑没做");
      expect(confirmed.entry.evidence[0]?.uri).toBe(`fox-say-capture:${capture.id}`);
      expect(confirmed.entry.confirmedJson.notes).toContain("5km/h");
      expect(confirmed.entry.confirmedJson.user_confirmation_status).toBe("confirmed");

      const listed = await request<{ entries: Array<{ id: string; source: string; kind: string }> }>(baseUrl, "/entries?source=voice_draft");
      expect(listed.entries).toHaveLength(1);
      expect(listed.entries[0]?.id).toBe(confirmed.entry.id);
      expect(listed.entries[0]?.source).toBe("voice_draft");

      const workoutSessionEntries = await request<{ entries: unknown[] }>(baseUrl, "/entries?source=workout_session");
      const after = await request<{ session: WorkoutSession }>(baseUrl, "/sessions/current");
      expect(workoutSessionEntries.entries).toHaveLength(0);
      expect(after.session.id).toBe(before.session.id);
      expect(after.session.status).toBe(before.session.status);
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("updates and discards Fox Say review drafts before confirmation", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    try {
      const capture = await createSayCapture(baseUrl);
      const { asrResult } = await createLinuxAsrResult(baseUrl, capture.id, "午饭花了四十二元，吃了鸡胸肉和米饭。");
      const { draft } = await request<{ draft: { id: string; status: string } }>(baseUrl, "/say/drafts", {
        method: "POST",
        body: JSON.stringify({ asrResultId: asrResult.id })
      });

      const updated = await request<{
        draft: {
          id: string;
          entryType: string;
          title: string;
          status: string;
          extractedJson: { amount?: number; currency?: string; notes?: string };
        };
      }>(baseUrl, `/say/drafts/${draft.id}`, {
        method: "PATCH",
        body: JSON.stringify({
          entryType: "expense",
          title: "午饭现金支出",
          extractedJson: {
            amount: 42,
            currency: "CNY",
            notes: "午饭：鸡胸肉和米饭"
          },
          extractionConfidence: 0.82
        })
      });

      expect(updated.draft.entryType).toBe("expense");
      expect(updated.draft.title).toBe("午饭现金支出");
      expect(updated.draft.status).toBe("needs_review");
      expect(updated.draft.extractedJson.amount).toBe(42);

      const confirmed = await request<{
        draft: { status: string; confirmedEntryId: string };
        entry: { kind: string; title: string; confirmedJson: { amount?: number; user_confirmation_status?: string } };
      }>(baseUrl, `/say/drafts/${draft.id}/confirm`, {
        method: "POST",
        body: JSON.stringify({
          confirmedJson: {
            ...updated.draft.extractedJson,
            user_confirmation_status: "confirmed"
          }
        })
      });

      expect(confirmed.draft.status).toBe("confirmed");
      expect(confirmed.entry.kind).toBe("expense");
      expect(confirmed.entry.title).toBe("午饭现金支出");
      expect(confirmed.entry.confirmedJson.amount).toBe(42);

      const patchConfirmed = await requestResponse(baseUrl, `/say/drafts/${draft.id}`, {
        method: "PATCH",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ status: "discarded" })
      });
      expect(patchConfirmed.status).toBe(409);

      const { asrResult: discardAsr } = await createLinuxAsrResult(baseUrl, capture.id, "这条只是测试，不需要入库。");
      const { draft: discardDraft } = await request<{ draft: { id: string } }>(baseUrl, "/say/drafts", {
        method: "POST",
        body: JSON.stringify({ asrResultId: discardAsr.id })
      });
      const discarded = await request<{ draft: { status: string } }>(baseUrl, `/say/drafts/${discardDraft.id}`, {
        method: "PATCH",
        body: JSON.stringify({ status: "discarded" })
      });
      expect(discarded.draft.status).toBe("discarded");

      const confirmDiscarded = await requestResponse(baseUrl, `/say/drafts/${discardDraft.id}/confirm`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}"
      });
      expect(confirmDiscarded.status).toBe(409);

      const entries = await request<{ entries: Array<{ source: string }> }>(baseUrl, "/entries?source=voice_draft");
      expect(entries.entries).toHaveLength(1);
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("runs Fox Say ASR for the latest capture through a server-side runner", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(
      createFoxServer({
        repository,
        aiProvider: createTemplateAiProvider(),
        asrRunner: {
          async runLatestCapture({ capture }) {
            repository.createVoiceAsrResult({
              captureId: String(capture.id),
              provider: "mock-linux-sensevoice",
              transcript: "这是当前录音的识别结果。",
              language: "zh-CN",
              confidence: 0.88,
              rawResult: { mock: true, raw_audio_committed: false }
            });
            return {
              ok: true,
              schema: "fox.say_linux_asr_runner_report.v0",
              decision: "linux_asr_transcript_posted_to_fox"
            };
          }
        }
      })
    );

    try {
      const capture = await createSayCapture(baseUrl, Buffer.from("fake-current-audio"));
      const response = await request<{
        report: { ok: boolean; decision: string };
        asrResult?: { captureId: string; provider: string; transcript: string };
      }>(baseUrl, "/say/asr/run-latest", {
        method: "POST",
        body: JSON.stringify({ captureId: capture.id })
      });

      expect(response.report.ok).toBe(true);
      expect(response.asrResult?.captureId).toBe(capture.id);
      expect(response.asrResult?.provider).toBe("mock-linux-sensevoice");
      expect(response.asrResult?.transcript).toBe("这是当前录音的识别结果。");
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("refuses to run Fox Say ASR when the requested capture is not latest", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(
      createFoxServer({
        repository,
        aiProvider: createTemplateAiProvider(),
        asrRunner: {
          async runLatestCapture() {
            throw new Error("runner_should_not_be_called");
          }
        }
      })
    );

    try {
      const oldCapture = await createSayCapture(baseUrl, Buffer.from("fake-old-audio"));
      const latestCapture = await createSayCapture(baseUrl, Buffer.from("fake-new-audio"));
      const response = await requestResponse(baseUrl, "/say/asr/run-latest", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ captureId: oldCapture.id })
      });

      expect(response.status).toBe(409);
      const payload = (await response.json()) as { error: string; latestCaptureId: string; requestedCaptureId: string };
      expect(payload.error).toBe("capture_is_not_latest");
      expect(payload.latestCaptureId).toBe(latestCapture.id);
      expect(payload.requestedCaptureId).toBe(oldCapture.id);
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("queues an ASR job for the requested capture and never substitutes a newer capture", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const runnerCaptures: string[] = [];
    const baseUrl = await listen(
      createFoxServer({
        repository,
        aiProvider: createTemplateAiProvider(),
        asrRunner: {
          async runCapture({ capture }) {
            const captureId = String(capture.id);
            runnerCaptures.push(captureId);
            const asrResult = repository.createVoiceAsrResult({
              captureId,
              provider: "mock-linux-sensevoice",
              transcript: `识别 ${captureId}`,
              language: "zh-CN",
              confidence: 0.9
            });
            return {
              ok: true,
              decision: "linux_asr_transcript_posted_to_fox",
              fox_api: { asr_result_id: asrResult.id, capture_id: captureId }
            };
          }
        }
      })
    );

    try {
      const firstCapture = await createSayCapture(baseUrl, Buffer.from("first-capture"));
      await createSayCapture(baseUrl, Buffer.from("newer-capture"));

      const queued = await request<{
        job: { id: string; captureId: string; status: string; asrResultId?: string };
        reused: boolean;
      }>(baseUrl, "/say/asr-jobs", {
        method: "POST",
        body: JSON.stringify({ captureId: firstCapture.id })
      });

      expect(queued.job.captureId).toBe(firstCapture.id);
      expect(queued.reused).toBe(false);

      const completed = await waitFor(
        () => request<{ job: { captureId: string; status: string; asrResultId?: string }; asrResult?: { captureId: string; transcript: string } }>(baseUrl, `/say/asr-jobs/${queued.job.id}`),
        (payload) => payload.job.status === "succeeded"
      );
      expect(completed.job.captureId).toBe(firstCapture.id);
      expect(completed.asrResult?.captureId).toBe(firstCapture.id);
      expect(completed.asrResult?.transcript).toContain(firstCapture.id);
      expect(runnerCaptures).toEqual([firstCapture.id]);

      const entries = await request<{ entries: unknown[] }>(baseUrl, "/entries?source=voice_draft");
      expect(entries.entries).toHaveLength(0);
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("reuses an active ASR job and exposes a failed job as retryable evidence", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    let releaseRunner: (() => void) | undefined;
    const holdRunner = new Promise<void>((resolveHold) => {
      releaseRunner = resolveHold;
    });
    let runnerCalls = 0;
    const baseUrl = await listen(
      createFoxServer({
        repository,
        aiProvider: createTemplateAiProvider(),
        asrRunner: {
          async runCapture({ capture }) {
            runnerCalls += 1;
            await holdRunner;
            throw new Error(`mock_linux_unavailable_${String(capture.id)}`);
          }
        }
      })
    );

    try {
      const capture = await createSayCapture(baseUrl);
      const first = await request<{ job: { id: string; status: string; attempt: number }; reused: boolean }>(baseUrl, "/say/asr-jobs", {
        method: "POST",
        body: JSON.stringify({ captureId: capture.id })
      });
      const duplicate = await request<{ job: { id: string; status: string; attempt: number }; reused: boolean }>(baseUrl, "/say/asr-jobs", {
        method: "POST",
        body: JSON.stringify({ captureId: capture.id })
      });

      expect(duplicate.job.id).toBe(first.job.id);
      expect(duplicate.reused).toBe(true);
      expect(duplicate.job.attempt).toBe(1);
      releaseRunner?.();

      const failed = await waitFor(
        () => request<{ job: { id: string; status: string; errorCode?: string; errorMessage?: string } }>(baseUrl, `/say/asr-jobs/${first.job.id}`),
        (payload) => payload.job.status === "failed"
      );
      expect(failed.job.errorCode).toBe("asr_runner_failed");
      expect(failed.job.errorMessage).toContain("mock_linux_unavailable");
      expect(runnerCalls).toBe(1);

      const retry = await request<{ job: { id: string; attempt: number }; reused: boolean }>(baseUrl, "/say/asr-jobs", {
        method: "POST",
        body: JSON.stringify({ captureId: capture.id })
      });
      expect(retry.job.id).not.toBe(first.job.id);
      expect(retry.reused).toBe(false);
      expect(retry.job.attempt).toBe(2);
    } finally {
      releaseRunner?.();
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

  it("queues a Mac clipboard job without exposing its text to LAN clients or mutating Fox", async () => {
    const { dir, repository } = createTempRepository();
    const previousCaptureDir = process.env.FOX_SAY_CAPTURE_DIR;
    process.env.FOX_SAY_CAPTURE_DIR = join(dir, "say-captures");
    const baseUrl = await listen(createFoxServer({ repository, aiProvider: createTemplateAiProvider() }));

    try {
      const before = await request<{ session: WorkoutSession }>(baseUrl, "/sessions/current");
      const capture = await createSayCapture(baseUrl);
      const { asrResult } = await createLinuxAsrResult(baseUrl, capture.id, "把这句话送到 Mac 剪贴板。");

      const queued = await request<{
        job: { id: string; asrResultId: string; captureId: string; status: string; textCharacters: number; textSha256: string };
        reused: boolean;
      }>(baseUrl, `/say/asr-results/${asrResult.id}/mac-input-jobs`, {
        method: "POST",
        body: JSON.stringify({ target: "clipboard" })
      });
      expect(queued.job.asrResultId).toBe(asrResult.id);
      expect(queued.job.captureId).toBe(capture.id);
      expect(queued.job.status).toBe("queued");
      expect(queued.job.textCharacters).toBe(asrResult.transcript.length);
      expect(queued.job.textSha256).toMatch(/^[a-f0-9]{64}$/);

      const duplicate = await request<{ job: { id: string }; reused: boolean }>(baseUrl, `/say/asr-results/${asrResult.id}/mac-input-jobs`, {
        method: "POST",
        body: JSON.stringify({ target: "clipboard" })
      });
      expect(duplicate.job.id).toBe(queued.job.id);
      expect(duplicate.reused).toBe(true);

      const listed = await request<{ jobs: Array<Record<string, unknown>> }>(baseUrl, `/say/mac-input-jobs?asrResultId=${asrResult.id}`);
      expect(JSON.stringify(listed.jobs)).not.toContain(asrResult.transcript);
      expect(listed.jobs[0]?.status).toBe("queued");

      const claimedResponse = await requestResponse(baseUrl, "/say/mac-input-jobs/next");
      expect(claimedResponse.status).toBe(200);
      const claimed = (await claimedResponse.json()) as { job: { id: string; status: string }; text: string };
      expect(claimed.job.id).toBe(queued.job.id);
      expect(claimed.job.status).toBe("claimed");
      expect(claimed.text).toBe(asrResult.transcript);

      const completed = await request<{ job: { status: string; completedAt?: string } }>(baseUrl, `/say/mac-input-jobs/${queued.job.id}/complete`, {
        method: "POST",
        body: "{}"
      });
      expect(completed.job.status).toBe("completed");
      expect(completed.job.completedAt).toBeTruthy();

      const entries = await request<{ entries: unknown[] }>(baseUrl, "/entries?source=voice_draft");
      const after = await request<{ session: WorkoutSession }>(baseUrl, "/sessions/current");
      expect(entries.entries).toHaveLength(0);
      expect(after.session.id).toBe(before.session.id);
      expect(after.session.status).toBe(before.session.status);
    } finally {
      if (previousCaptureDir === undefined) {
        delete process.env.FOX_SAY_CAPTURE_DIR;
      } else {
        process.env.FOX_SAY_CAPTURE_DIR = previousCaptureDir;
      }
    }
  });

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
