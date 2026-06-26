#!/usr/bin/env node
import { spawn } from "node:child_process";
import { networkInterfaces } from "node:os";
import { join, resolve } from "node:path";

const apiPort = process.env.FOX_API_PORT ?? "4177";
const webPort = process.env.FOX_WEB_PORT ?? "5177";
const root = resolve(new URL("..", import.meta.url).pathname);

function bin(name) {
  return join(root, "node_modules", ".bin", name);
}

function detectLanHost() {
  if (process.env.FOX_LAN_HOST) {
    return process.env.FOX_LAN_HOST;
  }
  for (const entries of Object.values(networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family === "IPv4" && !entry.internal) {
        return entry.address;
      }
    }
  }
  return "127.0.0.1";
}

const lanHost = detectLanHost();
const apiUrl = `http://${lanHost}:${apiPort}`;
const webUrl = `http://${lanHost}:${webPort}`;

console.log(`fox LAN API: ${apiUrl}`);
console.log(`fox LAN Web: ${webUrl}`);

const children = [
  spawn(bin("tsx"), ["watch", "--tsconfig", "tsconfig.dev.json", "src/server.ts"], {
    cwd: join(root, "apps", "api"),
    stdio: "inherit",
    env: {
      ...process.env,
      FOX_API_HOST: "0.0.0.0",
      FOX_API_PORT: apiPort
    }
  }),
  spawn(bin("vite"), ["--host", "0.0.0.0", "--port", webPort], {
    cwd: join(root, "apps", "web-runtime"),
    stdio: "inherit",
    env: {
      ...process.env,
      VITE_FOX_API_URL: apiUrl
    }
  })
];

function shutdown(signal) {
  for (const child of children) {
    child.kill(signal);
  }
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));

let exitCode = 0;
for (const child of children) {
  child.on("exit", (code, signal) => {
    if (code && code !== 0) {
      exitCode = code;
    }
    if (signal) {
      exitCode = 1;
    }
    shutdown("SIGTERM");
    setTimeout(() => process.exit(exitCode), 100);
  });
}
