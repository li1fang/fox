import assert from "node:assert/strict";
import test from "node:test";
import { selectPairedDevice } from "../../scripts/ios-device-selection.mjs";

const device = (id, family, name = id, paired = true) => ({
  identifier: id,
  hardwareProperties: { deviceType: family, udid: `udid-${id}` },
  deviceProperties: { name },
  connectionProperties: { pairingState: paired ? "paired" : "unpaired" }
});
const ipad = device("tablet", "iPad");
const phone = device("phone", "iPhone");

test("legacy default still targets the iPad when a phone is connected", () => {
  assert.equal(selectPairedDevice([phone, ipad]), ipad);
});
test("phone-only selection never falls back to an iPad", () => {
  assert.equal(selectPairedDevice([phone, ipad], { family: "iPhone" }), phone);
  assert.throws(() => selectPairedDevice([ipad], { family: "iPhone" }), /No paired/);
  assert.throws(() => selectPairedDevice([ipad], { family: "iPhone", selector: "tablet" }), /cannot target/);
});
test("exact identifier, UDID and unique name are accepted; unknown or unpaired are rejected", () => {
  for (const selector of ["phone", "udid-phone"]) {
    assert.equal(selectPairedDevice([phone, ipad], { family: "iPhone", selector }), phone);
  }
  assert.throws(() => selectPairedDevice([device("phone", "iPhone", "phone", false)], { selector: "phone" }), /No paired/);
  assert.throws(() => selectPairedDevice([phone], { selector: "missing" }), /No paired/);
});
test("ambiguous phone or repeated display name requires an explicit unique ID", () => {
  const second = device("second", "iPhone", "phone");
  assert.throws(() => selectPairedDevice([phone, second], { family: "iPhone" }), /Multiple/);
  assert.throws(() => selectPairedDevice([phone, second], { family: "iPhone", selector: "phone" }), /Multiple/);
});
