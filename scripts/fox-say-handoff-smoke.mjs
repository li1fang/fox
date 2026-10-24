#!/usr/bin/env node
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(new URL("..", import.meta.url).pathname);
const remoteHost = process.env.FOX_SAY_VCOMPOSE_HOST ?? "fox-voice-host";
const remoteVComposeDir = process.env.FOX_SAY_VCOMPOSE_REPO ?? "/srv/fox-voice/VCompose";
const remoteReportPath =
  process.env.FOX_SAY_HANDOFF_REMOTE_REPORT ??
  "/srv/vcompose/output/fox/voice/runtime/e2e/fox-voice-ipad-linux-roundtrip-smoke-v0.json";
const localReportPath = resolve(
  process.env.FOX_SAY_HANDOFF_REPORT ?? `${root}/.tmp/fox-say-handoff-smoke-report.json`
);
const templatePath =
  process.env.FOX_SAY_HANDOFF_TEMPLATE ?? "examples/job-fox-voice-roundtrip-smoke-gate.yaml";
const submitter = process.env.FOX_SAY_HANDOFF_SUBMITTER ?? "fox-say-handoff-smoke";
const pollMs = Number(process.env.FOX_SAY_HANDOFF_POLL_MS ?? "2000");
const timeoutMs = Number(process.env.FOX_SAY_HANDOFF_TIMEOUT_MS ?? "60000");

function emit(payload, exitCode = payload.ok ? 0 : 1) {
  mkdirSync(dirname(localReportPath), { recursive: true });
  writeFileSync(localReportPath, JSON.stringify(payload, null, 2));
  console.log(JSON.stringify({ ...payload, localReportPath }, null, 2));
  process.exit(exitCode);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: root,
    encoding: "utf8",
    ...options
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      `${command} failed with exit ${result.status ?? "unknown"}\n${result.stdout ?? ""}${result.stderr ?? ""}`
    );
  }
  return result.stdout ?? "";
}

function parseJsonOutput(output, label) {
  const trimmed = output.trim();
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error(`${label} did not return JSON`);
  }
  return JSON.parse(trimmed.slice(start, end + 1));
}

function readRemoteJson(path) {
  const output = run("ssh", [remoteHost, "cat", path], { timeout: 15_000 });
  return JSON.parse(output);
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function hash(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

function reportMatchesCapture(report, capture) {
  const exportedCapture = report?.capture_export;
  if (!exportedCapture || typeof exportedCapture !== "object") {
    return false;
  }
  return (
    exportedCapture.content_type === capture.contentType &&
    exportedCapture.bytes === capture.bytes &&
    exportedCapture.sha256_match === true &&
    exportedCapture.audio?.bytes === capture.bytes
  );
}

const startedAt = new Date().toISOString();

try {
  const exportOutput = run("node", ["scripts/fox-say-export-capture.mjs"], { timeout: 60_000 });
  const exportReport = parseJsonOutput(exportOutput, "capture export");
  const capture = exportReport.capture;
  if (!exportReport.ok || !capture || capture.rawAudioCommitted !== false) {
    emit({
      ok: false,
      schema: "fox.say_handoff_smoke_report.v0",
      decision: "capture_export_blocked",
      started_at: startedAt,
      blocker: "capture_export_not_green_or_raw_audio_policy_violation",
      export_report_shape: {
        ok: exportReport.ok,
        schema: exportReport.schema,
        raw_audio_committed: capture?.rawAudioCommitted
      }
    });
  }

  const submitOutput = run(
    "ssh",
    [
      remoteHost,
      `cd ${JSON.stringify(remoteVComposeDir)} && go run ./cmd/vfctl submit -f ${JSON.stringify(templatePath)} --submitter ${JSON.stringify(submitter)}`
    ],
    { timeout: 60_000 }
  );
  const submitReport = parseJsonOutput(submitOutput, "VCompose submit");

  const deadline = Date.now() + timeoutMs;
  let remoteReport = null;
  let lastError = "";
  while (Date.now() < deadline) {
    try {
      remoteReport = readRemoteJson(remoteReportPath);
      if (reportMatchesCapture(remoteReport, capture)) {
        break;
      }
      lastError = "remote report exists but does not match latest capture yet";
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
    sleep(pollMs);
  }

  if (!remoteReport || !reportMatchesCapture(remoteReport, capture)) {
    emit({
      ok: false,
      schema: "fox.say_handoff_smoke_report.v0",
      decision: "handoff_smoke_report_timeout",
      started_at: startedAt,
      capture: {
        id_hash: hash(capture.id),
        content_type: capture.contentType,
        bytes: capture.bytes,
        sha256_match_expected: true,
        raw_audio_committed: false
      },
      vcompose_submit: submitReport,
      remote_report_path: remoteReportPath,
      blocker: lastError
    });
  }

  const ok =
    remoteReport.ok === true &&
    remoteReport.decision === "roundtrip_capture_linux_evidence_ready" &&
    remoteReport.capture_export?.sha256_match === true &&
    remoteReport.raw_audio_committed === false &&
    remoteReport.full_realtime_e2e_measured === false &&
    Array.isArray(remoteReport.blockers) &&
    remoteReport.blockers.length === 0;

  emit({
    ok,
    schema: "fox.say_handoff_smoke_report.v0",
    decision: ok ? "fox_say_handoff_smoke_ready" : "fox_say_handoff_smoke_blocked",
    started_at: startedAt,
    completed_at: new Date().toISOString(),
    capture: {
      id_hash: hash(capture.id),
      content_type: capture.contentType,
      bytes: capture.bytes,
      sha256: capture.sha256,
      raw_audio_committed: false
    },
    export: {
      schema: exportReport.schema,
      remote: exportReport.remote,
      local_export_dir: exportReport.localExportDir
    },
    vcompose_submit: submitReport,
    remote_report_path: remoteReportPath,
    remote_decision: remoteReport.decision,
    linux_asr_ready: remoteReport.linux_asr_evidence?.ok === true,
    linux_tts_ready: remoteReport.linux_tts_evidence?.ok === true,
    full_realtime_e2e_measured: remoteReport.full_realtime_e2e_measured === true,
    raw_audio_committed: remoteReport.raw_audio_committed === true,
    next_constraint: remoteReport.recommended_next_check ?? "human_ipad_noisy_corpus_matrix_with_streaming_latency"
  });
} catch (error) {
  emit({
    ok: false,
    schema: "fox.say_handoff_smoke_report.v0",
    decision: "fox_say_handoff_smoke_failed",
    started_at: startedAt,
    error: error instanceof Error ? error.message : String(error)
  });
}
