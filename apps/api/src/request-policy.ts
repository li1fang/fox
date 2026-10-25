import type { IncomingMessage, ServerResponse } from "node:http";
import type { UserProfile } from "@fox/core";

export const maxJsonBytes = 1024 * 1024;

export class RequestError extends Error {
  constructor(message: string, public readonly status: number, public readonly closeConnection = false) {
    super(message);
  }
}

export function requestErrorStatus(error: unknown, fallback: number): number {
  return error instanceof RequestError ? error.status : fallback;
}

export function apiListenOptions(env: NodeJS.ProcessEnv = process.env) {
  return { host: env.FOX_API_HOST?.trim() || "127.0.0.1", port: Number(env.FOX_API_PORT ?? 4177) };
}

function normalizeHost(host: string): string {
  return host.toLowerCase().replace(/^\[|\]$/g, "").replace(/^::ffff:/, "");
}

// Host is also used by the ASR callback: accept local server names, never arbitrary authorities.
export function requestUrl(request: IncomingMessage, response: ServerResponse, env: NodeJS.ProcessEnv = process.env): URL {
  const target = request.url ?? "/";
  if (!target.startsWith("/") || target.startsWith("//")) throw new RequestError("invalid_request_target", 400);
  const authority = request.headers.host;
  if (!authority || /[\s\\/@?#]/.test(authority)) throw new RequestError("invalid_host", 400);
  let url: URL;
  try { url = new URL(`http://${authority}`); } catch { throw new RequestError("invalid_host", 400); }
  const options = apiListenOptions(env);
  const port = request.socket.localPort ?? options.port;
  const hosts = new Set(["localhost", "127.0.0.1", "::1"]);
  const bindHost = normalizeHost(options.host);
  if (!["localhost", "127.0.0.1", "::1"].includes(bindHost)) {
    if (!["0.0.0.0", "::"].includes(bindHost)) hosts.add(bindHost);
    if (request.socket.localAddress) hosts.add(normalizeHost(request.socket.localAddress));
    if (env.FOX_LAN_HOST) hosts.add(normalizeHost(env.FOX_LAN_HOST));
  }
  if (!hosts.has(normalizeHost(url.hostname)) || Number(url.port || 80) !== port) throw new RequestError("invalid_host", 400);
  const origin = request.headers.origin;
  response.setHeader("Vary", "Origin");
  if (origin !== undefined) {
    let parsed: URL;
    try { parsed = new URL(origin); } catch { throw new RequestError("origin_not_allowed", 403); }
    const originPort = Number(parsed.port || 80);
    if (parsed.origin !== origin || parsed.protocol !== "http:" || !hosts.has(normalizeHost(parsed.hostname)) ||
        ![port, Number(env.FOX_WEB_PORT ?? 5177)].includes(originPort)) {
      throw new RequestError("origin_not_allowed", 403);
    }
    response.setHeader("Access-Control-Allow-Origin", origin);
  }
  response.setHeader("Access-Control-Allow-Headers", "content-type,x-fox-say-source");
  response.setHeader("Access-Control-Allow-Methods", "GET,POST,PATCH,OPTIONS");
  const resolved = new URL(target, url);
  if (resolved.origin !== url.origin) throw new RequestError("invalid_request_target", 400);
  return resolved;
}

export function readJson<T>(request: IncomingMessage): Promise<T> {
  return new Promise((resolve, reject) => {
    let chunks: Buffer[] = [];
    let total = 0;
    const cleanup = () => {
      request.off("data", onData); request.off("end", onEnd);
      request.off("error", onError); request.off("aborted", onAborted);
      chunks = [];
    };
    const fail = (error: Error) => {
      cleanup();
      // An aborted IncomingMessage can emit ECONNRESET after its aborted event.
      request.once("error", () => {});
      request.pause();
      reject(error);
    };
    const onError = () => fail(new RequestError("request_read_failed", 400, true));
    const onAborted = () => fail(new RequestError("request_aborted", 400, true));
    const onData = (chunk: Buffer) => {
      total += chunk.byteLength;
      if (total > maxJsonBytes) { fail(new RequestError("request_too_large", 413, true)); return; }
      chunks.push(chunk);
    };
    const onEnd = () => {
      const bytes = Buffer.concat(chunks);
      cleanup();
      try {
        const body: unknown = bytes.length ? JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)) : {};
        if (!isObject(body)) throw new Error("object_required");
        resolve(body as T);
      } catch { reject(new RequestError("invalid_json_object", 400)); }
    };
    request.on("data", onData); request.on("end", onEnd);
    request.on("error", onError); request.on("aborted", onAborted);
  });
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

type Check = (value: unknown) => boolean;
const string: Check = value => typeof value === "string";
const nonnegative: Check = value => typeof value === "number" && Number.isFinite(value) && value >= 0;
const positive: Check = value => nonnegative(value) && (value as number) > 0;
const oneOf = (...values: string[]): Check => value => typeof value === "string" && values.includes(value);

function fields(value: unknown, checks: Record<string, Check>, required: string[] = []): boolean {
  return isObject(value) && required.every(key => Object.hasOwn(value, key)) &&
    Object.entries(value).every(([key, item]) => Object.hasOwn(checks, key) && checks[key]!(item));
}

export function isUserProfile(value: unknown): value is UserProfile {
  return fields(value, {
    sex: oneOf("male", "female", "other", "unknown"),
    birthYear: item => positive(item) && Number.isInteger(item),
    ethnicity: string, heightCm: positive, weightKg: positive,
    preferredWeightUnit: oneOf("kg", "lb"), notes: string, updatedAt: string,
    activityBaseline: item => fields(item, { dailyStepsApprox: nonnegative, recentTrainingStatus: string, cardioBaseline: string }),
    measurements: item => Array.isArray(item) && item.every(measurement => fields(measurement, {
      kind: oneOf("shoulder_width", "chest", "waist", "hip", "arm", "thigh", "body_weight", "other"),
      label: string, value: nonnegative, unit: oneOf("cm", "kg", "lb"), measuredAt: string, notes: string
    }, ["kind", "label", "value", "unit", "measuredAt"]))
  });
}
