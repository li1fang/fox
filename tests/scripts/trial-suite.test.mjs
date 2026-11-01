import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {Writable, PassThrough} from 'node:stream';
import {EventEmitter} from 'node:events';
import {spawn} from 'node:child_process';
import * as suiteModule from '../../scripts/trial-suite.mjs';
import {runSuite, checkXCTestLog, suiteSteps, compareHistory} from '../../scripts/trial-suite.mjs';
import {auditReceipt} from '../../scripts/verification-contracts.mjs';

test('device UI selection follows the catalogue without forcing pad experiments onto phone', () => {
  const lab = 'FoxUITests/FoxVisionUITests/testGuidanceOverlayAndMuteRemainAvailableAcrossRotation';
  const phone = 'FoxUITests/FoxFreeCaptureUITests/testPhoneLaunchKeepsSavedExperimentsAccessibleWithoutCapture';
  const steps = suiteSteps('/run', {ipad: 'pad', iphone: 'phone'}, [], {scope: 'public', catalogue: [
    {id: 'FoxAppTests/Example/testHost', file: 'apps/ipad/FoxAppTests/Example.swift', scope: 'public', surface: 'ipad'},
    {id: lab, file: 'apps/ipad/FoxUITests/FoxVisionUITests.swift', scope: 'public', surface: 'ipad'},
    {id: phone, file: 'apps/ipad/FoxUITests/FoxFreeCaptureUITests.swift', scope: 'public', surface: 'iphone'}
  ]});
  assert.equal(steps.find(x => x.id === 'ipad-ui').env.FOX_IOS_UI_TEST, lab);
  assert.equal(steps.find(x => x.id === 'iphone-ui').env.FOX_IOS_UI_TEST, phone);
});

test('unresponsive process inventory is killed and detached from the observer within its budget', {timeout: 1000}, async () => {
  const child = new EventEmitter(), signals = [];
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  child.kill = signal => { signals.push(signal); return false; };
  let detached = false; child.unref = () => { detached = true; };
  await assert.rejects(suiteModule.readProcessTable({launch: () => child, timeoutMs: 20}), /timed out/);
  assert.deepEqual(signals, ['SIGKILL']);
  assert.ok(detached && child.stdout.destroyed && child.stderr.destroyed);
});

test('inventory launch failure without stdio remains a caught error', async () => {
  const child = new EventEmitter();
  child.kill = () => false; child.unref = () => {};
  await assert.rejects(suiteModule.readProcessTable({launch: () => {
    queueMicrotask(() => child.emit('error', Object.assign(Error('EMFILE'), {code: 'EMFILE'})));
    return child;
  }}), /EMFILE/);
});

test('command launch failure without stdio seals its failed receipt and log', async t => {
  const {dir} = await harness(t);
  const script = `
    import {EventEmitter} from 'node:events';
    import {runSuite, execute} from ${JSON.stringify(new URL('../../scripts/trial-suite.mjs', import.meta.url).href)};
    const launch = () => {
      const child = new EventEmitter();
      child.stdout = null; child.stderr = null;
      queueMicrotask(() => {
        child.emit('error', Object.assign(Error('fixture EMFILE'), {code: 'EMFILE'}));
        child.emit('close', -1, null);
      });
      return child;
    };
    try {
      await runSuite({directory: ${JSON.stringify(dir)}, steps: [{id:'launch',command:'synthetic',args:[]}],
        fingerprint: async () => 'same', preflight: async () => [],
        execute: (step, options) => execute(step, {...options, launch})});
      process.exit(2);
    } catch (error) {
      console.log(error.message);
      process.exit(error.code === 'EMFILE' ? 0 : 3);
    }
  `;
  const child = spawn(process.execPath, ['--input-type=module', '-e', script], {stdio: ['ignore', 'pipe', 'pipe']});
  let output = '';
  child.stdout.on('data', bytes => { output += bytes; }); child.stderr.on('data', bytes => { output += bytes; });
  const code = await new Promise(resolve => child.on('close', resolve));
  assert.equal(code, 0, output);
  const receipt = JSON.parse(await readFile(path.join(dir, 'suite.json')));
  assert.equal(receipt.status, 'failed'); assert.equal(receipt.steps[0].status, 'failed');
  assert.match(receipt.error, /fixture EMFILE/);
  assert.equal(await readFile(path.join(dir, 'launch.log'), 'utf8'), '');
});

test('a receipt write error cannot erase unsafe cleanup and release a live lease', async t => {
  const {dir, steps} = await harness(t); let released = false;
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same', preflight: async () => [],
    execute: async () => { throw Object.assign(Error('unsafe child'), {resourceCleanupUncertain: true}); },
    writeReceipt: async (filename, body, options) => {
      if (filename.endsWith('suite.json.tmp') && JSON.parse(body).steps[0]?.status === 'failed') throw Error('fixture disk full');
      return writeFile(filename, body, options);
    }, finalize: async () => { released = true; }}), /disk full/);
  assert.equal(released, false);
  assert.match(JSON.parse(await readFile(path.join(dir, 'suite.json'))).finalizationError, /retain|unsafe/i);
});

test('ownership observation follows known compiler descendants across groups without adopting foreign or reused PIDs', async () => {
  let table = '10 1 10 S START-A\n20 10 20 S START-B\n30 1 30 S FOREIGN';
  const observe = suiteModule.ownedProcessObserver(10, async () => table);
  assert.deepEqual(await observe(), [10, 20]);
  table = '20 1 20 S START-B\n30 1 30 S FOREIGN\n40 20 40 S START-C';
  assert.deepEqual(await observe(), [20, 40]);
  table = '20 1 20 S REUSED\n40 1 40 Z START-C\n50 20 50 S NOT-OURS';
  assert.deepEqual(await observe(), []);
});

test('process-group release waits for observed exit and treats unobservable cleanup as unsafe', async () => {
  let polls = 0; const killed = [];
  await suiteModule.settleProcessGroup(123, {observe: async () => ++polls < 3 ? [456] : [],
    kill: (pid, signal) => killed.push([pid, signal]), pause: async () => {}});
  assert.equal(polls, 3, 'sending a signal is not proof that a child exited');
  assert.ok(killed.some(([pid, signal]) => pid === -123 && signal === 'SIGKILL'));
  await assert.rejects(suiteModule.settleProcessGroup(123, {observe: async () => { throw Error('ps unavailable'); }}),
    error => error.resourceCleanupUncertain === true);
});

test('unsafe process cleanup preserves the lease instead of calling finalizers', async t => {
  const {dir, steps} = await harness(t); let released = false;
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same', preflight: async () => [],
    execute: async () => { throw Object.assign(Error('unknown process state'), {resourceCleanupUncertain: true}); },
    finalize: async () => { released = true; }}), /unknown/);
  assert.equal(released, false);
  assert.match(JSON.parse(await readFile(path.join(dir, 'suite.json'))).finalizationError, /retain|unsafe/i);
});

test('preflight resource waiting receives cancellation and cannot create devices afterwards', async t => {
  const {dir, steps} = await harness(t);
  let created = false;
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same',
    preflight: async ({signal}) => {
      process.emit('SIGTERM');
      signal.throwIfAborted();
      created = true;
      return [];
    }}));
  assert.equal(created, false);
  assert.equal(JSON.parse(await readFile(path.join(dir, 'suite.json'))).status, 'cancelled');
});

test('suite has actual controller, phone/pad UI, real speech, wire and per-event history gates', () => {
  const steps = suiteSteps('/run', {ipad: 'pad', iphone: 'phone'}, [], {catalogue: [
    {id: 'FoxUITests/Phone/testTraining', file: 'apps/ipad/FoxUITests/Phone.swift', scope: 'public', surface: 'iphone'},
    {id: 'FoxSyncCoreTests/Sync/testTransport', file: 'apps/ipad/FoxSyncCore/Tests/FoxSyncCoreTests/Sync.swift', scope: 'public', surface: 'host'},
    {id: 'FoxAppTests/Example/testOne', file: 'apps/ipad/FoxAppTests/Example.swift', scope: 'public', surface: 'ipad'},
    {id: 'FoxAppTests/NativeSpeechTests/testSpeech', file: 'apps/ipad/FoxAppTests/NativeSpeechTests.swift', scope: 'real-speech', surface: 'ipad'},
    {id: 'FoxUITests/FoxVisionUITests/testGuidanceOverlayAndMuteRemainAvailableAcrossRotation', file: 'apps/ipad/FoxUITests/FoxVisionUITests.swift', scope: 'public', surface: 'ipad'},
    {id: 'tests/scripts/nested/test_example.py', file: 'tests/scripts/nested/test_example.py', scope: 'public'}]});
  for (const id of ['core', 'journal', 'sync-native', 'wire', 'history', 'app-host', 'ipad-ui', 'iphone-ui', 'real-speech', 'web', 'web-flow']) {
    assert.ok(steps.some(x => x.id === id), id);
  }
  assert.equal(steps.find(x => x.id === 'core').env.FOX_GUIDANCE_REQUIRE_PRIVATE, '1');
  assert.deepEqual(steps.find(x => x.id === 'sync-native').expectedNative, ['FoxSyncCoreTests/Sync/testTransport']);
  assert.match(steps.find(x => x.id === 'app-host').env.FOX_IOS_UI_TEST, /FoxAppTests/);
  assert.match(steps.find(x => x.id === 'real-speech').env.FOX_IOS_UI_TEST, /NativeSpeechTests/);
  assert.equal(steps.find(x => x.id === 'ipad-ui').timeoutMs, 60 * 60 * 1000);
  for (const step of steps.filter(x => x.args.includes('test-ui'))) {
    assert.equal(step.env.FOX_IOS_UI_RESULT, `/run/${step.id}.xcresult`);
  }
  assert.deepEqual(steps.find(x => x.id === 'mapping').args, ['scripts/run-python-tests.py', 'tests/scripts/nested/test_example.py']);
});

test('suite construction rejects eligible native cases omitted by a routing filter', () => {
  assert.throws(() => suiteSteps('/run', {ipad: 'pad', iphone: 'phone'}, [], {scope: 'public', catalogue: [
    {id: 'FoxAppTests/Example/testOmitted', file: 'apps/ipad/FoxAppTests/Example.swift', scope: 'public'},
    {id: 'FoxUITests/FoxVisionUITests/testGuidanceOverlayAndMuteRemainAvailableAcrossRotation',
      file: 'apps/ipad/FoxUITests/FoxVisionUITests.swift', scope: 'public', surface: 'ipad'}
  ]}), /selection.*missing.*testOmitted/);
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

test('native animation-idle expiry stops the process, retains evidence and does not run later gates', async t => {
  const {dir} = await harness(t); let later = false;
  const step = {id: 'native-idle', native: true, command: process.execPath, timeoutMs: 4000,
    args: ['-e', `process.on('SIGTERM', () => process.exit(0));
      process.stderr.write('    t = 72.45s App animations complete notification not received,');
      setTimeout(() => process.stderr.write(' will attempt to continue.\\n'), 25);
      setInterval(() => {}, 50);`]};
  await assert.rejects(runSuite({directory: dir, steps: [step, {id: 'later', command: 'fake', args: []}],
    fingerprint: async () => 'same', preflight: async () => [], execute: async (s, options) => {
      if (s.id === 'later') later = true;
      return suiteModule.execute(s, options);
    }}), /native_automation_idle_timeout/);
  assert.equal(later, false);
  const receipt = JSON.parse(await readFile(path.join(dir, 'suite.json')));
  assert.equal(receipt.status, 'failed');
  assert.match(receipt.steps[0].error, /native_automation_idle_timeout/);
  assert.match(await readFile(path.join(dir, 'native-idle.log'), 'utf8'), /will attempt to continue/);
});

test('animation-idle detector accepts normal native waits and does not interpret non-native quoted logs', async t => {
  const {dir} = await harness(t);
  const warning = '    t = 72.45s App animations complete notification not received, will attempt to continue.';
  const plain = await suiteModule.execute({id: 'plain', command: process.execPath,
    args: ['-e', `console.log(${JSON.stringify(warning)})`]}, {logPath: path.join(dir, 'plain.log')});
  assert.equal(plain.code, 0);
  const normal = await suiteModule.execute({id: 'normal', native: true, command: process.execPath,
    args: ['-e', `console.log('    t = 1.20s Wait for com.whipa.fox to idle'); console.log('quoted: ${warning.trim()}')`]},
    {logPath: path.join(dir, 'normal.log')});
  assert.equal(normal.code, 0);
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

test('an OS cancellation queued during cleanup cannot publish a successful receipt', async t => {
  const {dir} = await harness(t);
  const script = `import {runSuite} from ${JSON.stringify(new URL('../../scripts/trial-suite.mjs', import.meta.url).href)};
    import {spawnSync} from 'node:child_process';
    try {
      await runSuite({directory: ${JSON.stringify(dir)}, steps: [{id:'one',command:'fake',args:[]}],
        fingerprint:async()=> 'same', preflight:async()=> [], execute:async()=> ({code:0,output:'done'}),
        finalize:async()=> { console.log('READY_FOR_SIGNAL'); spawnSync(process.execPath, ['-e','setTimeout(()=>{},800)']); }});
      process.exit(0);
    } catch(error) { console.error(error.message); process.exit(1); }`;
  const child = spawn(process.execPath, ['--input-type=module', '-e', script], {stdio: ['ignore', 'pipe', 'pipe']});
  const timeout = setTimeout(() => child.kill('SIGKILL'), 5000);
  t.after(() => { clearTimeout(timeout); if (child.exitCode === null && !child.signalCode) child.kill('SIGKILL'); });
  let signalled = false;
  child.stdout.on('data', chunk => { if (!signalled && chunk.toString().includes('READY_FOR_SIGNAL')) { signalled = true; child.kill('SIGTERM'); } });
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
  assert.equal(signalled, true);
  assert.equal(code, 1);
  assert.equal(JSON.parse(await readFile(path.join(dir, 'suite.json'))).status, 'cancelled');
});

test('cancellation plus a failed final write never leaves a reusable success', async t => {
  const {dir, steps} = await harness(t); let cancelling = false;
  await assert.rejects(runSuite({directory: dir, steps, fingerprint: async () => 'same', preflight: async () => [],
    execute: async () => ({code: 0, output: 'done'}),
    writeReceipt: async (file, content, options) => {
      const state = JSON.parse(content).status;
      if (cancelling && state === 'cancelled') throw Object.assign(Error('synthetic disk full'), {code: 'ENOSPC'});
      await writeFile(file, content, options);
      if (state === 'software_suite_passed') { cancelling = true; process.emit('SIGTERM'); }
    }}), /disk full/);
  assert.equal(cancelling, true);
  const receipt = JSON.parse(await readFile(path.join(dir, 'suite.json')));
  assert.notEqual(receipt.status, 'software_suite_passed');
  assert.throws(() => auditReceipt(receipt, {commit: undefined, sourceSHA256: 'same', scope: undefined}), /Incomplete/);
});


test('inventory timeout identifies the sampled child and observation budget without asserting OS exit state', async () => {
  const child = new EventEmitter(); child.pid = 4242;
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  child.kill = () => {}; child.unref = () => {};
  await assert.rejects(suiteModule.readProcessTable({launch:()=>child,timeoutMs:20}), error =>
    error.inventory?.pid === 4242 && error.inventory?.timeoutMs === 20 &&
    error.inventory?.elapsedMs >= 20 && error.inventory?.deadlineOverrunMs >= 0 &&
    error.inventory?.exited === false && error.inventory?.stdoutBytes === 0);
});

test('inventory accepts exited command with both output EOFs without waiting for close', async () => {
  for (const order of ['exit-first', 'eof-first']) {
    const child = new EventEmitter();
    child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.kill = () => {}; child.unref = () => {};
    const result = suiteModule.readProcessTable({timeoutMs: 40, launch: () => {
      queueMicrotask(() => {
        child.stdout.write('10 1 10 S START-A\n');
        if (order === 'exit-first') child.emit('exit', 0, null);
        child.stdout.end(); child.stderr.end();
        if (order === 'eof-first') setImmediate(() => child.emit('exit', 0, null));
      });
      return child;
    }});
    assert.equal(await result, '10 1 10 S START-A\n');
  }
});

test('inventory exit without output EOF fails closed with lifecycle diagnostics', async () => {
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  child.kill = () => {}; child.unref = () => {};
  await assert.rejects(suiteModule.readProcessTable({timeoutMs: 20,launch: () => {
    queueMicrotask(() => child.emit('exit', 0, null)); return child;
  }}), error => error.message.includes('timed out') && error.inventory?.exited === true &&
    error.inventory?.stdoutEnded === false && error.inventory?.stderrEnded === false);
});

test('inventory EOF without exit and stream failures do not imply command success', async () => {
  for (const mode of ['no-exit', 'stream-error', 'nonzero', 'oversize']) {
    const child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.kill = () => {}; child.unref = () => {};
    await assert.rejects(suiteModule.readProcessTable({timeoutMs: 20, launch: () => {
      queueMicrotask(() => {
        if (mode === 'oversize') child.stdout.write('x'.repeat(2*1024*1024+1));
        if (mode === 'stream-error') child.stdout.emit('error', Error('synthetic stream failure'));
        child.stdout.end(); child.stderr.end();
        if (mode === 'nonzero') child.emit('exit', 1, null);
      }); return child;
    }}), mode === 'oversize' ? /exceeded budget/ : mode === 'stream-error' ? /stream failure/ : mode === 'nonzero' ? /failed/ : /timed out/);
  }
});

test('failed suite preserves bounded inventory lifecycle diagnostics', async t => {
  const {dir, steps} = await harness(t);
  const inventory = {exited: true, exitCode: 0, stdoutEnded: false, stderrEnded: true, stdoutBytes: 0};
  await assert.rejects(runSuite({directory:dir,steps,fingerprint:async()=> 'same',preflight:async()=>[],
    execute:async()=>{throw Object.assign(Error('Process inventory timed out'), {inventory});}}));
  assert.deepEqual(JSON.parse(await readFile(path.join(dir,'suite.json'))).steps[0].inventory, inventory);
});

test('a transient inventory timeout keeps the same live command and records recovery', async t => {
  const dir=await mkdtemp(path.join(tmpdir(),'fox-inventory-recovery-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));
  let observations=0, watchedPID;
  const result=await suiteModule.execute({id:'live-inventory-recovery',command:process.execPath,
    args:['-e',"console.log('original-started');setTimeout(()=>console.log('original-finished'),700)"],timeoutMs:2500},
    {logPath:path.join(dir,'command.log'),processObserver:pid=>{
      watchedPID=pid;const real=suiteModule.ownedProcessObserver(pid);
      return async()=>{ if(observations++===0) throw Object.assign(Error('Process inventory timed out'),
        {code:'FOX_PROCESS_INVENTORY_TIMEOUT',inventory:{pid:424242,timeoutMs:3000,exited:false}});return real(); };
    }});
  assert.ok(watchedPID>0);assert.equal(result.code,0);
  assert.match(result.output,/original-started/);assert.match(result.output,/original-finished/);
  assert.equal(result.inventoryObservations.length,1);
  assert.equal(result.inventoryObservations[0].inventory.pid,424242);
  assert.match(await readFile(path.join(dir,'command.log'),'utf8'),/FOX_PROCESS_INVENTORY_RETRY/);
});

test('natural command completion cannot release resources while inventory stays unavailable', async t => {
  const dir=await mkdtemp(path.join(tmpdir(),'fox-inventory-unknown-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));
  await assert.rejects(suiteModule.execute({id:'inventory-unknown',command:process.execPath,
    args:['-e',"console.log('original-started');setTimeout(()=>console.log('original-finished'),400)"],timeoutMs:2000},
    {logPath:path.join(dir,'command.log'),processObserver:()=>async()=>{
      throw Object.assign(Error('Process inventory timed out'),{code:'FOX_PROCESS_INVENTORY_TIMEOUT',inventory:{pid:424243}});
    }}),error=>error.resourceCleanupUncertain===true);
  assert.match(await readFile(path.join(dir,'command.log'),'utf8'),/original-finished/);
});

test('a timed-out inventory helper must exit even when a later table is available', async t => {
  const dir=await mkdtemp(path.join(tmpdir(),'fox-inventory-helper-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));
  let calls=0;
  await assert.rejects(suiteModule.execute({id:'inventory-helper',command:process.execPath,
    args:['-e',"setTimeout(()=>console.log('original-finished'),350)"],timeoutMs:1800},
    {logPath:path.join(dir,'command.log'),processObserver:pid=>{
      const real=suiteModule.ownedProcessObserver(pid);
      return async()=>{if(calls++===0)throw Object.assign(Error('Process inventory timed out'),
        {code:'FOX_PROCESS_INVENTORY_TIMEOUT',inventory:{pid:424244},inventoryChild:{exitCode:null,signalCode:null}});return real();};
    }}),error=>error.resourceCleanupUncertain===true && /helper has not exited/.test(error.message));
});

test('successful suite retains transient inventory diagnostics without a restart', async t => {
  const {dir}=await harness(t);let calls=0;
  await runSuite({directory:dir,steps:[{id:'same-command',command:process.execPath,
    args:['-e',"setTimeout(()=>console.log('original-finished'),350)"],timeoutMs:1800}],
    fingerprint:async()=> 'fixed',preflight:async()=>[],execute:(step,options)=>suiteModule.execute(step,
      {...options,processObserver:pid=>{const real=suiteModule.ownedProcessObserver(pid);return async()=>{
        if(calls++===0)throw Object.assign(Error('Process inventory timed out'),
          {code:'FOX_PROCESS_INVENTORY_TIMEOUT',inventory:{pid:424245}});return real();};}})});
  const receipt=JSON.parse(await readFile(path.join(dir,'suite.json'),'utf8'));
  assert.equal(receipt.status,'software_suite_passed');assert.equal(receipt.steps.length,1);
  assert.equal(receipt.steps[0].inventoryObservations[0].inventory.pid,424245);
});
