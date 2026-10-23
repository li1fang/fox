import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {runSuite, checkXCTestLog, suiteSteps, compareHistory} from '../../scripts/trial-suite.mjs';

test('suite has actual controller, phone/pad UI, real speech, wire and per-event history gates', () => {
  const steps = suiteSteps('/run', {ipad: 'pad', iphone: 'phone'}, '/baseline');
  for (const id of ['core', 'journal', 'wire', 'history', 'app-host', 'ipad-ui', 'iphone-ui', 'real-speech', 'web', 'web-flow']) {
    assert.ok(steps.some(x => x.id === id), id);
  }
  assert.equal(steps.find(x => x.id === 'core').env.FOX_GUIDANCE_REQUIRE_PRIVATE, '1');
  assert.match(steps.find(x => x.id === 'app-host').env.FOX_IOS_UI_TEST, /FoxAppTests/);
  assert.match(steps.find(x => x.id === 'real-speech').env.FOX_IOS_UI_TEST, /NativeSpeechTests/);
});

test('zero tests, unexpected skips and failures cannot pass XCTest audit', () => {
  assert.throws(() => checkXCTestLog('** TEST SUCCEEDED **'), /No completed tests/);
  const pass = "Test Case '-[FoxAppTests.Example testOne]' passed (0.1 seconds).";
  const skip = "Test Case '-[FoxAppTests.Private testCache]' skipped (0.1 seconds).";
  assert.throws(() => checkXCTestLog(pass + '\n' + skip), /Unexpected skipped/);
  assert.throws(() => checkXCTestLog(pass + "\nTest Case '-[FoxAppTests.Other testTwo]' failed (0.1 seconds)."), /Failed test/);
  assert.equal(checkXCTestLog(pass).passed, 1);
  const phone = "Test Case '-[FoxAppTests.PhoneCameraLayoutTests testLayout]' skipped (0.1 seconds).";
  assert.equal(checkXCTestLog(pass + '\n' + phone, ['PhoneCameraLayoutTests']).skipped.length, 1);
});

test('equal total counts cannot hide changed repetition timing or return facts', () => {
  const baseline = [{complete: true, candidateCount: 2, candidateRepetitions: [{completedAtSeconds: 2}]}];
  compareHistory(baseline, structuredClone(baseline));
  const changed = structuredClone(baseline); changed[0].candidateRepetitions[0].completedAtSeconds = 3;
  assert.throws(() => compareHistory(baseline, changed), /Historical event/);
  assert.throws(() => compareHistory([{complete: false}], [{complete: false}]), /No complete historical/);
});

async function harness(t) {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-suite-test-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  return {dir, steps: [{id: 'first', command: 'fake', args: []}, {id: 'second', command: 'fake', args: []}]};
}

test('failed gate stops subsequent execution and writes a failed receipt', async t => {
  const {dir, steps} = await harness(t); const called = [];
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same',
    preflight: async () => [], execute: async step => { called.push(step.id); return {code: 1, output: 'failure'}; }}), /first failed/);
  assert.deepEqual(called, ['first']);
  const receipt = JSON.parse(await readFile(path.join(dir, 'suite.json')));
  assert.equal(receipt.status, 'failed'); assert.equal(receipt.steps[0].status, 'failed');
});

test('missing input executes nothing; changing source invalidates successful commands', async t => {
  const {dir, steps} = await harness(t); let executed = 0;
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same',
    preflight: async () => { throw Error('missing private input'); }, execute: async () => { executed++; }}), /missing private/);
  assert.equal(executed, 0);
  await rm(path.join(dir, 'suite.json'));
  let fingerprints = 0;
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => ++fingerprints === 1 ? 'old' : 'new',
    preflight: async () => [], execute: async () => ({code: 0, output: 'done'})}), /Source changed/);
  assert.equal(JSON.parse(await readFile(path.join(dir, 'suite.json'))).status, 'failed');
});

test('successful software receipt does not claim trial readiness or device acceptance', async t => {
  const {dir, steps} = await harness(t);
  const result = await runSuite({directory: dir, steps, fingerprint: async () => 'same',
    preflight: async () => ['checked'], execute: async () => ({code: 0, output: 'done'})});
  assert.equal(result.status, 'software_suite_passed');
  assert.equal(result.deviceVerified, false);
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same',
    preflight: async () => [], execute: async () => ({code: 0, output: ''})}), /already exists/);
});
