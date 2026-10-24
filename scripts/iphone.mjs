#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const root = fileURLToPath(new URL("..", import.meta.url));
const command = process.argv[2] ?? "doctor";
if (!["doctor", "build", "install", "open", "run"].includes(command)) {
  throw new Error(`Unsupported iPhone command: ${command}`);
}
const result = spawnSync(process.execPath, [join(root, "scripts/ipad.mjs"), command, "fox"], {
  cwd: root,
  stdio: "inherit",
  env: {
    ...process.env,
    FOX_IOS_DEVICE_FAMILY: "iPhone",
    FOX_IOS_DERIVED_DATA: process.env.FOX_IOS_DERIVED_DATA ?? join(root, ".tmp", "home-iphone-derived-data"),
    FOX_IOS_REGISTER_DEVICE: "1"
  }
});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
