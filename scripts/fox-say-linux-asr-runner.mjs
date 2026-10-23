#!/usr/bin/env node
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(new URL("..", import.meta.url).pathname);
const defaultTarget = "fox-say-latest-capture-sensevoice-v0";
const defaultTemplateRef =
  process.env.FOX_SAY_LINUX_ASR_TEMPLATE_REF ??
  "fox/k3s-heavy-gpu-fox-say-sensevoice-latest-capture-asr";
const defaultRemoteHost = process.env.FOX_SAY_VCOMPOSE_HOST ?? "fox-voice-host";
const defaultRemoteVComposeDir = process.env.FOX_SAY_VCOMPOSE_REPO ?? "/srv/fox-voice/VCompose";
const defaultRemoteReportPath =
  process.env.FOX_SAY_LINUX_ASR_REMOTE_REPORT ??
  `/srv/vcompose/output/fox/voice/runtime/asr-benchmark/${process.env.FOX_SAY_LINUX_ASR_TARGET ?? defaultTarget}.json`;
const defaultLocalReportPath = resolve(
  process.env.FOX_SAY_LINUX_ASR_REPORT ?? `${root}/.tmp/fox-say-linux-asr-runner-report.json`
);
const defaultApiUrl = process.env.FOX_API_URL ?? "http://127.0.0.1:4177";
const defaultPollMs = Number(process.env.FOX_SAY_LINUX_ASR_POLL_MS ?? "2000");
const defaultTimeoutMs = Number(process.env.FOX_SAY_LINUX_ASR_TIMEOUT_MS ?? "180000");

function yamlQuote(value) {
  return JSON.stringify(String(value));
}

function emit(payload, localReportPath = defaultLocalReportPath, exitCode = payload.ok ? 0 : 1) {
  mkdirSync(dirname(localReportPath), { recursive: true });
  writeFileSync(localReportPath, JSON.stringify(payload, null, 2));
  console.log(JSON.stringify({ ...payload, localReportPath }, null, 2));
  process.exit(exitCode);
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    encoding: "utf8",
    input: options.input,
    timeout: options.timeout,
    stdio: options.inherit ? "inherit" : "pipe"
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

export function parseJsonOutput(output, label) {
  const trimmed = output.trim();
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start < 0 || end < start) {
    throw new Error(`${label} did not return JSON`);
  }
  return JSON.parse(trimmed.slice(start, end + 1));
}

export function buildAsrJobSpec({
  audioPathShape,
  target = defaultTarget,
  templateRef = defaultTemplateRef
}) {
  const remoteAudioPath = `/workspace/data/roundtrip/${audioPathShape}`;
  const reportPath = `/srv/vcompose/output/fox/voice/runtime/asr-benchmark/${target}.ready`;
  return `apiVersion: vcompose/v1
kind: Job
metadata:
  name: fox-say-latest-capture-sensevoice-asr
  project: fox
  tags: [asr, heavy-gpu, fox, voice, fox-say, sensevoice]
spec:
  class: heavy-gpu
  priority: 40
  timeoutSec: 1800
  retry:
    maxAttempts: 1
  runtime:
    templateRef: ${yamlQuote(templateRef)}
    env:
      FOX_VOICE_ASR_AUDIO: ${yamlQuote(remoteAudioPath)}
      FOX_VOICE_ASR_BENCHMARK_TARGET: ${yamlQuote(target)}
      FOX_VOICE_ASR_EXPECTED_TEXT: ""
      FOX_VOICE_ASR_LANGUAGE: zh
      FOX_VOICE_ASR_MODEL_PATH: /workspace/data/modelscope/iic/SenseVoiceSmall
      FOX_VOICE_OUTPUT_ROOT: /workspace/output
  governance:
    team: fox
    purpose: fox-say-latest-capture-asr
  outputs:
    mustExist:
      - ${reportPath}
`;
}

export function reportMatchesCapture(report, capture) {
  if (!report || typeof report !== "object") {
    return false;
  }
  const audioShape = String(report.audio_path_shape ?? "");
  const expectedAudioShape = String(capture.asrAudioPathShape ?? capture.audioPathShape ?? "");
  const expectedAudioBytes = Number(capture.asrAudioBytes ?? capture.bytes);
  return (
    report.ok === true &&
    report.raw_audio_committed === false &&
    Number(report.audio_bytes) === expectedAudioBytes &&
    audioShape.endsWith(expectedAudioShape) &&
    String(report.text ?? "").trim().length > 0
  );
}

export function buildAsrPostPayload({ capture, remoteReport }) {
  const text = String(remoteReport.text ?? "").trim();
  if (!text) {
    throw new Error("linux_asr_report_missing_text");
  }
  const confidence =
    remoteReport.text_score?.expected_text_present === true &&
    typeof remoteReport.text_score?.normalized_similarity === "number"
      ? Math.max(0, Math.min(1, remoteReport.text_score.normalized_similarity))
      : undefined;
  return {
    captureId: capture.id,
    provider: "linux-sensevoice",
    language: "zh-CN",
    ...(confidence === undefined ? {} : { confidence }),
    transcript: text,
    rawResult: {
      schema: "fox.say_linux_asr_result_raw.v0",
      asr_engine: remoteReport.asr_engine,
      asr_model: remoteReport.asr_model,
      tagged_text: remoteReport.tagged_text,
      transcribe_ms: remoteReport.transcribe_ms,
      load_ms: remoteReport.load_ms,
      duration_ms_total: remoteReport.duration_ms_total,
      audio_path_shape: remoteReport.audio_path_shape,
      audio_bytes: remoteReport.audio_bytes,
      raw_audio_committed: false
    }
  };
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function hash(value) {
  return createHash("sha256").update(String(value)).digest("hex").slice(0, 16);
}

function readRemoteJson(remoteHost, path) {
  return JSON.parse(run("ssh", [remoteHost, "cat", path], { timeout: 15_000 }));
}

async function postAsrResult(apiUrl, payload) {
  const response = await fetch(`${apiUrl.replace(/\/$/, "")}/say/asr-results`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(payload)
  });
  const body = await response.json();
  if (!response.ok) {
    throw new Error(`Fox API rejected ASR result: ${JSON.stringify(body)}`);
  }
  return body;
}

export async function main() {
  const startedAt = new Date().toISOString();
  const remoteHost = defaultRemoteHost;
  const remoteVComposeDir = defaultRemoteVComposeDir;
  const target = process.env.FOX_SAY_LINUX_ASR_TARGET ?? defaultTarget;
  const remoteReportPath =
    process.env.FOX_SAY_LINUX_ASR_REMOTE_REPORT ??
    `/srv/vcompose/output/fox/voice/runtime/asr-benchmark/${target}.json`;
  const localReportPath = defaultLocalReportPath;

  try {
    const exportOutput = run("node", ["scripts/fox-say-export-capture.mjs"], { timeout: 60_000 });
    const exportReport = parseJsonOutput(exportOutput, "capture export");
    const capture = exportReport.capture;
    if (!exportReport.ok || !capture || capture.rawAudioCommitted !== false || !capture.audioPathShape) {
      throw new Error("capture_export_not_ready");
    }
    const asrAudioPathShape = capture.asrAudioPathShape ?? capture.audioPathShape;

    const jobSpec = buildAsrJobSpec({
      audioPathShape: asrAudioPathShape,
      target
    });
    const remoteSpecPath = `/tmp/fox-say-linux-asr-${Date.now()}.yaml`;
    run("ssh", [remoteHost, `cat > ${remoteSpecPath}`], { input: jobSpec, timeout: 15_000 });
    run("ssh", [remoteHost, `rm -f ${remoteReportPath} ${remoteReportPath.replace(/\.json$/, ".ready")}`], { timeout: 15_000 });
    const submitOutput = run(
      "ssh",
      [
        remoteHost,
        `cd ${JSON.stringify(remoteVComposeDir)} && go run ./cmd/vfctl submit -f ${remoteSpecPath} --submitter fox-say-linux-asr-runner`
      ],
      { timeout: 60_000 }
    );
    const submitReport = parseJsonOutput(submitOutput, "VCompose submit");

    const deadline = Date.now() + defaultTimeoutMs;
    let remoteReport = null;
    let lastError = "";
    while (Date.now() < deadline) {
      try {
        remoteReport = readRemoteJson(remoteHost, remoteReportPath);
        if (reportMatchesCapture(remoteReport, capture)) {
          break;
        }
        lastError = "remote ASR report exists but does not match latest capture or has empty text";
      } catch (error) {
        lastError = error instanceof Error ? error.message : String(error);
      }
      sleep(defaultPollMs);
    }

    if (!remoteReport || !reportMatchesCapture(remoteReport, capture)) {
      throw new Error(`linux_asr_report_timeout: ${lastError}`);
    }

    const postPayload = buildAsrPostPayload({ capture, remoteReport });
    const apiResponse = await postAsrResult(defaultApiUrl, postPayload);

    emit(
      {
        ok: true,
        schema: "fox.say_linux_asr_runner_report.v0",
        decision: "linux_asr_transcript_posted_to_fox",
        started_at: startedAt,
        completed_at: new Date().toISOString(),
        capture: {
          id_hash: hash(capture.id),
          content_type: capture.contentType,
          bytes: capture.bytes,
          sha256: capture.sha256,
          asr_content_type: capture.asrContentType,
          asr_audio_path_shape: asrAudioPathShape,
          asr_audio_bytes: capture.asrAudioBytes,
          raw_audio_committed: false
        },
        asr: {
          provider: postPayload.provider,
          language: postPayload.language,
          transcript: postPayload.transcript,
          transcribe_ms: remoteReport.transcribe_ms,
          report_path: remoteReportPath,
          raw_audio_committed: false
        },
        fox_api: {
          url: defaultApiUrl,
          asr_result_id: apiResponse.asrResult?.id,
          capture_id: apiResponse.asrResult?.captureId
        },
        vcompose_submit: submitReport
      },
      localReportPath
    );
  } catch (error) {
    emit(
      {
        ok: false,
        schema: "fox.say_linux_asr_runner_report.v0",
        decision: "linux_asr_runner_failed",
        started_at: startedAt,
        error: error instanceof Error ? error.message : String(error),
        raw_audio_committed: false
      },
      localReportPath
    );
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
