#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
if (process.platform !== "darwin") {
  console.error("Journal native tests require macOS and Xcode. CI runs them in the native-core job.");
  process.exit(1);
}
const python = process.env.FOX_JOURNAL_PYTHON ?? "python3";
function run(command, args, env = process.env) {
  const result = spawnSync(command, args, { cwd: root, env, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
run(python, ["-c", "import jsonschema, referencing"]);
mkdirSync(join(root, ".tmp"), { recursive: true });
const fixture = join(mkdtempSync(join(root, ".tmp", "journal-wire-")), "backup.json");
const environment = { ...process.env, FOX_JOURNAL_SCHEMA_FIXTURE: fixture };
if (!environment.DEVELOPER_DIR && existsSync("/Applications/Xcode.app/Contents/Developer")) {
  environment.DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer";
}
run("xcrun", ["swift", "test", "--package-path", "apps/ipad/FoxJournalCore", "--scratch-path", ".tmp/journal-core-build"], environment);
run(python, ["scripts/validate-journal-schema.py", fixture]);
const sdk = spawnSync("xcrun", ["--sdk", "iphoneos", "--show-sdk-path"], { env: environment, encoding: "utf8" });
if (sdk.error || sdk.status !== 0 || !sdk.stdout.trim()) {
  console.error("An iPhoneOS SDK is required for the journal compatibility check.");
  process.exit(1);
}
run("xcrun", ["swift", "build", "--package-path", "apps/ipad/FoxJournalCore", "--scratch-path", ".tmp/journal-ios-build",
  "--target", "FoxJournalCore", "--triple", "arm64-apple-ios16.0", "--sdk", sdk.stdout.trim()], environment);
console.log("journal_ios_compile_pass (SDK compilation only, not device execution)");
