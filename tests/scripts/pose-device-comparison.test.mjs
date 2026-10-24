import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyDeviceReplay, numericallyEqual } from '../../scripts/pose-device-comparison.mjs';

function fixture() {
  const videoSHA256 = 'a'.repeat(64);
  const header = { schema: 'fox.pose_comparison_cache.v1', platform: 'iOS', source: 'device-video-not-camera', videoSHA256 };
  const row = { seconds: 0, width: 1280, height: 720, imageSHA256: 'd'.repeat(64), people: [] };
  const deviceCache = { header, rows: [row], sha256: 'b'.repeat(64) };
  const device = { schema: 'fox.pose_comparison_evaluation.v1', backend: 'vision', videoSHA256, inputSHA256: deviceCache.sha256,
    platform: 'iOS', inferencePlatform: 'iOS', configuration: { angle: 1 }, runtimePolicy: {}, segments: [{ count: 5, peak: 2 }] };
  const macCache = structuredClone(deviceCache); macCache.header.platform = 'macOS';
  const mac = structuredClone(device); mac.platform = 'macOS';
  return { videoSHA256, device, host: structuredClone(device), mac, deviceCache, macCache,
    status: { schema: 'fox.ipad_pose_probe_status.v1', phase: 'completed', source: 'device-video-not-camera', platform: 'iOS', error: null } };
}
test('accepts completed isolated video and identical same-pose replay', () => {
  assert.equal(verifyDeviceReplay(fixture()).frames, 1);
});
test('same total cannot conceal different event timing in target vs host replay', () => {
  const f = fixture(); f.host.segments[0].peak = 2.1;
  assert.throws(() => verifyDeviceReplay(f), /core replay/);
});
test('rejects unfinished status and cache mismatch', () => {
  const f = fixture(); f.status.phase = 'extracting';
  assert.throws(() => verifyDeviceReplay(f), /not completed/);
  f.status.phase = 'completed'; f.device.inputSHA256 = 'wrong';
  assert.throws(() => verifyDeviceReplay(f), /source mismatch/);
});
test('rejects changed counter parameters or misaligned samples', () => {
  const f = fixture(); f.mac.configuration.angle = 2;
  assert.throws(() => verifyDeviceReplay(f), /parameters/);
  f.mac.configuration.angle = 1; f.macCache.rows[0].seconds = 0.1;
  assert.throws(() => verifyDeviceReplay(f), /alignment/);
});
test('PNG differences remain explicit instead of claiming identical platform pixels', () => {
  const f = fixture(); f.deviceCache.rows[0].imageSHA256 = 'e'.repeat(64);
  assert.equal(verifyDeviceReplay(f).differentEncodedPNGs, 1);
});
test('rejects a report relabeled as iPad without device inference provenance', () => {
  const f = fixture(); f.device.inferencePlatform = 'macOS';
  assert.throws(() => verifyDeviceReplay(f), /provenance/);
});
test('numeric replay parity is order independent and only tolerates rounding noise', () => {
  assert.equal(numericallyEqual({ b: 1, a: [2] }, { a: [2 + 1e-12], b: 1 }), true);
  assert.equal(numericallyEqual({ a: 2 }, { a: 2.01 }), false);
  assert.equal(numericallyEqual({ a: NaN }, { a: NaN }), false);
});
