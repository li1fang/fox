import assert from "node:assert/strict";
import test from "node:test";
import { iosLaunchArguments } from "../../scripts/ios-launch-policy.mjs";

const target = { device: "phone-only", bundleId: "com.whipa.fox" };
test("ordinary native open activates without terminating unsubmitted input", () => {
  const args = iosLaunchArguments(target);
  assert.equal(args.includes("--terminate-existing"), false);
  assert.equal(args.includes("--environment-variables"), false);
  assert.equal(args.at(-1), target.bundleId);
  assert.equal(args[args.indexOf("--device") + 1], target.device);
});
test("explicit day1, vision or Say URL launch still starts with requested environment", () => {
  for (const environment of [{ FOX_PREPARE_DAY1_DRAFT: "1" }, { FOX_START_SCREEN: "vision" }, { FOX_WEB_URL: "http://localhost" }]) {
    const args = iosLaunchArguments({ ...target, environment });
    assert.equal(args.includes("--terminate-existing"), true);
    assert.deepEqual(JSON.parse(args[args.indexOf("--environment-variables") + 1]), environment);
  }
});
test("forced restart is opt-in and does not add unrelated environment", () => {
  const args = iosLaunchArguments({ ...target, forceRestart: true });
  assert.equal(args.includes("--terminate-existing"), true);
  assert.equal(args.includes("--environment-variables"), false);
});
