import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { execFile } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { apiListenOptions, isUserProfile, readJson, RequestError, requestErrorStatus, requestUrl } from "./request-policy.js";
import {
  createSession,
  createTemplateAiProvider,
  draftAdjustmentSuggestionWithFallback,
  draftFeedbackOptionsWithFallback,
  draftPlanWithFallback
} from "@fox/core";
import type { AiProvider, DailyCheckIn, EquipmentInventory, ExerciseHistorySnapshot, FeedbackKind, UserProfile, WorkoutEvent } from "@fox/core";
import {
  createWorkoutRepository,
  defaultDatabasePath,
  type EntryKind,
  type EntryRecord,
  type EntrySource,
  type EvidenceItem,
  type WorkoutRepository
} from "./repository.js";

const { port, host } = apiListenOptions();
const maxSayCaptureBytes = 12 * 1024 * 1024;
const sayCorpusBuckets = new Set(["short_command", "training_feedback", "equipment_context", "mixed_utterance", "noise_distance"]);
const entryKinds = new Set<EntryKind>(["meal", "medical", "workout", "expense", "note"]);
const entrySources = new Set<EntrySource>(["workout_session", "voice_draft"]);

export interface FoxServerDependencies {
  repository: WorkoutRepository;
  aiProvider: AiProvider;
  asrRunner?: FoxSayAsrRunner;
}

export interface FoxSayAsrRunner {
  runCapture?: (input: { apiUrl: string; capture: Record<string, unknown> }) => Promise<Record<string, unknown>>;
  /** @deprecated Kept for older test runners and handoff scripts. */
  runLatestCapture?: (input: { apiUrl: string; capture: Record<string, unknown> }) => Promise<Record<string, unknown>>;
}

interface FoxSayRuntime {
  enqueueAsrJob: (jobId: string, apiUrl: string) => void;
}

export function createDefaultDependencies(): FoxServerDependencies {
  return {
    repository: createWorkoutRepository(process.env.FOX_DB_PATH ?? defaultDatabasePath()),
    aiProvider: createTemplateAiProvider(),
    asrRunner: createCliFoxSayAsrRunner()
  };
}

function sendJson(response: ServerResponse, status: number, payload: unknown): void {
  response.writeHead(status, { "content-type": "application/json" });
  response.end(JSON.stringify(payload));
}

function sendBinary(response: ServerResponse, status: number, contentType: string, payload: Buffer): void {
  response.writeHead(status, { "content-type": contentType, "content-length": payload.byteLength });
  response.end(payload);
}

function readBinary(request: IncomingMessage, maxBytes = maxSayCaptureBytes): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let total = 0;
    request.on("data", (chunk: Buffer) => {
      total += chunk.byteLength;
      if (total > maxBytes) {
        reject(new Error("request_too_large"));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on("end", () => resolve(Buffer.concat(chunks)));
    request.on("error", reject);
  });
}

function sayCaptureRoot(): string {
  return process.env.FOX_SAY_CAPTURE_DIR ?? join(process.cwd(), ".tmp", "fox-say-captures");
}

function sayCorpusRoot(): string {
  return process.env.FOX_SAY_CORPUS_DIR ?? join(process.cwd(), ".tmp", "fox-say-corpus");
}

function safeCaptureId(id: string): string | null {
  return /^[A-Za-z0-9_-]{8,80}$/.test(id) ? id : null;
}

function safeRecordId(id: string): string | null {
  return /^[A-Za-z0-9_-]{8,100}$/.test(id) ? id : null;
}

function asEntryKind(value: unknown): EntryKind | null {
  const kind = String(value ?? "");
  return entryKinds.has(kind as EntryKind) ? (kind as EntryKind) : null;
}

function asEntrySource(value: unknown): EntrySource | null {
  const source = String(value ?? "");
  return entrySources.has(source as EntrySource) ? (source as EntrySource) : null;
}

function captureContentType(request: IncomingMessage): string {
  const header = request.headers["content-type"];
  if (typeof header !== "string") {
    return "application/octet-stream";
  }
  return header.split(";")[0]?.trim() || "application/octet-stream";
}

function captureExtension(contentType: string): string {
  if (contentType.includes("webm")) {
    return "webm";
  }
  if (contentType.includes("wav")) {
    return "wav";
  }
  if (contentType.includes("mp4") || contentType.includes("m4a")) {
    return "m4a";
  }
  return "bin";
}

function captureMetadataPath(id: string): string {
  return join(sayCaptureRoot(), `${id}.json`);
}

function latestCapturePath(): string {
  return join(sayCaptureRoot(), "latest.json");
}

function readLatestCaptureMetadata(): Record<string, unknown> | null {
  try {
    return JSON.parse(readFileSync(latestCapturePath(), "utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
}

function saveSayCapture(payload: Buffer, contentType: string): Record<string, unknown> {
  if (payload.byteLength === 0) {
    throw new Error("empty_capture");
  }
  const root = sayCaptureRoot();
  mkdirSync(root, { recursive: true });
  const id = `say_${Date.now()}_${randomUUID().slice(0, 8)}`;
  const extension = captureExtension(contentType);
  const audioPath = join(root, `${id}.${extension}`);
  writeFileSync(audioPath, payload);
  const sha256 = createHash("sha256").update(payload).digest("hex");
  const metadata = {
    ok: true,
    schema: "fox.say_capture.v0",
    id,
    contentType,
    bytes: payload.byteLength,
    sha256,
    audioPath,
    audioPathShape: basename(audioPath),
    capturedAt: new Date().toISOString(),
    source: "fox-say-web-runtime",
    rawAudioCommitted: false
  };
  writeFileSync(captureMetadataPath(id), JSON.stringify(metadata, null, 2));
  writeFileSync(latestCapturePath(), JSON.stringify(metadata, null, 2));
  return metadata;
}

function readCaptureMetadata(id: string): Record<string, unknown> | null {
  try {
    return JSON.parse(readFileSync(captureMetadataPath(id), "utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
}

function repoRoot(): string {
  return resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
}

function parseJsonObject(output: string, label: string): Record<string, unknown> {
  const trimmed = output.trim();
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error(`${label}_missing_json`);
  }
  const parsed = JSON.parse(trimmed.slice(start, end + 1));
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`${label}_invalid_json`);
  }
  return parsed as Record<string, unknown>;
}

function createCliFoxSayAsrRunner(): FoxSayAsrRunner {
  return {
    runCapture({ apiUrl, capture }) {
      return new Promise((resolveRunner, rejectRunner) => {
        const root = repoRoot();
        execFile(
          process.execPath,
          [join(root, "scripts", "fox-say-linux-asr-runner.mjs")],
          {
            cwd: root,
            env: {
              ...process.env,
              FOX_API_URL: apiUrl,
              FOX_SAY_CAPTURE_ID: String(capture.id ?? "")
            },
            timeout: Number(process.env.FOX_SAY_LINUX_ASR_HTTP_TIMEOUT_MS ?? 240_000),
            maxBuffer: 4 * 1024 * 1024
          },
          (error, stdout, stderr) => {
            if (error) {
              rejectRunner(new Error(`${error.message}${stderr ? `\n${stderr}` : ""}`));
              return;
            }
            try {
              resolveRunner(parseJsonObject(stdout, "fox_say_linux_asr_runner"));
            } catch (parseError) {
              rejectRunner(parseError);
            }
          }
        );
      });
    }
  };
}

async function runFoxSayAsrRunner(runner: FoxSayAsrRunner, input: { apiUrl: string; capture: Record<string, unknown> }): Promise<Record<string, unknown>> {
  if (runner.runCapture) {
    return runner.runCapture(input);
  }
  if (runner.runLatestCapture) {
    return runner.runLatestCapture(input);
  }
  throw new Error("asr_runner_not_configured");
}

function asrResultIdFromRunnerReport(report: Record<string, unknown>): string | null {
  const foxApi = report.fox_api;
  if (!foxApi || typeof foxApi !== "object" || Array.isArray(foxApi)) {
    return null;
  }
  return safeRecordId(String((foxApi as Record<string, unknown>).asr_result_id ?? ""));
}

function apiUrlForRequest(url: URL): string {
  return process.env.FOX_SAY_CALLBACK_API_URL ?? `${url.protocol}//${url.host}`;
}

function isLoopbackRequest(request: IncomingMessage): boolean {
  const address = request.socket.remoteAddress?.replace(/^::ffff:/, "");
  return address === "127.0.0.1" || address === "::1";
}

function createFoxSayRuntime(dependencies: FoxServerDependencies): FoxSayRuntime {
  const callbackUrls = new Map<string, string>();
  let workerRunning = false;

  const drainAsrJobs = async (): Promise<void> => {
    if (workerRunning) {
      return;
    }
    workerRunning = true;
    try {
      while (true) {
        const job = dependencies.repository.claimNextVoiceAsrJob();
        if (!job) {
          return;
        }
        try {
          const capture = readCaptureMetadata(job.captureId);
          if (!capture) {
            dependencies.repository.failVoiceAsrJob(job.id, "capture_not_found", "The capture is no longer available to the ASR worker.");
            continue;
          }
          const apiUrl = process.env.FOX_SAY_CALLBACK_API_URL ?? callbackUrls.get(job.id) ?? `http://127.0.0.1:${port}`;
          const report = await runFoxSayAsrRunner(dependencies.asrRunner ?? createCliFoxSayAsrRunner(), { apiUrl, capture });
          if (report.ok !== true) {
            throw new Error(`asr_runner_report_not_ok: ${JSON.stringify(report)}`);
          }
          const currentJob = dependencies.repository.getVoiceAsrJob(job.id);
          if (currentJob?.status === "succeeded") {
            continue;
          }
          const asrResultId = asrResultIdFromRunnerReport(report);
          if (!asrResultId) {
            throw new Error("asr_runner_did_not_report_result_id");
          }
          dependencies.repository.succeedVoiceAsrJob(job.id, asrResultId);
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error);
          dependencies.repository.failVoiceAsrJob(job.id, "asr_runner_failed", message);
        } finally {
          callbackUrls.delete(job.id);
        }
      }
    } finally {
      workerRunning = false;
    }
  };

  return {
    enqueueAsrJob(jobId, apiUrl) {
      callbackUrls.set(jobId, apiUrl);
      queueMicrotask(() => {
        void drainAsrJobs();
      });
    }
  };
}

function corpusSamplePath(sampleId: string): string {
  return join(sayCorpusRoot(), `${sampleId}.json`);
}

function safeCorpusSampleId(id: string): string | null {
  return /^fox-say-\d{4,6}$/.test(id) ? id : null;
}

function listCorpusSamples(): Array<Record<string, unknown>> {
  try {
    return readdirSync(sayCorpusRoot())
      .filter((name) => /^fox-say-\d{4,6}\.json$/.test(name))
      .map((name) => JSON.parse(readFileSync(join(sayCorpusRoot(), name), "utf8")) as Record<string, unknown>)
      .sort((left, right) => String(right.createdAt ?? "").localeCompare(String(left.createdAt ?? "")));
  } catch {
    return [];
  }
}

function nextCorpusSampleId(): string {
  const max = listCorpusSamples().reduce((largest, sample) => {
    const match = String(sample.sampleId ?? sample.sample_id ?? "").match(/^fox-say-(\d{4,6})$/);
    return match?.[1] ? Math.max(largest, Number(match[1])) : largest;
  }, 0);
  return `fox-say-${String(max + 1).padStart(4, "0")}`;
}

function corpusSummary(samples: Array<Record<string, unknown>>): Record<string, unknown> {
  const buckets: Record<string, number> = {};
  for (const sample of samples) {
    const bucket = String(sample.bucket ?? "unknown");
    buckets[bucket] = (buckets[bucket] ?? 0) + 1;
  }
  return {
    schema: "fox.say_corpus_summary.v0",
    total: samples.length,
    buckets
  };
}

function saveCorpusSample(body: Record<string, unknown>): Record<string, unknown> {
  const captureId = safeCaptureId(String(body.captureId ?? body.capture_id ?? ""));
  if (!captureId) {
    throw new Error("invalid_capture_id");
  }
  const capture = readCaptureMetadata(captureId);
  if (!capture) {
    throw new Error("capture_not_found");
  }

  const bucket = String(body.bucket ?? "");
  if (!sayCorpusBuckets.has(bucket)) {
    throw new Error("invalid_bucket");
  }

  const expectedText = String(body.expectedText ?? body.expected_text ?? "").trim();
  if (!expectedText) {
    throw new Error("expected_text_required");
  }

  const sampleIdInput = body.sampleId ?? body.sample_id;
  const sampleId =
    typeof sampleIdInput === "string" && sampleIdInput.trim()
      ? safeCorpusSampleId(sampleIdInput.trim())
      : nextCorpusSampleId();
  if (!sampleId) {
    throw new Error("invalid_sample_id");
  }

  const now = new Date().toISOString();
  const audioPathShape = String(capture.audioPathShape ?? "");
  const sample = {
    ok: true,
    schema: "fox.say_corpus_sample.v0",
    sampleId,
    sample_id: sampleId,
    bucket,
    expectedText,
    expected_text: expectedText,
    captureId,
    capture_id: captureId,
    audioPath: `runtime-only/${audioPathShape}`,
    audio_path: `runtime-only/${audioPathShape}`,
    audioPathShape,
    audio_path_shape: audioPathShape,
    contentType: capture.contentType,
    content_type: capture.contentType,
    bytes: capture.bytes,
    sha256: capture.sha256,
    device: String(body.device ?? "iPad"),
    environment: String(body.environment ?? "unknown").trim() || "unknown",
    noiseNotes: String(body.noiseNotes ?? body.noise_notes ?? "").trim(),
    noise_notes: String(body.noiseNotes ?? body.noise_notes ?? "").trim(),
    speakerProfile: String(body.speakerProfile ?? body.speaker_profile ?? "owner").trim() || "owner",
    speaker_profile: String(body.speakerProfile ?? body.speaker_profile ?? "owner").trim() || "owner",
    createdAt: now,
    created_at: now,
    capturedAt: capture.capturedAt,
    captured_at: capture.capturedAt,
    rawAudioCommitted: false,
    raw_audio_committed: false
  };

  mkdirSync(sayCorpusRoot(), { recursive: true });
  writeFileSync(corpusSamplePath(sampleId), JSON.stringify(sample, null, 2));
  const samples = listCorpusSamples();
  writeFileSync(join(sayCorpusRoot(), "index.json"), JSON.stringify({ schema: "fox.say_corpus_index.v0", samples }, null, 2));
  writeFileSync(join(sayCorpusRoot(), "latest.json"), JSON.stringify(sample, null, 2));
  return sample;
}

function inferEntryTypeFromTranscript(transcript: string): EntryKind {
  if (/[¥￥฿$]\s?\d|\d+(\.\d+)?\s?(元|块|人民币|泰铢|美元|usd|thb|cny)/i.test(transcript) || /花了|买了|付款|现金|转账/.test(transcript)) {
    return "expense";
  }
  if (/医生|处方|药|用药|剂量|复诊|医院|诊所/.test(transcript)) {
    return "medical";
  }
  if (/早餐|午餐|晚餐|吃了|喝了|卡路里|热量|蛋白|碳水|脂肪/.test(transcript)) {
    return "meal";
  }
  if (/训练|健身|跑步|游泳|哑铃|卧推|硬拉|深蹲|平板支撑|组|次数|配速|公里|kg|千克/.test(transcript)) {
    return "workout";
  }
  return "note";
}

function titleForVoiceDraft(kind: EntryKind, transcript: string): string {
  const prefix: Record<EntryKind, string> = {
    meal: "语音饮食记录",
    medical: "语音医疗记录",
    workout: "语音训练记录",
    expense: "语音记账记录",
    note: "语音笔记"
  };
  const compact = transcript.replace(/\s+/g, " ").trim();
  return compact ? `${prefix[kind]}：${compact.slice(0, 18)}` : prefix[kind];
}

function extractAmount(transcript: string): number | undefined {
  const match = transcript.match(/(\d+(?:\.\d+)?)\s?(?:元|块|人民币|泰铢|美元|usd|thb|cny|฿|\$)/i);
  return match?.[1] ? Number(match[1]) : undefined;
}

function draftJsonForVoice(kind: EntryKind, transcript: string): Record<string, unknown> {
  if (kind === "workout") {
    return {
      status: "completed",
      user_confirmation_status: "unconfirmed",
      notes: transcript
    };
  }
  if (kind === "expense") {
    return {
      amount: extractAmount(transcript),
      currency: /泰铢|thb|฿/i.test(transcript) ? "THB" : undefined,
      notes: transcript
    };
  }
  if (kind === "meal") {
    return {
      notes: transcript,
      items: []
    };
  }
  if (kind === "medical") {
    return {
      doctor_notes: transcript,
      source_type: "note"
    };
  }
  return {
    notes: transcript
  };
}

function evidenceForCapture(capture: Record<string, unknown>, captureId: string): EvidenceItem[] {
  return [
    {
      id: `evidence_${captureId}`,
      kind: "audio",
      uri: `fox-say-capture:${captureId}`,
      mimeType: typeof capture.contentType === "string" ? capture.contentType : undefined,
      sha256: typeof capture.sha256 === "string" ? capture.sha256 : undefined,
      createdAt: typeof capture.capturedAt === "string" ? capture.capturedAt : new Date().toISOString()
    }
  ];
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

export async function route(request: IncomingMessage, response: ServerResponse, dependencies: FoxServerDependencies, runtime: FoxSayRuntime): Promise<void> {
  const { repository, aiProvider } = dependencies;
  const url = requestUrl(request, response);
  const pathname = url.pathname.replace(/^\/api/, "") || "/";

  if (request.method === "OPTIONS") {
    response.writeHead(204);
    response.end();
    return;
  }

  if (request.method === "GET" && pathname === "/health") {
    sendJson(response, 200, { ok: true, service: "fox-api" });
    return;
  }

  if (request.method === "POST" && pathname === "/say/capture") {
    try {
      const payload = await readBinary(request);
      sendJson(response, 201, { capture: saveSayCapture(payload, captureContentType(request)) });
    } catch (error) {
      const message = error instanceof Error ? error.message : "capture_failed";
      sendJson(response, message === "request_too_large" ? 413 : 400, { error: message });
    }
    return;
  }

  if (request.method === "GET" && pathname === "/say/captures/latest") {
    try {
      sendJson(response, 200, { capture: JSON.parse(readFileSync(latestCapturePath(), "utf8")) });
    } catch {
      sendJson(response, 404, { error: "capture_not_found" });
    }
    return;
  }

  const captureMetadataMatch = pathname.match(/^\/say\/captures\/([^/]+)$/);
  if (request.method === "GET" && captureMetadataMatch) {
    const id = safeCaptureId(captureMetadataMatch[1] ?? "");
    const capture = id ? readCaptureMetadata(id) : null;
    if (!capture) {
      sendJson(response, 404, { error: "capture_not_found" });
      return;
    }
    sendJson(response, 200, { capture });
    return;
  }

  const captureAudioMatch = pathname.match(/^\/say\/captures\/([^/]+)\/audio$/);
  if (request.method === "GET" && captureAudioMatch) {
    const id = safeCaptureId(captureAudioMatch[1] ?? "");
    if (!id) {
      sendJson(response, 400, { error: "invalid_capture_id" });
      return;
    }
    const metadata = readCaptureMetadata(id);
    const audioPath = typeof metadata?.audioPath === "string" ? metadata.audioPath : "";
    if (!metadata || !audioPath) {
      sendJson(response, 404, { error: "capture_not_found" });
      return;
    }
    try {
      statSync(audioPath);
      sendBinary(response, 200, String(metadata.contentType ?? "application/octet-stream"), readFileSync(audioPath));
    } catch {
      sendJson(response, 404, { error: "capture_audio_not_found" });
    }
    return;
  }

  if (request.method === "GET" && pathname === "/say/corpus-samples") {
    const samples = listCorpusSamples();
    sendJson(response, 200, { schema: "fox.say_corpus_samples_response.v0", samples, summary: corpusSummary(samples) });
    return;
  }

  if (request.method === "POST" && pathname === "/say/corpus-samples") {
    try {
      const sample = saveCorpusSample(await readJson<Record<string, unknown>>(request));
      sendJson(response, 201, { sample, summary: corpusSummary(listCorpusSamples()) });
    } catch (error) {
      if (error instanceof RequestError) throw error;
      const message = error instanceof Error ? error.message : "corpus_sample_failed";
      const status = message === "capture_not_found" ? 404 : 400;
      sendJson(response, status, { error: message });
    }
    return;
  }

  if (request.method === "GET" && pathname === "/say/asr-results/latest") {
    const captureId = url.searchParams.get("captureId") ?? undefined;
    const results = repository.listVoiceAsrResults(captureId);
    const asrResult = results[0];
    if (!asrResult) {
      sendJson(response, 404, { error: "asr_result_not_found" });
      return;
    }
    sendJson(response, 200, { asrResult });
    return;
  }

  if (request.method === "POST" && pathname === "/say/asr-jobs") {
    try {
      const body = await readJson<Record<string, unknown>>(request);
      const captureId = safeCaptureId(String(body.captureId ?? body.capture_id ?? ""));
      if (!captureId) {
        sendJson(response, 400, { error: "invalid_capture_id" });
        return;
      }
      if (!readCaptureMetadata(captureId)) {
        sendJson(response, 404, { error: "capture_not_found" });
        return;
      }
      const queued = repository.createOrReuseVoiceAsrJob(captureId);
      sendJson(response, 202, queued);
      runtime.enqueueAsrJob(queued.job.id, apiUrlForRequest(url));
    } catch (error) {
      if (error instanceof RequestError) throw error;
      const message = error instanceof Error ? error.message : "asr_job_enqueue_failed";
      sendJson(response, 400, { error: message });
    }
    return;
  }

  if (request.method === "GET" && pathname === "/say/asr-jobs") {
    const captureIdInput = url.searchParams.get("captureId") ?? url.searchParams.get("capture_id") ?? "";
    const captureId = captureIdInput ? safeCaptureId(captureIdInput) : null;
    if (captureIdInput && !captureId) {
      sendJson(response, 400, { error: "invalid_capture_id" });
      return;
    }
    sendJson(response, 200, { jobs: repository.listVoiceAsrJobs(captureId ?? undefined) });
    return;
  }

  const asrJobMatch = pathname.match(/^\/say\/asr-jobs\/([^/]+)$/);
  if (request.method === "GET" && asrJobMatch) {
    const jobId = safeRecordId(asrJobMatch[1] ?? "");
    const job = jobId ? repository.getVoiceAsrJob(jobId) : null;
    if (!job) {
      sendJson(response, 404, { error: "asr_job_not_found" });
      return;
    }
    const asrResult = job.asrResultId ? repository.getVoiceAsrResult(job.asrResultId) : undefined;
    sendJson(response, 200, { job, ...(asrResult ? { asrResult } : {}) });
    return;
  }

  if (request.method === "POST" && pathname === "/say/asr/run-latest") {
    try {
      const body = await readJson<Record<string, unknown>>(request);
      const requestedCaptureIdInput = String(body.captureId ?? body.capture_id ?? "").trim();
      const requestedCaptureId = requestedCaptureIdInput ? safeCaptureId(requestedCaptureIdInput) : null;
      if (requestedCaptureIdInput && !requestedCaptureId) {
        sendJson(response, 400, { error: "invalid_capture_id" });
        return;
      }

      const latestCapture = readLatestCaptureMetadata();
      if (!latestCapture) {
        sendJson(response, 404, { error: "capture_not_found" });
        return;
      }
      if (requestedCaptureId && String(latestCapture.id ?? "") !== requestedCaptureId) {
        sendJson(response, 409, {
          error: "capture_is_not_latest",
          latestCaptureId: latestCapture.id,
          requestedCaptureId
        });
        return;
      }

      const apiUrl = `${url.protocol}//${url.host}`;
      const report = await runFoxSayAsrRunner(dependencies.asrRunner ?? createCliFoxSayAsrRunner(), {
        apiUrl,
        capture: latestCapture
      });
      if (report.ok !== true) {
        sendJson(response, 502, { error: "linux_asr_runner_failed", report });
        return;
      }

      const captureId = String(requestedCaptureId ?? latestCapture.id ?? "");
      const asrResult = repository.listVoiceAsrResults(captureId)[0];
      sendJson(response, 200, { report, asrResult });
    } catch (error) {
      if (error instanceof RequestError) throw error;
      const message = error instanceof Error ? error.message : "linux_asr_runner_failed";
      sendJson(response, 502, { error: message });
    }
    return;
  }

  if (request.method === "POST" && pathname === "/say/asr-results") {
    try {
      const body = await readJson<Record<string, unknown>>(request);
      const captureId = safeCaptureId(String(body.captureId ?? body.capture_id ?? ""));
      if (!captureId) {
        sendJson(response, 400, { error: "invalid_capture_id" });
        return;
      }
      if (!readCaptureMetadata(captureId)) {
        sendJson(response, 404, { error: "capture_not_found" });
        return;
      }
      const transcript = String(body.transcript ?? "").trim();
      if (!transcript) {
        sendJson(response, 400, { error: "transcript_required" });
        return;
      }
      const provider = String(body.provider ?? "").trim() || "linux-asr";
      const confidence = typeof body.confidence === "number" && Number.isFinite(body.confidence) ? Math.max(0, Math.min(1, body.confidence)) : undefined;
      const asrResult = repository.createVoiceAsrResult({
        captureId,
        provider,
        transcript,
        language: typeof body.language === "string" ? body.language : undefined,
        confidence,
        segments: body.segments,
        rawResult: body.rawResult ?? body.raw_result
      });
      repository.succeedActiveVoiceAsrJobForCapture(captureId, asrResult.id);
      sendJson(response, 201, { asrResult });
    } catch (error) {
      if (error instanceof RequestError) throw error;
      const message = error instanceof Error ? error.message : "asr_result_failed";
      sendJson(response, 400, { error: message });
    }
    return;
  }

  const asrMacInputMatch = pathname.match(/^\/say\/asr-results\/([^/]+)\/mac-input-jobs$/);
  if (request.method === "POST" && asrMacInputMatch) {
    const asrResultId = safeRecordId(asrMacInputMatch[1] ?? "");
    const asrResult = asrResultId ? repository.getVoiceAsrResult(asrResultId) : null;
    if (!asrResult) {
      sendJson(response, 404, { error: "asr_result_not_found" });
      return;
    }
    try {
      const body = await readJson<Record<string, unknown>>(request);
      const requestedTarget = body.target === undefined ? "clipboard" : String(body.target);
      if (requestedTarget !== "clipboard") {
        sendJson(response, 400, { error: "invalid_mac_input_target" });
        return;
      }
      const queued = repository.createOrReuseVoiceMacInputJob({
        asrResultId: asrResult.id,
        captureId: asrResult.captureId,
        text: asrResult.transcript,
        target: "clipboard"
      });
      sendJson(response, queued.reused ? 200 : 201, queued);
    } catch (error) {
      if (error instanceof RequestError) throw error;
      const message = error instanceof Error ? error.message : "mac_input_job_enqueue_failed";
      sendJson(response, 400, { error: message });
    }
    return;
  }

  if (request.method === "GET" && pathname === "/say/mac-input-jobs") {
    const asrResultIdInput = url.searchParams.get("asrResultId") ?? url.searchParams.get("asr_result_id") ?? "";
    const asrResultId = asrResultIdInput ? safeRecordId(asrResultIdInput) : null;
    if (asrResultIdInput && !asrResultId) {
      sendJson(response, 400, { error: "invalid_asr_result_id" });
      return;
    }
    sendJson(response, 200, { jobs: repository.listVoiceMacInputJobs(asrResultId ?? undefined) });
    return;
  }

  if (request.method === "GET" && pathname === "/say/mac-input-jobs/next") {
    if (!isLoopbackRequest(request)) {
      sendJson(response, 403, { error: "mac_bridge_local_only" });
      return;
    }
    const claimed = repository.claimNextVoiceMacInputJob();
    if (!claimed) {
      response.writeHead(204);
      response.end();
      return;
    }
    sendJson(response, 200, claimed);
    return;
  }

  const macInputCompleteMatch = pathname.match(/^\/say\/mac-input-jobs\/([^/]+)\/complete$/);
  if (request.method === "POST" && macInputCompleteMatch) {
    if (!isLoopbackRequest(request)) {
      sendJson(response, 403, { error: "mac_bridge_local_only" });
      return;
    }
    const jobId = safeRecordId(macInputCompleteMatch[1] ?? "");
    const existing = jobId ? repository.getVoiceMacInputJob(jobId) : null;
    if (!existing) {
      sendJson(response, 404, { error: "mac_input_job_not_found" });
      return;
    }
    if (existing.status !== "claimed" && existing.status !== "completed") {
      sendJson(response, 409, { error: "mac_input_job_not_claimed", job: existing });
      return;
    }
    sendJson(response, 200, { job: repository.completeVoiceMacInputJob(existing.id) });
    return;
  }

  const macInputFailMatch = pathname.match(/^\/say\/mac-input-jobs\/([^/]+)\/fail$/);
  if (request.method === "POST" && macInputFailMatch) {
    if (!isLoopbackRequest(request)) {
      sendJson(response, 403, { error: "mac_bridge_local_only" });
      return;
    }
    const jobId = safeRecordId(macInputFailMatch[1] ?? "");
    const existing = jobId ? repository.getVoiceMacInputJob(jobId) : null;
    if (!existing) {
      sendJson(response, 404, { error: "mac_input_job_not_found" });
      return;
    }
    if (existing.status === "completed" || existing.status === "failed") {
      sendJson(response, 409, { error: "mac_input_job_terminal", job: existing });
      return;
    }
    const body = await readJson<Record<string, unknown>>(request);
    const errorCode = String(body.errorCode ?? body.error_code ?? "mac_clipboard_failed").slice(0, 120);
    const errorMessage = typeof body.errorMessage === "string" ? body.errorMessage : typeof body.error_message === "string" ? body.error_message : undefined;
    sendJson(response, 200, { job: repository.failVoiceMacInputJob(existing.id, errorCode, errorMessage) });
    return;
  }

  if (request.method === "GET" && pathname === "/say/drafts") {
    sendJson(response, 200, { drafts: repository.listVoiceDrafts() });
    return;
  }

  if (request.method === "POST" && pathname === "/say/drafts") {
    try {
      const body = await readJson<Record<string, unknown>>(request);
      const asrResultId = safeRecordId(String(body.asrResultId ?? body.asr_result_id ?? ""));
      if (!asrResultId) {
        sendJson(response, 400, { error: "invalid_asr_result_id" });
        return;
      }
      const asrResult = repository.getVoiceAsrResult(asrResultId);
      if (!asrResult) {
        sendJson(response, 404, { error: "asr_result_not_found" });
        return;
      }
      const capture = readCaptureMetadata(asrResult.captureId);
      if (!capture) {
        sendJson(response, 404, { error: "capture_not_found" });
        return;
      }
      const explicitKind = asEntryKind(body.entryType ?? body.entry_type);
      const entryType = explicitKind ?? inferEntryTypeFromTranscript(asrResult.transcript);
      const extractedJson =
        body.extractedJson && typeof body.extractedJson === "object"
          ? (body.extractedJson as Record<string, unknown>)
          : draftJsonForVoice(entryType, asrResult.transcript);
      const extractionConfidence =
        typeof body.extractionConfidence === "number" && Number.isFinite(body.extractionConfidence)
          ? Math.max(0, Math.min(1, body.extractionConfidence))
          : asrResult.confidence ?? 0.6;
      const draft = repository.createVoiceDraft({
        asrResultId: asrResult.id,
        captureId: asrResult.captureId,
        entryType,
        title: String(body.title ?? "").trim() || titleForVoiceDraft(entryType, asrResult.transcript),
        rawText: asrResult.transcript,
        evidence: evidenceForCapture(capture, asrResult.captureId),
        extractedJson,
        extractionConfidence
      });
      sendJson(response, 201, { draft });
    } catch (error) {
      if (error instanceof RequestError) throw error;
      const message = error instanceof Error ? error.message : "voice_draft_failed";
      sendJson(response, 400, { error: message });
    }
    return;
  }

  const draftConfirmMatch = pathname.match(/^\/say\/drafts\/([^/]+)\/confirm$/);
  if (request.method === "POST" && draftConfirmMatch) {
    const draftId = safeRecordId(draftConfirmMatch[1] ?? "");
    if (!draftId) {
      sendJson(response, 400, { error: "invalid_draft_id" });
      return;
    }
    const existingDraft = repository.getVoiceDraft(draftId);
    if (!existingDraft) {
      sendJson(response, 404, { error: "draft_not_found" });
      return;
    }
    if (existingDraft.status === "discarded") {
      sendJson(response, 409, { error: "draft_discarded" });
      return;
    }
    const body = await readJson<Record<string, unknown>>(request);
    const confirmedJson = body.confirmedJson && typeof body.confirmedJson === "object" ? (body.confirmedJson as Record<string, unknown>) : undefined;
    const result = repository.confirmVoiceDraft(draftId, {
      title: typeof body.title === "string" ? body.title : undefined,
      occurredAt: typeof body.occurredAt === "string" ? body.occurredAt : undefined,
      timezone: typeof body.timezone === "string" ? body.timezone : undefined,
      confirmedJson
    });
    if (!result) {
      sendJson(response, 404, { error: "draft_not_found" });
      return;
    }
    sendJson(response, 200, result);
    return;
  }

  const draftPatchMatch = pathname.match(/^\/say\/drafts\/([^/]+)$/);
  if (request.method === "PATCH" && draftPatchMatch) {
    const draftId = safeRecordId(draftPatchMatch[1] ?? "");
    if (!draftId) {
      sendJson(response, 400, { error: "invalid_draft_id" });
      return;
    }
    const existingDraft = repository.getVoiceDraft(draftId);
    if (!existingDraft) {
      sendJson(response, 404, { error: "draft_not_found" });
      return;
    }
    if (existingDraft.status === "confirmed") {
      sendJson(response, 409, { error: "draft_already_confirmed" });
      return;
    }
    const body = await readJson<Record<string, unknown>>(request);
    const requestedEntryType = body.entryType ?? body.entry_type;
    const entryType = requestedEntryType === undefined ? undefined : asEntryKind(requestedEntryType);
    if (requestedEntryType !== undefined && !entryType) {
      sendJson(response, 400, { error: "invalid_entry_type" });
      return;
    }
    const requestedStatus = typeof body.status === "string" ? body.status : undefined;
    if (requestedStatus !== undefined && requestedStatus !== "needs_review" && requestedStatus !== "discarded") {
      sendJson(response, 400, { error: "invalid_draft_status" });
      return;
    }
    const requestedExtractedJson = body.extractedJson ?? body.extracted_json;
    if (requestedExtractedJson !== undefined && (typeof requestedExtractedJson !== "object" || requestedExtractedJson === null || Array.isArray(requestedExtractedJson))) {
      sendJson(response, 400, { error: "invalid_extracted_json" });
      return;
    }
    const draft = repository.updateVoiceDraft(draftId, {
      entryType: entryType ?? undefined,
      status: requestedStatus,
      title: typeof body.title === "string" ? body.title : undefined,
      extractedJson: requestedExtractedJson === undefined ? undefined : (requestedExtractedJson as Record<string, unknown>),
      extractionConfidence: typeof body.extractionConfidence === "number" ? body.extractionConfidence : undefined
    });
    if (!draft) {
      sendJson(response, 404, { error: "draft_not_found" });
      return;
    }
    sendJson(response, 200, { draft });
    return;
  }

  const draftMatch = pathname.match(/^\/say\/drafts\/([^/]+)$/);
  if (request.method === "GET" && draftMatch) {
    const draftId = safeRecordId(draftMatch[1] ?? "");
    const draft = draftId ? repository.getVoiceDraft(draftId) : null;
    if (!draft) {
      sendJson(response, 404, { error: "draft_not_found" });
      return;
    }
    sendJson(response, 200, { draft });
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
    if (!isUserProfile(body.userProfile)) {
      sendJson(response, 400, { error: body.userProfile === undefined ? "user_profile_required" : "invalid_user_profile" });
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
    const sourceParam = url.searchParams.get("source");
    const kindParam = url.searchParams.get("kind");
    const source = sourceParam ? asEntrySource(sourceParam) : "workout_session";
    const kind = kindParam ? asEntryKind(kindParam) : undefined;
    if (sourceParam && !source) {
      sendJson(response, 400, { error: "invalid_entry_source" });
      return;
    }
    if (kindParam && !kind) {
      sendJson(response, 400, { error: "invalid_entry_kind" });
      return;
    }
    const filters: { source?: EntrySource; kind?: EntryKind } = {};
    if (source) {
      filters.source = source;
    }
    if (kind) {
      filters.kind = kind;
    }
    sendJson(response, 200, { entries: repository.listEntries(filters) });
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
  const runtime = createFoxSayRuntime(dependencies);
  return createServer((request, response) => {
    route(request, response, dependencies, runtime).catch((error: unknown) => {
      if (!(error instanceof RequestError)) console.error(error);
      if (response.destroyed || response.writableEnded) return;
      if (error instanceof RequestError && error.closeConnection) response.setHeader("Connection", "close");
      sendJson(response, requestErrorStatus(error, 500), { error: error instanceof RequestError ? error.message : "internal_server_error" });
    });
  });
}

if (process.env.NODE_ENV !== "test" && process.env.VITEST !== "true") {
  const server = createFoxServer();
  const onListening = () => {
    const address = server.address();
    const boundPort = typeof address === "object" && address ? address.port : port;
    console.log(`fox api listening on http://${host.includes(":") ? `[${host}]` : host}:${boundPort}`);
  };
  server.listen(port, host, onListening);
}
