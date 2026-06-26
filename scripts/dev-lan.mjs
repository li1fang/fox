#!/usr/bin/env node
import { spawn } from "node:child_process";
import { networkInterfaces } from "node:os";

const apiPort = process.env.FOX_API_PORT ?? "4177";
const webPort = process.env.FOX_WEB_PORT ?? "5177";

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
  spawn("npm", ["run", "dev", "-w", "@fox/api"], {
    stdio: "inherit",
    env: {
      ...process.env,
      FOX_API_HOST: "0.0.0.0",
      FOX_API_PORT: apiPort
    }
  }),
  spawn("npm", ["run", "dev", "-w", "@fox/web-runtime", "--", "--host", "0.0.0.0", "--port", webPort], {
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
