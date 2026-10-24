#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { basename, extname, join, resolve } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const captureRootCandidates = process.env.FOX_SAY_CAPTURE_DIR
  ? [resolve(process.env.FOX_SAY_CAPTURE_DIR)]
  : [
      join(root, ".tmp", "fox-say-captures"),
      join(root, "apps", "api", ".tmp", "fox-say-captures")
    ];
const requestedCaptureId = String(process.env.FOX_SAY_CAPTURE_ID ?? "").trim();
if (requestedCaptureId && !/^[A-Za-z0-9_-]{8,80}$/.test(requestedCaptureId)) {
  fail(`invalid requested capture id: ${requestedCaptureId}`);
}
const captureRoot =
  captureRootCandidates.find((candidate) => existsSync(join(candidate, requestedCaptureId ? `${requestedCaptureId}.json` : "latest.json"))) ??
  captureRootCandidates[0];
const latestPath = join(captureRoot, "latest.json");
const captureMetadataPath = requestedCaptureId ? join(captureRoot, `${requestedCaptureId}.json`) : latestPath;
const remoteHost = process.env.FOX_SAY_VCOMPOSE_HOST ?? "fox-voice-host";
const remoteDir = process.env.FOX_SAY_VCOMPOSE_DIR ?? "/srv/vcompose/data/fox/voice/roundtrip";
const localExportDir = resolve(process.env.FOX_SAY_EXPORT_DIR ?? join(root, ".tmp", "fox-say-roundtrip-export"));

function fail(message) {
  console.error(JSON.stringify({ ok: false, error: message }, null, 2));
  process.exit(1);
}

function run(command, args) {
  const result = spawnSync(command, args, { stdio: "inherit" });
  if (result.status !== 0) {
    fail(`${command} failed with exit ${result.status ?? "unknown"}`);
  }
}

if (!existsSync(captureMetadataPath)) {
  fail(`${requestedCaptureId ? "requested" : "latest"} capture not found: ${captureMetadataPath}`);
}

const capture = JSON.parse(readFileSync(captureMetadataPath, "utf8"));
if (capture?.schema !== "fox.say_capture.v0" || typeof capture.audioPath !== "string" || typeof capture.id !== "string") {
  fail(`${requestedCaptureId ? "requested" : "latest"} capture is not a fox.say_capture.v0 artifact`);
}
if (requestedCaptureId && capture.id !== requestedCaptureId) {
  fail(`requested capture id mismatch: expected ${requestedCaptureId}, received ${capture.id}`);
}
if (!existsSync(capture.audioPath)) {
  fail(`capture audio not found: ${capture.audioPath}`);
}

mkdirSync(localExportDir, { recursive: true });
const audioName = basename(capture.audioPath);
const localAudioPath = join(localExportDir, audioName);
const wavName = `${basename(capture.audioPath, extname(capture.audioPath))}.wav`;
const localWavPath = join(localExportDir, wavName);
const localMetadataPath = join(localExportDir, "latest-capture.json");
copyFileSync(capture.audioPath, localAudioPath);
run("ffmpeg", ["-y", "-hide_banner", "-loglevel", "error", "-i", capture.audioPath, "-ac", "1", "-ar", "16000", localWavPath]);
const wavBytes = statSync(localWavPath).size;

const exported = {
  ok: true,
  schema: "fox.say_roundtrip_capture_export.v0",
  exportedAt: new Date().toISOString(),
  capture: {
    id: capture.id,
    contentType: capture.contentType,
    bytes: capture.bytes,
    sha256: capture.sha256,
    capturedAt: capture.capturedAt,
    source: capture.source,
    rawAudioCommitted: false,
    audioPathShape: audioName,
    vcomposeAudioPath: `/workspace/data/roundtrip/${audioName}`,
    asrContentType: "audio/wav",
    asrAudioPathShape: wavName,
    asrAudioBytes: wavBytes,
    vcomposeAsrAudioPath: `/workspace/data/roundtrip/${wavName}`
  },
  remote: {
    host: remoteHost,
    directory: remoteDir
  }
};
writeFileSync(localMetadataPath, JSON.stringify(exported, null, 2));

run("ssh", [remoteHost, "mkdir", "-p", remoteDir]);
run("scp", [localAudioPath, localWavPath, localMetadataPath, `${remoteHost}:${remoteDir}/`]);

console.log(JSON.stringify({ ...exported, localExportDir }, null, 2));
