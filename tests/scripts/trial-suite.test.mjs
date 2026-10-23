import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {Writable} from 'node:stream';
import * as suiteModule from '../../scripts/trial-suite.mjs';
import {runSuite, checkXCTestLog, suiteSteps, compareHistory} from '../../scripts/trial-suite.mjs';

test('suite has actual controller, phone/pad UI, real speech, wire and per-event history gates', () => {
  const steps = suiteSteps('/run', {ipad: 'pad', iphone: 'phone'}, [], {catalogue: [
    {id: 'FoxAppTests/Example/testOne', file: 'apps/ipad/FoxAppTests/Example.swift', scope: 'public', surface: 'ipad'},
    {id: 'FoxAppTests/NativeSpeechTests/testSpeech', file: 'apps/ipad/FoxAppTests/NativeSpeechTests.swift', scope: 'real-speech', surface: 'ipad'},
    {id: 'tests/scripts/nested/test_example.py', file: 'tests/scripts/nested/test_example.py', scope: 'public'}]});
  for (const id of ['core', 'journal', 'wire', 'history', 'app-host', 'ipad-ui', 'iphone-ui', 'real-speech', 'web', 'web-flow']) {
    assert.ok(steps.some(x => x.id === id), id);
  }
  assert.equal(steps.find(x => x.id === 'core').env.FOX_GUIDANCE_REQUIRE_PRIVATE, '1');
  assert.match(steps.find(x => x.id === 'app-host').env.FOX_IOS_UI_TEST, /FoxAppTests/);
  assert.match(steps.find(x => x.id === 'real-speech').env.FOX_IOS_UI_TEST, /NativeSpeechTests/);
  assert.deepEqual(steps.find(x => x.id === 'mapping').args, ['scripts/run-python-tests.py', 'tests/scripts/nested/test_example.py']);
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

test('cancellation during the last successful command cannot become a passed suite', async t => {
  const {dir, steps} = await harness(t);
  await assert.rejects(runSuite({directory:dir, steps:steps.slice(0,1), fingerprint:async()=> 'same', preflight:async()=>[],
    execute:async()=> { process.emit('SIGTERM'); return {code:0,output:'command completed after cancellation'}; }}), /cancelled/);
  assert.equal(JSON.parse(await readFile(path.join(dir,'suite.json'))).status,'cancelled');
});

test('private bytes changing after otherwise green steps invalidate the receipt', async t => {
  const {dir, steps} = await harness(t); let n = 0;
  await assert.rejects(runSuite({directory:dir, steps, fingerprint:async()=> 'same', preflight:async()=>[++n],
    execute:async()=>({code:0,output:'done'})}), /inputs changed/);
  assert.equal(JSON.parse(await readFile(path.join(dir,'suite.json'))).status,'failed');
});

test('cancellation during the final input recheck cannot publish success', async t => {
  const {dir, steps} = await harness(t); let checks = 0;
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same',
    preflight: async () => { if (++checks === 2) process.emit('SIGTERM'); return []; },
    execute: async () => ({code: 0, output: 'done'})}), /cancelled/);
  assert.equal(JSON.parse(await readFile(path.join(dir, 'suite.json'))).status, 'cancelled');
});

test('a timed-out child exiting zero is a failure, not a green receipt', async t => {
  const {dir} = await harness(t);
  const step = {id: 'timeout', command: process.execPath, timeoutMs: 800,
    args: ['-e', "process.on('SIGTERM', () => process.exit(0)); console.log('ready'); setInterval(() => {}, 50)"]};
  await assert.rejects(runSuite({directory: dir, steps: [step], fingerprint: async () => 'same',
    preflight: async () => []}), /timed out/);
  assert.match(await readFile(path.join(dir, 'timeout.log'), 'utf8'), /ready/);
  assert.equal(JSON.parse(await readFile(path.join(dir, 'suite.json'))).status, 'failed');
});

test('pre-cancelled execution and unavailable logs never spawn a child', async t => {
  const {dir} = await harness(t); const marker = path.join(dir, 'spawned');
  const step = {command: process.execPath, args: ['-e', `require('fs').writeFileSync(${JSON.stringify(marker)}, 'spawned')`]};
  const controller = new AbortController(); controller.abort();
  await assert.rejects(suiteModule.execute(step, {logPath: path.join(dir, 'cancelled.log'), signal: controller.signal}), /abort|cancel/i);
  const logPath = path.join(dir, 'existing.log'); await writeFile(logPath, 'keep');
  await assert.rejects(suiteModule.execute(step, {logPath}), /EEXIST/);
  await assert.rejects(readFile(marker), {code: 'ENOENT'});
  assert.equal(await readFile(logPath, 'utf8'), 'keep');
});

test('a mid-stream logging error terminates the child and retains a failed receipt', async t => {
  const {dir} = await harness(t); let pid;
  const log = new Writable({write(chunk, encoding, callback) {
    pid = Number(chunk.toString().trim()); callback(Error('synthetic disk full'));
  }});
  const step = {id: 'logging', command: process.execPath,
    args: ['-e', 'console.log(process.pid); setInterval(() => {}, 50)']};
  await assert.rejects(runSuite({directory: dir, steps: [step], fingerprint: async () => 'same',
    preflight: async () => [], execute: (s, options) => suiteModule.execute(s, {...options, openLog: async () => log})}), /disk full/);
  assert.ok(pid > 0);
  assert.throws(() => process.kill(pid, 0), {code: 'ESRCH'});
  assert.equal(JSON.parse(await readFile(path.join(dir, 'suite.json'))).status, 'failed');
});

test('failed resource cleanup cannot leave a successful suite receipt', async t => {
  const {dir, steps} = await harness(t);
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same', preflight: async () => [],
    execute: async () => ({code: 0, output: 'done'}), finalize: async () => { throw Error('simulator cleanup failed'); }}), /cleanup/);
  const receipt = JSON.parse(await readFile(path.join(dir, 'suite.json')));
  assert.equal(receipt.status, 'failed');
  assert.match(receipt.finalizationError, /cleanup/);
});

test('failed preflight still finalizes resources and finalization cancellation cannot pass', async t => {
  const first = await harness(t); let cleaned = false;
  await assert.rejects(runSuite({directory: first.dir, steps: first.steps, preflight: async () => { throw Error('preflight failed'); },
    finalize: async () => { cleaned = true; }}), /preflight failed/);
  assert.equal(cleaned, true);
  const second = await harness(t);
  await assert.rejects(runSuite({directory: second.dir, steps: second.steps, fingerprint: async () => 'same',
    preflight: async () => [], execute: async () => ({code: 0, output: 'done'}),
    finalize: async () => { process.emit('SIGTERM'); }}), /cancelled/);
  assert.equal(JSON.parse(await readFile(path.join(second.dir, 'suite.json'))).status, 'cancelled');
});
