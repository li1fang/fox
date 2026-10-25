import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { request as httpRequest, type Server } from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import { PassThrough } from "node:stream";
import { spawn } from "node:child_process";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createTemplateAiProvider } from "@fox/core";
import { createWorkoutRepository } from "../src/repository";
import { createFoxServer, type FoxSayAsrRunner } from "../src/server";
import { apiListenOptions, maxJsonBytes, readJson, requestUrl } from "../src/request-policy";
import playwrightConfig from "../../../playwright.config";

const cleanups: Array<() => void | Promise<void>> = [];
afterEach(async () => {
  try { for (const cleanup of cleanups.reverse()) await cleanup(); }
  finally { cleanups.length = 0; vi.unstubAllEnvs(); }
});

async function fixture(asrRunner?: FoxSayAsrRunner) {
  const dir = mkdtempSync(join(tmpdir(), "fox-boundary-"));
  const repository = createWorkoutRepository(join(dir, "test.sqlite"));
  cleanups.push(() => { repository.close(); rmSync(dir, { recursive: true, force: true }); });
  const server: Server = createFoxServer({ repository, aiProvider: createTemplateAiProvider(), asrRunner });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())));
  const port = (server.address() as AddressInfo).port;
  return { repository, port, url: `http://127.0.0.1:${port}` };
}

function raw(port: number, path: string, chunks: string[], headers: Record<string, string> = {}, method = "PATCH") {
  return new Promise<{ status: number; body: string }>((resolve, reject) => {
    const req = httpRequest({ hostname: "127.0.0.1", port, path, method, headers }, response => {
      let body = "";
      response.on("data", chunk => { body += chunk; });
      response.on("end", () => resolve({ status: response.statusCode!, body }));
    });
    req.on("error", reject);
    for (const chunk of chunks) req.write(chunk);
    req.end();
  });
}

describe("API request boundaries", () => {
  it("declares the actual Playwright web port to the API child", () => {
    const webPort = new URL(playwrightConfig.use!.baseURL!).port;
    const servers = playwrightConfig.webServer as Array<{ command: string }>;
    expect(servers[0]!.command).toContain(`FOX_WEB_PORT=${webPort}`);
  });

  it("binds the real default CLI to loopback and reports its actual ephemeral port", async () => {
    const dir = mkdtempSync(join(tmpdir(), "fox-listen-"));
    cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
    const child = spawn(process.execPath, ["--import", "tsx", "src/server.ts"], {
      cwd: new URL("..", import.meta.url),
      env: { ...process.env, NODE_ENV: "development", VITEST: "false", FOX_API_HOST: "", FOX_API_PORT: "0", FOX_DB_PATH: join(dir, "test.sqlite") },
      stdio: ["ignore", "pipe", "pipe"]
    });
    cleanups.push(async () => {
      if (child.exitCode !== null || child.signalCode !== null) return;
      const exited = once(child, "exit");
      child.kill("SIGTERM"); await exited;
    });
    const url = await new Promise<string>((resolve, reject) => {
      let output = "", errors = "";
      const timer = setTimeout(() => reject(new Error(`API startup timeout: ${output} ${errors}`)), 5000);
      child.stderr.on("data", data => { errors += data; });
      child.stdout.on("data", data => {
        output += data;
        const match = output.match(/fox api listening on (http:\/\/127\.0\.0\.1:([1-9]\d*))/);
        if (match) { clearTimeout(timer); resolve(match[1]!); }
      });
      child.once("error", error => { clearTimeout(timer); reject(error); });
      child.once("exit", code => { clearTimeout(timer); reject(new Error(`API exited ${code}: ${errors}`)); });
    });
    expect((await fetch(`${url}/health`)).status).toBe(200);
    expect(apiListenOptions({ FOX_API_HOST: "0.0.0.0", FOX_API_PORT: "4187" })).toEqual({ host: "0.0.0.0", port: 4187 });
  });

  it("allows explicit LAN/custom web ports and native audio without treating CORS as authentication", async () => {
    vi.stubEnv("FOX_API_HOST", "0.0.0.0");
    vi.stubEnv("FOX_LAN_HOST", "fox.local");
    vi.stubEnv("FOX_WEB_PORT", "5187");
    const { port, url } = await fixture();
    expect((await raw(port, "/health", [], { Host: `fox.local:${port}`, Origin: "http://fox.local:5187" }, "GET")).status).toBe(200);
    const response = await fetch(`${url}/health`, { headers: { Host: `fox.local:${port}`, Origin: "http://fox.local:5187" } });
    expect(response.status).toBe(200);
    expect(response.headers.get("access-control-allow-origin")).toBe("http://fox.local:5187");
    expect((await fetch(`${url}/health`, { headers: { Origin: "http://fox.local:5188" } })).status).toBe(403);
    const dir = mkdtempSync(join(tmpdir(), "fox-audio-boundary-"));
    cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
    vi.stubEnv("FOX_SAY_CAPTURE_DIR", dir);
    const audio = await fetch(`${url}/say/capture`, { method: "POST", headers: { "content-type": "audio/mp4", "x-fox-say-source": "ipad" }, body: Buffer.from("synthetic-audio") });
    expect(audio.status).toBe(201);
    expect(audio.headers.get("access-control-allow-origin")).toBeNull();
    const req = { url: "/say/asr-jobs", headers: { host: "192.168.1.20:4187", origin: "http://192.168.1.20:5187" }, socket: { localPort: 4187, localAddress: "192.168.1.20" } } as IncomingMessage;
    const res = { setHeader() {} } as unknown as ServerResponse;
    expect(requestUrl(req, res).origin).toBe("http://192.168.1.20:4187");
    expect(() => requestUrl(req, res, {})).toThrow("invalid_host");
  });
  it("rejects untrusted Origin before writes while accepting local preflight and no-Origin clients", async () => {
    const { url, repository } = await fixture();
    const before = repository.getUserProfile();
    const denied = await fetch(`${url}/profile/user`, {
      method: "PATCH", headers: { Origin: "https://untrusted.example", "content-type": "application/json" },
      body: JSON.stringify({ userProfile: { notes: "must not persist" } })
    });
    expect(denied.status).toBe(403);
    expect(denied.headers.get("access-control-allow-origin")).toBeNull();
    expect(repository.getUserProfile()).toEqual(before);
    const allowed = await fetch(`${url}/profile/user`, { method: "OPTIONS", headers: { Origin: "http://localhost:5177", "Access-Control-Request-Method": "PATCH", "Access-Control-Request-Headers": "content-type,x-fox-say-source" } });
    expect(allowed.status).toBe(204);
    expect(allowed.headers.get("access-control-allow-origin")).toBe("http://localhost:5177");
    expect(allowed.headers.get("vary")).toContain("Origin");
    expect((await fetch(`${url}/profile/user`)).status).toBe(200);
  });

  it("rejects forged Host and absolute targets before ASR or repository effects", async () => {
    const { port } = await fixture();
    for (const [path, Host] of [["/profile/user", "attacker.example:4177"], ["http://attacker.example/profile/user", `127.0.0.1:${port}`], ["/profile/user", "127.0.0.1:1"]]) {
      expect((await raw(port, path!, [JSON.stringify({ userProfile: {} })], { Host: Host! })).status).toBe(400);
    }
  });

  it("blocks forged ASR requests before the runner and permits its no-Origin callback", async () => {
    const runner = vi.fn<NonNullable<FoxSayAsrRunner["runCapture"]>>(async ({ apiUrl, capture }) => {
      const response = await fetch(`${apiUrl}/say/asr-results`, {
        method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ captureId: capture.id, provider: "synthetic", transcript: "test" })
      });
      expect(response.status).toBe(201);
      return { ok: true };
    });
    const { url, port, repository } = await fixture({ runCapture: runner });
    const dir = mkdtempSync(join(tmpdir(), "fox-asr-boundary-"));
    cleanups.push(() => rmSync(dir, { recursive: true, force: true }));
    vi.stubEnv("FOX_SAY_CAPTURE_DIR", dir);
    const audio = await fetch(`${url}/say/capture`, { method: "POST", headers: { "content-type": "audio/mp4" }, body: Buffer.from("synthetic-audio") });
    const { capture } = await audio.json() as { capture: { id: string } };
    const body = JSON.stringify({ captureId: capture.id });
    for (const headers of [{ Host: `attacker.example:${port}` }, { Origin: "https://untrusted.example" }]) {
      const response = await raw(port, "/say/asr/run-latest", [body], headers, "POST");
      expect([400, 403]).toContain(response.status);
      expect(runner).not.toHaveBeenCalled();
      expect(repository.listVoiceAsrResults(capture.id)).toHaveLength(0);
    }
    expect((await fetch(`${url}/say/asr/run-latest`, { method: "POST", body })).status).toBe(200);
    expect(runner).toHaveBeenCalledTimes(1);
    expect(runner.mock.calls[0]![0].apiUrl).toBe(url);
    expect(repository.listVoiceAsrResults(capture.id)).toHaveLength(1);
  });

  it("caps streamed JSON by UTF-8 bytes, rejects bad JSON and stays usable", async () => {
    const { port, url, repository } = await fixture();
    const before = repository.getUserProfile();
    const tooLarge = await raw(port, "/profile/user", ['{"userProfile":{"notes":"', "中".repeat(360000), '"}}'], { "content-type": "application/json" });
    expect(tooLarge.status).toBe(413);
    expect(repository.getUserProfile()).toEqual(before);
    for (const body of ["{broken", "null", "[]", "42"]) {
      const rejected = await raw(port, "/profile/user", [body]);
      expect(rejected.status).toBe(400);
      expect(repository.getUserProfile()).toEqual(before);
    }
    const valid = await fetch(`${url}/profile/user`, { method: "PATCH", body: JSON.stringify({ userProfile: { heightCm: 180, notes: "中文" } }) });
    expect(valid.status).toBe(200);
    expect(repository.getUserProfile()?.notes).toBe("中文");
    const envelope = JSON.stringify({ userProfile: { notes: "" } });
    const exact = JSON.stringify({ userProfile: { notes: "x".repeat(maxJsonBytes - Buffer.byteLength(envelope)) } });
    expect(Buffer.byteLength(exact)).toBe(maxJsonBytes);
    expect((await raw(port, "/profile/user", [exact])).status).toBe(200);
    expect((await raw(port, "/profile/user", [exact + " "])).status).toBe(413);
  });

  it("releases buffered data on interrupted and oversized streams without unhandled late errors", async () => {
    const stream = new PassThrough() as unknown as IncomingMessage;
    stream.headers = {};
    const result = readJson(stream);
    const rejected = expect(result).rejects.toMatchObject({ message: "request_aborted", status: 400 });
    stream.emit("data", Buffer.from('{"partial":'));
    stream.emit("aborted");
    expect(() => stream.emit("error", new Error("ECONNRESET"))).not.toThrow();
    await rejected;
    expect(stream.listenerCount("data")).toBe(0);
    expect(stream.listenerCount("end")).toBe(0);
    const oversized = new PassThrough() as unknown as IncomingMessage;
    oversized.headers = {};
    const overflow = readJson(oversized);
    const limited = expect(overflow).rejects.toMatchObject({ status: 413 });
    oversized.emit("data", Buffer.alloc(maxJsonBytes + 1));
    await limited;
    expect(oversized.listenerCount("data")).toBe(0);
  });

  it("validates profile containers, numbers, enums and nested measurements before storage", async () => {
    const { url, repository } = await fixture();
    const before = repository.getUserProfile();
    for (const userProfile of [[], { heightCm: "180" }, { heightCm: -1 }, { heightCm: null }, { birthYear: 2000.5 }, { sex: "invalid" }, { preferredWeightUnit: "stone" }, { activityBaseline: [] }, { activityBaseline: { dailyStepsApprox: -1 } }, { measurements: [null] }, { measurements: [{ kind: "waist", label: "waist", value: "80", unit: "cm", measuredAt: "2026-10-25" }] }, { measurements: [{ kind: "waist", label: "waist", value: 80, unit: "cm" }] }, { note: "typo" }]) {
      const response = await fetch(`${url}/profile/user`, { method: "PATCH", body: JSON.stringify({ userProfile }) });
      expect(response.status).toBe(400);
      expect(repository.getUserProfile()).toEqual(before);
    }
    const valid = { sex: "unknown", birthYear: 1990, ethnicity: "", heightCm: 180, weightKg: 80, preferredWeightUnit: "kg", activityBaseline: { dailyStepsApprox: 5000, recentTrainingStatus: "", cardioBaseline: "" }, measurements: [{ kind: "waist", label: "waist", value: 80, unit: "cm", measuredAt: "2026-10-25", notes: "" }], notes: "", updatedAt: "2026-10-25" };
    expect((await fetch(`${url}/profile/user`, { method: "PATCH", body: JSON.stringify({ userProfile: valid }) })).status).toBe(200);
    expect(repository.getUserProfile()?.measurements).toEqual(valid.measurements);
    expect((await fetch(`${url}/profile/user`, { method: "PATCH", body: '{"userProfile":{"heightCm":1e400}}' })).status).toBe(400);
  });

  it("keeps JSON 4xx errors through Fox Say endpoint catch handlers", async () => {
    const { url } = await fixture();
    for (const path of ["/say/corpus-samples", "/say/asr-jobs", "/say/asr/run-latest", "/say/asr-results", "/say/drafts"]) {
      const response = await fetch(`${url}${path}`, { method: "POST", body: '{"padding":"' + "x".repeat(1024 * 1024) + '"}' });
      expect(response.status, path).toBe(413);
    }
  });
});
