#!/usr/bin/env node
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir, networkInterfaces } from "node:os";
import { join, resolve } from "node:path";
import { selectPairedDevice } from "./ios-device-selection.mjs";
import { iosLaunchArguments } from "./ios-launch-policy.mjs";
import {classifyDeviceError} from './verification-contracts.mjs';

const root = resolve(new URL("..", import.meta.url).pathname);
const ipadDir = join(root, "apps", "ipad");
const projectPath = join(ipadDir, "FoxPad.xcodeproj");
const derivedDataPath = resolve(process.env.FOX_IOS_DERIVED_DATA ?? join(root, ".tmp", "ipad-derived-data"));
const developerDir = process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
const ipadApps = {
  fox: {
    key: "fox",
    label: "Fox",
    scheme: "Fox",
    bundleId: "com.whipa.fox",
    appName: "Fox.app",
    webPath: ""
  },
  say: {
    key: "say",
    label: "Fox Say",
    scheme: "FoxSay",
    bundleId: "com.whipa.foxsay",
    appName: "FoxSay.app",
    webPath: "/?mode=say"
  }
};

function bin(name) {
  return join(root, "node_modules", ".bin", name);
}

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

function appPath(app) {
  return join(derivedDataPath, "Build", "Products", "Debug-iphoneos", app.appName);
}

function selectedApp(optionalValue = process.argv[3]) {
  const key = optionalValue ?? process.env.FOX_IPAD_APP ?? "fox";
  const app = ipadApps[key];
  if (!app) {
    throw new Error(`Unknown iPad app: ${key}. Expected one of: ${Object.keys(ipadApps).join(", ")}`);
  }
  return app;
}

function appSelection(optionalValue = process.argv[3], { defaultToAll = false } = {}) {
  if (optionalValue === "all" || (!optionalValue && defaultToAll)) {
    return Object.values(ipadApps);
  }
  if (!optionalValue && process.env.FOX_IPAD_APP === "all") {
    return Object.values(ipadApps);
  }
  return [selectedApp(optionalValue)];
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
  return deviceIdentifier(selectedDeviceDetails());
}

function selectedDeviceDetails() {
  return selectPairedDevice(listDevices(), {
    selector: process.env.FOX_IOS_DEVICE,
    family: process.env.FOX_IOS_DEVICE_FAMILY ?? "iPad"
  });
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

function inspectDevice(identifier) {
  const dir = mkdtempSync(join(tmpdir(), "fox-device-details-"));
  try {
    const outputPath = join(dir, "details.json");
    run("xcrun", ["devicectl", "device", "info", "details", "--device", identifier,
      "--timeout", "30", "--json-output", outputPath], { capture: true });
    return readJsonFile(outputPath).result;
  } finally {
    rmSync(dir, { recursive: true, force: true });
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
  console.log(`apps=${Object.values(ipadApps).map((app) => `${app.key}:${app.bundleId}`).join(" ")}`);
  printDeviceSummary();
  const device = selectDevice();
  console.log(`selectedDevice=${device}`);
  const details = inspectDevice(device);
  console.log(`selectedOS=${details?.deviceProperties?.osVersionNumber ?? "unknown"}`);
  console.log(`developerMode=${details?.deviceProperties?.developerModeStatus ?? "unknown"}`);
  console.log(`ddiServicesAvailable=${details?.deviceProperties?.ddiServicesAvailable ?? "unknown"}`);
  if (details?.deviceProperties?.developerModeStatus !== "enabled") {
    throw new Error("Developer Mode is not enabled or could not be verified. On the selected device: Settings > Privacy & Security > Developer Mode; enable, restart, confirm, and unlock. Pairing/trusting the Mac alone is not sufficient.");
  }
  console.log("Device discovery and Developer Mode checked; app-specific signing/install/launch are separate checks.");
}

function generate() {
  run("xcodegen", ["generate"], { cwd: ipadDir });
}

function build(apps = Object.values(ipadApps)) {
  if (!process.env.FOX_DEVELOPMENT_TEAM) throw new Error("Set FOX_DEVELOPMENT_TEAM locally for a signed physical build. Simulator verification needs no Apple account.");
  const registration = process.env.FOX_IOS_REGISTER_DEVICE === "1";
  const selected = registration ? selectedDeviceDetails() : null;
  if (selected && inspectDevice(deviceIdentifier(selected))?.deviceProperties?.developerModeStatus !== "enabled") {
    throw new Error("Selected iPhone requires Developer Mode before the device build. Run `npm run iphone:doctor` and complete the on-device restart/confirmation; no app was installed.");
  }
  const destination = selected ? `id=${selected.hardwareProperties.udid}` : "generic/platform=iOS";
  generate();
  for (const app of apps) {
    run("xcodebuild", [
      "-project",
      projectPath,
      "-scheme",
      app.scheme,
      "-configuration",
      "Debug",
      "-destination",
      destination,
      "-destination-timeout",
      "30",
      "-derivedDataPath",
      derivedDataPath,
      "-allowProvisioningUpdates",
      ...(registration ? ["-allowProvisioningDeviceRegistration"] : []),
      `DEVELOPMENT_TEAM=${process.env.FOX_DEVELOPMENT_TEAM}`,
      "build"
    ]);
    const path = appPath(app);
    if (!existsSync(path)) {
      throw new Error(`Expected app bundle was not created: ${path}`);
    }
    console.log(`builtApp=${path}`);
  }
}

function install(apps = Object.values(ipadApps)) {
  const device = selectDevice();
  const missingApps = apps.filter((app) => !existsSync(appPath(app)));
  if (missingApps.length > 0) {
    build(missingApps);
  }
  for (const app of apps) {
    try {
      run("xcrun", ["devicectl", "device", "install", "app", "--device", device, appPath(app)]);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      if (message.includes("maximum number of installed apps using a free developer profile")) {
        throw new Error(
          `${message}\n\n` +
            `Cannot install ${app.label}: the selected device has reached Apple's free developer profile app limit.\n` +
            "Review installed development apps and explicitly choose any app to remove before retrying. This script will not uninstall apps or delete their data."
        );
      }
      throw error;
    }
  }
}

function urlForApp(app) {
  if (process.env.FOX_WEB_URL) {
    return process.env.FOX_WEB_URL;
  }
  return `http://${detectLanHost()}:${process.env.FOX_WEB_PORT ?? "5177"}${app.webPath}`;
}

function open(app = selectedApp()) {
  const device = selectDevice();
  console.log(`launching ${app.label} (${app.bundleId}) on ${device}`);
  const environment = app.key === "say" ? { FOX_WEB_URL: urlForApp(app) }
    : (process.env.FOX_PREPARE_DAY1_DRAFT === "1" || process.argv[4] === "day1") ? { FOX_PREPARE_DAY1_DRAFT: "1" }
    : (process.env.FOX_START_SCREEN === "vision" || process.argv[4] === "vision") ? { FOX_START_SCREEN: "vision" } : {};
  console.log(app.key === "fox" ? "Fox native: no Web/API server required." : `FOX_WEB_URL=${urlForApp(app)}`);
  try {
    const output = run(
      "xcrun",
      iosLaunchArguments({ device, bundleId: app.bundleId, environment,
        forceRestart: process.env.FOX_IOS_RELAUNCH === "1" }),
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
          `${app.label} launch was rejected at the iOS/iPadOS signature/profile/entitlement/trust security check; this error alone does not distinguish those causes.\n` +
          "On the selected device, check Settings > General > VPN & Device Management. If the actual profile is untrusted, trust/verify it while online, then retry. If already trusted, check signature validity, profile expiry, device registration and entitlements; do not repeatedly trust or uninstall the app as a substitute for diagnosis."
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

function startChild(command, args, env, cwd = root) {
  return spawn(command, args, {
    cwd,
    stdio: "inherit",
    env: {
      ...process.env,
      ...env
    }
  });
}

function lanRuntimeConfig() {
  const lanHost = detectLanHost();
  const apiPort = process.env.FOX_API_PORT ?? "4177";
  const webPort = process.env.FOX_WEB_PORT ?? "5177";
  const webPath = process.env.FOX_WEB_PATH ?? "";
  const apiUrl = `http://${lanHost}:${apiPort}`;
  const webUrl = `http://${lanHost}:${webPort}${webPath}`;
  return { apiPort, apiUrl, webPort, webUrl };
}

function startLanChildren({ databasePath } = {}) {
  const { apiPort, apiUrl, webPort, webUrl } = lanRuntimeConfig();
  const apiEnv = {
    FOX_API_HOST: "0.0.0.0",
    FOX_API_PORT: apiPort
  };
  if (databasePath) {
    apiEnv.FOX_DB_PATH = databasePath;
  }
  const children = [
    startChild(bin("tsx"), ["watch", "--tsconfig", "tsconfig.dev.json", "src/server.ts"], {
      ...apiEnv
    }, join(root, "apps", "api")),
    startChild(bin("vite"), ["--host", "0.0.0.0", "--port", webPort], {
      VITE_FOX_API_URL: apiUrl
    }, join(root, "apps", "web-runtime"))
  ];
  return { apiUrl, webUrl, children };
}

function startMacInputBridge(apiPort) {
  return startChild(process.execPath, [join(root, "scripts", "fox-say-mac-input-bridge.mjs")], {
    FOX_API_PORT: apiPort,
    FOX_SAY_MAC_BRIDGE_API_URL: `http://127.0.0.1:${apiPort}`
  });
}

function stopChildren(children, signal = "SIGTERM") {
  for (const child of children) {
    child.kill(signal);
  }
}

async function waitForChildExit(children) {
  await new Promise((resolveExit, rejectExit) => {
    let settled = false;
    for (const child of children) {
      child.on("exit", (code, signal) => {
        if (settled) {
          return;
        }
        settled = true;
        if (code && code !== 0) {
          rejectExit(new Error(`LAN child exited with code ${code}`));
          return;
        }
        if (signal) {
          resolveExit();
          return;
        }
        resolveExit();
      });
    }
  });
}

async function smoke() {
  const app = selectedApp();
  if (app.key === "fox") {
    build([app]);
    install([app]);
    open(app);
    console.log("Native Fox build/install/launch smoke complete. No LAN runtime was started.");
    return;
  }
  const { apiUrl, webUrl, children } = startLanChildren({ databasePath: join(root, ".tmp", "ipad-smoke.sqlite") });
  try {
    await waitForUrl(`${apiUrl}/health`, "fox API");
    await waitForUrl(webUrl, "fox web runtime");
    build(Object.values(ipadApps));
    install(Object.values(ipadApps));
    process.env.FOX_WEB_URL = `${webUrl}${app.webPath}`;
    open(app);
    console.log("Smoke complete. Temporary LAN servers are stopping; use `npm run ipad:run` for hands-on iPad testing.");
  } finally {
    stopChildren(children);
  }
}

async function runIpad() {
  const app = selectedApp();
  if (app.key === "fox") {
    build([app]);
    install([app]);
    open(app);
    return;
  }
  const { apiUrl, webUrl, children } = startLanChildren();
  let shuttingDown = false;
  const shutdown = (signal) => {
    shuttingDown = true;
    stopChildren(children, signal);
  };
  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  try {
    await waitForUrl(`${apiUrl}/health`, "fox API");
    await waitForUrl(webUrl, "fox web runtime");
    if (app.key === "say" && process.env.FOX_SAY_MAC_BRIDGE !== "0") {
      children.push(startMacInputBridge(lanRuntimeConfig().apiPort));
      console.log("Fox Say Mac clipboard bridge is live. Dictation remains manual paste with Command-V.");
    }
    process.env.FOX_WEB_URL = `${webUrl}${app.webPath}`;
    open(app);
    console.log(`${app.label} iPad runtime is live at ${process.env.FOX_WEB_URL}. Press Ctrl+C to stop.`);
    await waitForChildExit(children);
  } catch (error) {
    if (!shuttingDown) {
      throw error;
    }
  } finally {
    stopChildren(children);
  }
}

function testNativeCore() {
  run("xcrun", ["swift", "test", "--package-path", join(ipadDir, "FoxTrainingCore"), "--scratch-path", join(root, ".tmp", "native-core-build"),
    ...(process.env.FOX_SWIFT_TEST_FILTER ? ['--filter', process.env.FOX_SWIFT_TEST_FILTER] : [])]);
}

function buildSimulator() {
  generate();
  for (const app of Object.values(ipadApps)) {
    run('xcodebuild', ['-project', projectPath, '-scheme', app.scheme, '-configuration', 'Debug',
      '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', join(root, '.tmp/ipad-simulator-data'),
      'CODE_SIGNING_ALLOWED=NO', 'build']);
  }
}

function testNativeUI() {
  generate();
  const devices = JSON.parse(run("xcrun", ["simctl", "list", "devices", "available", "--json"], { capture: true }));
  const ipads = Object.values(devices.devices ?? {}).flat().filter((device) => device.name.includes("iPad"));
  const deviceId = process.env.FOX_IOS_SIMULATOR ?? ipads.find((device) => device.name.includes("11-inch"))?.udid ?? ipads[0]?.udid;
  if (!deviceId) {
    throw new Error("No available iPad simulator. Install an iOS simulator runtime in Xcode first.");
  }
  // Reload only the simulator test harness; preserve the Fox app and its data.
  run("xcrun", ["simctl", "bootstatus", deviceId, "-b"]);
  run("xcrun", ["simctl", "uninstall", deviceId, "com.whipa.fox.uitests.xctrunner"]);
  const derivedData = process.env.FOX_IOS_UI_DERIVED_DATA ?? join(root, ".tmp", "ipad-simulator-data");
  const tests = (process.env.FOX_IOS_UI_TEST ?? "FoxUITests").split(",").map((value) => value.trim()).filter(Boolean);
  if (!tests.length) throw new Error('No native tests selected');
  run("xcodebuild", ["-project", projectPath, "-scheme", "Fox", "-configuration", "Debug",
    "-destination", `platform=iOS Simulator,id=${deviceId}`, "-derivedDataPath", derivedData,
    "-parallel-testing-enabled", "NO", ...tests.map((value) => `-only-testing:${value}`), "CODE_SIGNING_ALLOWED=NO", "test"]);
}

const command = process.argv[2] ?? "doctor";

try {
  if (command === "doctor") {
    doctor();
  } else if (command === "generate") {
    generate();
  } else if (command === "build") {
    build(appSelection(process.argv[3], { defaultToAll: true }));
  } else if (command === "install") {
    install(appSelection(process.argv[3], { defaultToAll: true }));
  } else if (command === "open") {
    open(selectedApp());
  } else if (command === "smoke") {
    await smoke();
  } else if (command === "run") {
    await runIpad();
  } else if (command === "test-core") {
    testNativeCore();
  } else if (command === "test-ui") {
    testNativeUI();
  } else if (command === "build-simulator") {
    buildSimulator();
  } else {
    throw new Error(`Unknown command: ${command}`);
  }
} catch (error) {
  if (['doctor', 'build', 'install', 'open', 'smoke', 'run'].includes(command)) {
    console.error(`device_condition=${classifyDeviceError(error.message ?? String(error))}; this is not a motion-algorithm result`);
  }
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
}
