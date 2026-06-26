#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir, networkInterfaces } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const ipadDir = join(root, "apps", "ipad");
const projectPath = join(ipadDir, "FoxPad.xcodeproj");
const derivedDataPath = join(root, ".tmp", "ipad-derived-data");
const appPath = join(derivedDataPath, "Build", "Products", "Debug-iphoneos", "FoxPad.app");
const developerDir = process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
const bundleId = "com.whipa.fox";

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? root,
    env: {
      ...process.env,
      DEVELOPER_DIR: developerDir,
      ...options.env
    },
    encoding: "utf8",
    stdio: options.capture ? "pipe" : "inherit"
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    const output = [result.stdout, result.stderr].filter(Boolean).join("\n");
    throw new Error(`${command} ${args.join(" ")} failed${output ? `\n${output}` : ""}`);
  }
  return result.stdout ?? "";
}

function commandExists(command) {
  const result = spawnSync("sh", ["-lc", `command -v ${command}`], { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : "";
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

function readJsonFile(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function listDevices() {
  const dir = mkdtempSync(join(tmpdir(), "fox-devicectl-"));
  const outputPath = join(dir, "devices.json");
  try {
    run("xcrun", ["devicectl", "list", "devices", "--json-output", outputPath], { capture: true });
    return readJsonFile(outputPath).result?.devices ?? [];
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function deviceDisplayName(device) {
  return device.deviceProperties?.name ?? device.name ?? device.identifier ?? "Unknown device";
}

function deviceIdentifier(device) {
  return (
    device.identifier ??
    device.hardwareProperties?.udid ??
    device.connectionProperties?.potentialHostnames?.[0] ??
    deviceDisplayName(device)
  );
}

function selectDevice() {
  if (process.env.FOX_IOS_DEVICE) {
    return process.env.FOX_IOS_DEVICE;
  }
  const devices = listDevices().filter((device) => device.connectionProperties?.pairingState === "paired");
  if (devices.length === 0) {
    throw new Error("No paired iPad/iOS device found. Connect and trust the iPad first.");
  }
  if (devices.length > 1) {
    const names = devices.map((device) => `${deviceDisplayName(device)} (${deviceIdentifier(device)})`).join(", ");
    throw new Error(`Multiple paired devices found. Set FOX_IOS_DEVICE to one of: ${names}`);
  }
  return deviceIdentifier(devices[0]);
}

function printDeviceSummary() {
  const devices = listDevices();
  if (devices.length === 0) {
    console.log("No devices returned by devicectl.");
    return;
  }
  for (const device of devices) {
    console.log(
      [
        `device=${deviceDisplayName(device)}`,
        `id=${deviceIdentifier(device)}`,
        `pairing=${device.connectionProperties?.pairingState ?? "unknown"}`,
        `developerMode=${device.deviceProperties?.developerModeStatus ?? "unknown"}`,
        `transport=${device.connectionProperties?.transportType ?? "unknown"}`
      ].join(" ")
    );
  }
}

function doctor() {
  console.log(`DEVELOPER_DIR=${developerDir}`);
  run("xcodebuild", ["-version"]);
  const xcodegen = commandExists("xcodegen");
  if (!xcodegen) {
    throw new Error("xcodegen is required. Install it with Homebrew: brew install xcodegen");
  }
  console.log(`xcodegen=${xcodegen}`);
  run("xcodegen", ["--version"]);
  run("security", ["find-identity", "-v", "-p", "codesigning"]);
  console.log(`LAN host=${detectLanHost()}`);
  printDeviceSummary();
  console.log(`selectedDevice=${selectDevice()}`);
}

function generate() {
  run("xcodegen", ["generate"], { cwd: ipadDir });
}

function build() {
  generate();
  run("xcodebuild", [
    "-project",
    projectPath,
    "-scheme",
    "FoxPad",
    "-configuration",
    "Debug",
    "-destination",
    "generic/platform=iOS",
    "-derivedDataPath",
    derivedDataPath,
    "-allowProvisioningUpdates",
    "build"
  ]);
  if (!existsSync(appPath)) {
    throw new Error(`Expected app bundle was not created: ${appPath}`);
  }
  console.log(`builtApp=${appPath}`);
}

function install() {
  const device = selectDevice();
  if (!existsSync(appPath)) {
    build();
  }
  run("xcrun", ["devicectl", "device", "install", "app", "--device", device, appPath]);
}

function open() {
  const device = selectDevice();
  const webUrl = process.env.FOX_WEB_URL ?? `http://${detectLanHost()}:${process.env.FOX_WEB_PORT ?? "5177"}`;
  console.log(`launching ${bundleId} on ${device}`);
  console.log(`FOX_WEB_URL=${webUrl}`);
  try {
    const output = run(
      "xcrun",
      [
        "devicectl",
        "device",
        "process",
        "launch",
        "--device",
        device,
        "--terminate-existing",
        "--environment-variables",
        JSON.stringify({ FOX_WEB_URL: webUrl }),
        bundleId
      ],
      { capture: true }
    );
    if (output) {
      process.stdout.write(output);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (message.includes("explicitly trusted") || message.includes("invalid code signature")) {
      throw new Error(
        `${message}\n\n` +
          "FoxPad was installed, but iPadOS rejected launch because the development profile is not trusted yet.\n" +
          "On the iPad, open Settings > General > VPN & Device Management, trust the Apple Development profile, then rerun `npm run ipad:open` or `npm run ipad:smoke`."
      );
    }
    throw error;
  }
}

async function waitForUrl(url, label) {
  const deadline = Date.now() + 60_000;
  let latestError = "";
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        return;
      }
      latestError = `${response.status} ${response.statusText}`;
    } catch (error) {
      latestError = error instanceof Error ? error.message : String(error);
    }
    await new Promise((resolveWait) => setTimeout(resolveWait, 750));
  }
  throw new Error(`${label} did not become ready at ${url}: ${latestError}`);
}

function startChild(command, args, env) {
  return spawn(command, args, {
    cwd: root,
    stdio: "inherit",
    env: {
      ...process.env,
      ...env
    }
  });
}

async function smoke() {
  const lanHost = detectLanHost();
  const apiPort = process.env.FOX_API_PORT ?? "4177";
  const webPort = process.env.FOX_WEB_PORT ?? "5177";
  const apiUrl = `http://${lanHost}:${apiPort}`;
  const webUrl = `http://${lanHost}:${webPort}`;
  const children = [
    startChild("npm", ["run", "dev", "-w", "@fox/api"], {
      FOX_API_HOST: "0.0.0.0",
      FOX_API_PORT: apiPort,
      FOX_DB_PATH: join(root, ".tmp", "ipad-smoke.sqlite")
    }),
    startChild("npm", ["run", "dev", "-w", "@fox/web-runtime", "--", "--host", "0.0.0.0", "--port", webPort], {
      VITE_FOX_API_URL: apiUrl
    })
  ];
  try {
    await waitForUrl(`${apiUrl}/health`, "fox API");
    await waitForUrl(webUrl, "fox web runtime");
    build();
    install();
    process.env.FOX_WEB_URL = webUrl;
    open();
  } finally {
    for (const child of children) {
      child.kill("SIGTERM");
    }
  }
}

const command = process.argv[2] ?? "doctor";

try {
  if (command === "doctor") {
    doctor();
  } else if (command === "generate") {
    generate();
  } else if (command === "build") {
    build();
  } else if (command === "install") {
    install();
  } else if (command === "open") {
    open();
  } else if (command === "smoke") {
    await smoke();
  } else {
    throw new Error(`Unknown command: ${command}`);
  }
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
}
