#!/usr/bin/env node
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

const apiUrl = (process.env.FOX_SAY_MAC_BRIDGE_API_URL ?? `http://127.0.0.1:${process.env.FOX_API_PORT ?? "4177"}`).replace(/\/$/, "");
const pollMs = Number(process.env.FOX_SAY_MAC_BRIDGE_POLL_MS ?? "750");
const clipboardCommand = process.env.FOX_SAY_MAC_CLIPBOARD_COMMAND ?? "pbcopy";
const runOnce = process.argv.includes("--once");
let stopping = false;

function sleep(ms) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, ms));
}

function errorMessage(error) {
  return error instanceof Error ? error.message : String(error);
}

export function bridgeReceipt(job) {
  return `[fox-say-mac-bridge] clipboard complete job=${job.id} chars=${job.textCharacters}`;
}

export function bridgeFailureReceipt(job, error) {
  return `[fox-say-mac-bridge] clipboard failed job=${job.id} reason=${errorMessage(error).slice(0, 240)}`;
}

export function writeTextToClipboard(text, command = clipboardCommand) {
  return new Promise((resolveWrite, rejectWrite) => {
    const child = spawn(command, [], { stdio: ["pipe", "ignore", "pipe"] });
    let stderr = "";
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.on("error", (error) => rejectWrite(error));
    child.on("exit", (code, signal) => {
      if (code === 0) {
        resolveWrite();
        return;
      }
      rejectWrite(new Error(`${command} exited with ${code ?? signal ?? "unknown"}${stderr ? `: ${stderr.trim()}` : ""}`));
    });
    child.stdin.end(text);
  });
}

async function jsonRequest(path, init = {}) {
  const response = await fetch(`${apiUrl}${path}`, init);
  if (response.status === 204) {
    return null;
  }
  const bodyText = await response.text();
  let body = {};
  if (bodyText) {
    try {
      body = JSON.parse(bodyText);
    } catch {
      body = { raw: bodyText };
    }
  }
  if (!response.ok) {
    throw new Error(`Fox API ${response.status}: ${JSON.stringify(body)}`);
  }
  return body;
}

async function markFailed(job, error) {
  try {
    await jsonRequest(`/say/mac-input-jobs/${encodeURIComponent(job.id)}/fail`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        errorCode: "mac_clipboard_failed",
        errorMessage: errorMessage(error).slice(0, 2_000)
      })
    });
  } catch (markError) {
    console.error(`[fox-say-mac-bridge] could not mark job failed: ${errorMessage(markError).slice(0, 240)}`);
  }
}

export async function processNextMacInputJob() {
  const payload = await jsonRequest("/say/mac-input-jobs/next");
  if (!payload) {
    return false;
  }
  const job = payload.job;
  const text = payload.text;
  if (!job?.id || typeof text !== "string" || !text.trim()) {
    throw new Error("mac_input_job_payload_invalid");
  }
  try {
    await writeTextToClipboard(text);
    await jsonRequest(`/say/mac-input-jobs/${encodeURIComponent(job.id)}/complete`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}"
    });
    console.log(bridgeReceipt(job));
  } catch (error) {
    await markFailed(job, error);
    console.error(bridgeFailureReceipt(job, error));
  }
  return true;
}

export async function main() {
  console.log(`[fox-say-mac-bridge] listening on ${apiUrl} (clipboard only; Command-V remains manual)`);
  while (!stopping) {
    try {
      const processed = await processNextMacInputJob();
      if (runOnce) {
        return;
      }
      if (!processed) {
        await sleep(pollMs);
      }
    } catch (error) {
      console.error(`[fox-say-mac-bridge] poll failed: ${errorMessage(error).slice(0, 240)}`);
      if (runOnce) {
        process.exitCode = 1;
        return;
      }
      await sleep(Math.max(pollMs, 1_000));
    }
  }
}

process.on("SIGINT", () => {
  stopping = true;
});
process.on("SIGTERM", () => {
  stopping = true;
});

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await main();
}
