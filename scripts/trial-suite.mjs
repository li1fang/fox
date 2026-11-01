#!/usr/bin/env node
import {spawn, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir, readFile, writeFile, rename, lstat, open} from 'node:fs/promises';
import {renameSync} from 'node:fs';
import {finished} from 'node:stream/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {isDeepStrictEqual} from 'node:util';
import {setTimeout as delay} from 'node:timers/promises';
import {artifact} from './trial-readiness.mjs';
import {auditNativeCoverage, auditNativeSelection, auditCommandOutput} from './verification-contracts.mjs';
import {environment, nativeScratchPath} from './development-environment.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const developerDir = process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer';

export function checkXCTestLog(output, allowedSkipClasses = []) {
  const cases = [...output.matchAll(/^Test Case '([^']+)' (passed|skipped|failed) /gm)];
  const passed = cases.filter(x => x[2] === 'passed').length;
  if (!passed) throw Error('No completed tests in native log');
  const failed = cases.filter(x => x[2] === 'failed');
  if (failed.length) throw Error(`Failed test: ${failed.map(x => x[1]).join(', ')}`);
  const skipped = cases.filter(x => x[2] === 'skipped').map(x => x[1]);
  for (const name of skipped) {
    if (!allowedSkipClasses.some(c => name.includes(`.${c} `) || name.startsWith(`${c}.`))) {
      throw Error(`Unexpected skipped test: ${name}`);
    }
  }
  return {passed, skipped};
}

export function compareHistory(before, after) {
  if (!before.some(x => x.complete)) throw Error('No complete historical replay');
  if (!isDeepStrictEqual(before, after)) throw Error('Historical event facts changed, even if total counts match');
}

export function suiteSteps(directory, devices, inputs = [], {scope = 'private', component = 'all', catalogue = []} = {}) {
  const python = environment.FOX_JOURNAL_PYTHON;
  const privateScope = scope === 'private';
  const asset = id => inputs.find(x => x.id === id)?.path;
  const selected = (target, surface) => catalogue.filter(x => x.id.startsWith(`${target}/`) && (!surface || x.surface === surface)
    && (x.scope === 'public' || privateScope && x.scope === 'private')).map(x => x.id);
  const coreTests = selected('FoxTrainingCoreTests');
  const pythonTests = catalogue.filter(x => x.file.startsWith('tests/scripts/') && x.file.endsWith('.py')
    && (x.scope === 'public' || privateScope && x.scope === 'private')).map(x => x.file);
  const ui = (id, tests, device, allowedSkipClasses = []) => ({id, command: 'node', args: ['scripts/ipad.mjs', 'test-ui'],
    timeoutMs: (id === 'ipad-ui' ? 60 : 45) * 60 * 1000,
    native: true, allowedSkipClasses, expectedNative: tests.split(','), env: {FOX_IOS_UI_TEST: tests, FOX_IOS_SIMULATOR: device,
      FOX_IOS_UI_RESULT: path.join(directory, `${id}.xcresult`),
      TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST: privateScope ? process.env.FOX_PRIVATE_INPUT_MANIFEST : '',
      TEST_RUNNER_FOX_M3_EVIDENCE_DIR: directory,
      TEST_RUNNER_FOX_REAL_SPEECH: privateScope ? '1' : '0',
      TEST_RUNNER_FOX_GUIDANCE_REPLAY_INPUT: privateScope ? path.join(directory, 'guidance-cache-evidence.json') : ''}});
  const steps = [
    {id: 'boundaries', command: 'node', args: ['scripts/repository-checks.mjs']},
    {id: 'web', command: 'npm', args: ['run', 'verify'], audit: 'web'},
    ...(scope !== 'fast' ? [{id: 'web-flow', command: 'npm', args: ['run', 'test:e2e'], audit: 'browser'}] : [])
  ];
  if (component === 'web') return steps;
  if (component === 'native') steps.splice(1);
  steps.push(
    {id: 'core', resource: 'mac-native', command: 'npm', args: ['run', 'test:native'], native: true, env: {
      FOX_GUIDANCE_REQUIRE_PRIVATE: privateScope ? '1' : '0', FOX_GUIDANCE_EVIDENCE_DIR: directory,
      FOX_SWIFT_TEST_FILTER: coreTests.map(x => x.split('/').slice(-2).join('/')).join('|'),
      FOX_R2_EVIDENCE_DIR: directory, FOX_M3_EVIDENCE_DIR: directory}, expectedNative: coreTests},
    {id: 'journal', resource: 'mac-native', command: 'npm', args: ['run', 'test:journal'], native: true, expectedNative: selected('FoxJournalCoreTests')},
    {id: 'sync-native', resource: 'mac-native', command: 'npm', args: ['run', 'test:sync:native'], native: true, expectedNative: selected('FoxSyncCoreTests')},
    {id: 'mapping', command: python, args: ['scripts/run-python-tests.py', ...pythonTests], audit: 'python'},
    {id: 'wire', command: python, args: ['scripts/validate-vision-schema.py', directory, ...(privateScope ? [asset('history.trials')] : [])]},
    {id: 'pulldown-wire', command: python, args: ['scripts/validate-pulldown-schema.py', directory]},
    {id: 'strategy-wire', command: python, args: ['scripts/validate-motion-contracts.py']});
  if (privateScope) steps.push(
    {id: 'private-scripts', command: 'node', args: ['scripts/test-scripts.mjs', 'private'], audit: 'node'},
    {id: 'history', resource: 'mac-native', command: 'xcrun', args: ['swift', 'run', '--package-path', 'apps/ipad/FoxTrainingCore',
      '--scratch-path', nativeScratchPath('native-core-build'), 'fox-pose-replay',
      asset('history.trials'), '--current-runtime'], historyBaseline: asset('history.baseline')});
  if (scope !== 'fast') steps.push(
    {id: 'native-build', resource: 'mac-native', command: 'node', args: ['scripts/ipad.mjs', 'build-simulator']},
    ui('app-host', selected('FoxAppTests', 'ipad').join(','), devices.ipad),
    ui('ipad-ui', selected('FoxUITests', 'ipad').join(','), devices.ipad),
    ui('iphone-ui', [...selected('FoxAppTests', 'iphone'), ...selected('FoxUITests', 'iphone')].join(','), devices.iphone));
  if (privateScope) steps.push(ui('real-speech', catalogue.filter(x => x.scope === 'real-speech').map(x => x.id).join(','), devices.ipad));
  auditNativeSelection(catalogue, steps, {scope, component});
  return steps;
}

export async function fingerprint() {
  const result = spawnSync('git', ['ls-files', '-co', '--exclude-standard', '-z'], {cwd: root, encoding: 'utf8'});
  if (result.status !== 0) throw Error('Cannot enumerate candidate sources');
  const files = [...new Set(result.stdout.split('\0'))].filter(Boolean).sort();
  const rows = [];
  for (const file of files) {
    const location = path.join(root, file), stat = await lstat(location);
    if (!stat.isFile()) throw Error(`Unsupported candidate source: ${file}`);
    rows.push({path: file, sha256: createHash('sha256').update(await readFile(location)).digest('hex')});
  }
  if (!rows.length) throw Error('Empty candidate source');
  const commit = spawnSync('git', ['rev-parse', 'HEAD'], {cwd: root, encoding: 'utf8'});
  if (commit.status !== 0) throw Error('Cannot identify candidate commit');
  return createHash('sha256').update(JSON.stringify({commit: commit.stdout.trim(), files: rows})).digest('hex');
}

const openLogFile = async filename => (await open(filename, 'wx')).createWriteStream();

export function readProcessTable({launch = spawn, timeoutMs = 3000} = {}) {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const child = launch('ps', ['-axo', 'pid=,ppid=,pgid=,stat=,lstart='], {stdio: ['ignore', 'pipe', 'pipe']});
    let output = '', errorOutput = '', done = false;
    const inventory = {exited: false, exitCode: null, signal: null, stdoutEnded: false, stderrEnded: false};
    const finish = error => {
      if (done) return;
      done = true; clearTimeout(timer);
      if (error) {
        const elapsedMs = performance.now() - started;
        error.inventoryChild = child;
        error.inventory = {...inventory, pid: child.pid ?? null, timeoutMs, elapsedMs,
          deadlineOverrunMs: Math.max(0, elapsedMs - timeoutMs),
          stdoutBytes: Buffer.byteLength(output), stderrBytes: Buffer.byteLength(errorOutput)};
        // Do not wait for close after the observation budget. A stuck ps is
        // unknown cleanup, never proof that the native resource is free.
        try { child.kill('SIGKILL'); } catch {}
        child.stdout?.destroy(); child.stderr?.destroy(); child.unref();
        reject(error);
      } else resolve(output);
    };
    const timer = setTimeout(() => finish(Object.assign(Error('Process inventory timed out'),
      {code: 'FOX_PROCESS_INVENTORY_TIMEOUT'})), timeoutMs);
    // Exit plus both EOFs is sufficient; close can be delayed after those facts.
    // Exit alone is not sufficient: inherited output may still be open.
    const complete = () => {
      if (inventory.exited && inventory.stdoutEnded && inventory.stderrEnded) {
        finish(inventory.exitCode === 0 && inventory.signal === null ? undefined :
          Error(`Process inventory failed (${inventory.exitCode}, ${inventory.signal}): ${errorOutput}`));
      }
    };
    child.on('exit', (code, signal) => {
      inventory.exited = true; inventory.exitCode = code; inventory.signal = signal ?? null; complete();
    });
    child.stdout?.on('end', () => { inventory.stdoutEnded = true; complete(); });
    child.stderr?.on('end', () => { inventory.stderrEnded = true; complete(); });
    child.stdout?.on('error', finish); child.stderr?.on('error', finish);
    child.on('error', finish);
    child.on('close', code => finish(code === 0 ? undefined : Error(`Process inventory failed (${code}): ${errorOutput}`)));
    child.stdout?.on('data', bytes => {
      output += bytes;
      if (output.length > 2 * 1024 * 1024) finish(Error('Process inventory exceeded budget'));
    });
    child.stderr?.on('data', bytes => { errorOutput += bytes; });
  });
}

// Swift can put a compiler child in a new process group. Remember observed
// descendants by PID + start time, without inspecting or killing other jobs.
export function ownedProcessObserver(pgid, table = readProcessTable) {
  const known = new Map();
  let pending;
  return () => pending ??= (async () => {
    const rows = (await table()).trim().split('\n').filter(Boolean).map(line => {
      const match = line.trim().match(/^(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)$/);
      if (!match) throw Error('Cannot parse process ownership inventory');
      return {pid: +match[1], parent: +match[2], group: +match[3], state: match[4], identity: match[5]};
    });
    for (const row of rows) if (known.has(row.pid) && known.get(row.pid) !== row.identity) known.delete(row.pid);
    const present = new Set(rows.filter(r => known.get(r.pid) === r.identity || r.group === pgid).map(r => r.pid));
    let previous;
    do {
      previous = present.size;
      for (const row of rows) if (present.has(row.parent)) present.add(row.pid);
    } while (previous !== present.size);
    for (const row of rows) if (present.has(row.pid)) known.set(row.pid, row.identity);
    return rows.filter(r => present.has(r.pid) && !r.state.startsWith('Z')).map(r => r.pid);
  })().finally(() => { pending = undefined; });
}

export async function settleProcessGroup(pgid, {observe = ownedProcessObserver(pgid),
  kill = process.kill.bind(process), pause = delay, timeoutMs = 5000} = {}) {
  const deadline = Date.now() + timeoutMs;
  try {
    while (true) {
      const remaining = await observe();
      if (!remaining.length) return;
      for (const pid of [-pgid, ...remaining]) {
        try { kill(pid, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
      }
      if (Date.now() >= deadline) throw Error(`Processes did not settle: ${remaining.join(', ')}`);
      await pause(25);
    }
  } catch (error) {
    throw Object.assign(Error(`Resource cleanup uncertain: ${error.message}`), {resourceCleanupUncertain: true});
  }
}

export async function execute(step, {logPath, signal, openLog = openLogFile, forwardOutput = false, launch = spawn, processObserver = ownedProcessObserver} = {}) {
  signal?.throwIfAborted();
  // Secure the log before spawning; a broken log is a failed run, even when the child exits zero.
  const log = await openLog(logPath);
  return new Promise((resolve, reject) => {
    let child, forced, failure, observe, monitor, sampling, settled = Promise.resolve();
    const inventoryObservations = [], inventoryChildren = new Set();
    let stdout = '', stderr = '';
    const terminate = () => {
      if (!child?.pid) return;
      try { process.kill(-child.pid, 'SIGTERM'); } catch {}
      observe?.().then(pids => { for (const pid of pids) { try { process.kill(pid, 'SIGTERM'); } catch {} } }).catch(() => {});
      forced ??= setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 5000);
    };
    const logFinished = finished(log, {cleanup: true}).catch(error => { failure ??= error; terminate(); });
    if (signal?.aborted) {
      log.destroy();
      logFinished.then(() => reject(Error('Command cancelled')));
      return;
    }
    const cancel = () => { failure ??= Error('Command cancelled'); terminate(); };
    child = launch(step.command, step.args, {cwd: root, env: {...environment, ...step.env},
      detached: true, stdio: ['ignore', 'pipe', 'pipe']});
    // Failed stdio allocation can return a child with null pipes. Keep its
    // asynchronous error inside the normal receipt/log finalization path.
    child.on('error', error => { failure ??= error; });
    if (child.pid) {
      observe = processObserver(child.pid);
      // A missed observation is not evidence that the original command stopped.
      // Keep its process handle and lease, and ask the same observer again. The
      // strict final inventory/cleanup still has to succeed before release.
      const sample = () => sampling ??= observe().catch(error => {
        if (error.code === 'FOX_PROCESS_INVENTORY_TIMEOUT') {
          const entry = {observedAt: new Date().toISOString(), error: error.message, inventory: error.inventory};
          inventoryObservations.push(entry);
          if (error.inventoryChild) inventoryChildren.add(error.inventoryChild);
          if (!log.destroyed) log.write(`FOX_PROCESS_INVENTORY_RETRY ${JSON.stringify(entry)}\n`);
          return;
        }
        failure ??= error; failure.resourceCleanupUncertain = true; terminate();
      }).finally(() => { sampling = undefined; });
      void sample();
      monitor = setInterval(sample, 250);
    }
    const timeout = setTimeout(() => {
      failure ??= Error(`${step.id ?? step.command} timed out`); terminate();
    }, step.timeoutMs ?? 45 * 60 * 1000);
    signal?.addEventListener('abort', cancel, {once: true});
    // XCTest continues after this 60s expiry; every later gesture can incur it again.
    // Preserve the first diagnostic and fail closed, without disabling idle checking or retrying.
    const pendingLines = {stdout: '', stderr: ''};
    const detectIdleExpiry = (stream, chunk) => {
      if (!step.native || failure) return;
      const output = pendingLines[stream] + chunk.toString();
      pendingLines[stream] = output.slice(output.lastIndexOf('\n') + 1);
      if (/(?:^|\n)\s*t =\s*\d+(?:\.\d+)?s App animations complete notification not received, will attempt to continue\./.test(output)) {
        failure ??= Error('native_automation_idle_timeout: XCTest did not receive animation-idle completion; retain logs and diagnose before rerunning');
        terminate();
      }
    };
    child.stdout?.on('data', chunk => { stdout += chunk.toString(); if (!log.destroyed) log.write(chunk); if (forwardOutput) process.stdout.write(chunk); detectIdleExpiry('stdout', chunk); });
    child.stderr?.on('data', chunk => { stderr += chunk.toString(); if (!log.destroyed) log.write(chunk); if (forwardOutput) process.stderr.write(chunk); detectIdleExpiry('stderr', chunk); });
    child.on('exit', () => {
      clearInterval(monitor);
      // Start at exit, not close: a surviving child may still hold the log pipe.
      settled = settleProcessGroup(child.pid, {observe}).catch(error => {
        failure ??= error; failure.resourceCleanupUncertain = true;
        child.stdout?.destroy(); child.stderr?.destroy();
      });
    });
    child.on('close', async (code, childSignal) => {
      clearInterval(monitor);
      await settled;
      clearTimeout(timeout); clearTimeout(forced); signal?.removeEventListener('abort', cancel);
      if (!log.destroyed) log.end();
      await logFinished;
      clearTimeout(forced);
      if ([...inventoryChildren].some(helper => helper.exitCode === null && helper.signalCode === null)) {
        failure ??= Error('Timed-out process inventory helper has not exited');
        failure.resourceCleanupUncertain = true;
      }
      if (failure) { failure.inventoryObservations = inventoryObservations; reject(failure); }
      else resolve({code, signal: childSignal, stdout, output: stdout + '\n' + stderr, liveLog: true, inventoryObservations});
    });
  });
}

export async function runSuite({directory, steps, fingerprint: sourceFingerprint = fingerprint, preflight, execute: run = execute, finalize, writeReceipt = writeFile, metadata = {}}) {
  await mkdir(directory, {recursive: true});
  const filename = path.join(directory, 'suite.json');
  const receipt = {schema: 'fox.trial_suite.v1', status: 'running', startedAt: new Date().toISOString(),
    ...metadata, sourceSHA256: null, inputs: [], steps: [], deviceVerified: false};
  try { await writeReceipt(filename, JSON.stringify(receipt, null, 2) + '\n', {flag: 'wx'}); }
  catch (error) { if (error.code === 'EEXIST') throw Error('Suite receipt already exists; use a fresh run directory'); throw error; }
  const save = async () => {
    await writeReceipt(filename + '.tmp', JSON.stringify(receipt, null, 2) + '\n');
    await rename(filename + '.tmp', filename);
  };
  const cancellation = new AbortController();
  const cancel = () => cancellation.abort();
  process.on('SIGINT', cancel); process.on('SIGTERM', cancel);
  let failure, cleanupUncertain = false;
  try {
    receipt.inputs = await preflight({signal: cancellation.signal});
    if (!steps.length) throw Error('Empty verification scope');
    receipt.sourceSHA256 = await sourceFingerprint();
    await save();
    for (const step of steps) {
      if (cancellation.signal.aborted) throw Error('Suite cancelled');
      if (await sourceFingerprint() !== receipt.sourceSHA256) throw Error('Source changed during suite; rerun candidate');
      const item = {id: step.id, command: [step.command, ...step.args], environment: step.env ?? {}, status: 'running', startedAt: new Date().toISOString()};
      receipt.steps.push(item); await save();
      process.stdout.write(`trial-suite: ${step.id}\n`);
      try {
        const result = await run(step, {logPath: path.join(directory, `${step.id}.log`), signal: cancellation.signal});
        if (result.resourceAdmission) item.resourceAdmission = result.resourceAdmission;
        if (result.inventoryObservations?.length) item.inventoryObservations = result.inventoryObservations;
        item.exitCode = result.code; item.signal = result.signal ?? null;
        if (!result.liveLog) await writeFile(path.join(directory, `${step.id}.log`), result.output);
        item.log = await artifact(directory, `${step.id}.log`);
        if (cancellation.signal.aborted) throw Error('Suite cancelled');
        if (result.code !== 0) throw Error(`${step.id} failed (exit ${result.code})`);
        if (step.native) item.tests = step.expectedNative ? auditNativeCoverage(result.output, step.expectedNative) : checkXCTestLog(result.output, step.allowedSkipClasses);
        if (step.audit) item.tests = auditCommandOutput(result.output, step.audit);
        if (step.historyBaseline) {
          const before = JSON.parse(await readFile(step.historyBaseline, 'utf8')), after = JSON.parse(result.stdout);
          compareHistory(before, after);
          await writeFile(path.join(directory, 'history-candidate.json'), JSON.stringify(after, null, 2) + '\n');
          item.comparison = {complete: after.filter(x => x.complete).length, unavailable: after.filter(x => !x.complete).length};
        }
        if (await sourceFingerprint() !== receipt.sourceSHA256) throw Error('Source changed during suite; rerun candidate');
        item.status = 'passed';
      } catch (error) {
        cleanupUncertain ||= error.resourceCleanupUncertain === true;
        item.status = 'failed'; item.error = error.message;
        if (error.inventory) item.inventory = error.inventory;
        if (error.inventoryObservations?.length) item.inventoryObservations = error.inventoryObservations;
        if (error.resourceAdmission) item.resourceAdmission = error.resourceAdmission;
        throw error;
      }
      finally { item.finishedAt = new Date().toISOString(); await save(); }
    }
    // Re-read private bytes at the end too; source stability alone is insufficient.
    if (!isDeepStrictEqual(await preflight({signal: cancellation.signal}), receipt.inputs)) throw Error('Private inputs changed during suite');
    if (cancellation.signal.aborted) throw Error('Suite cancelled');
    if (await sourceFingerprint() !== receipt.sourceSHA256) throw Error('Source changed during suite; rerun candidate');
    if (cancellation.signal.aborted) throw Error('Suite cancelled');
    receipt.status = 'software_suite_passed';
  } catch (error) {
    cleanupUncertain ||= error.resourceCleanupUncertain === true;
    receipt.status = cancellation.signal.aborted ? 'cancelled' : 'failed'; receipt.error = error.message; failure = error;
  } finally {
    try {
      if (cleanupUncertain) throw Error('Retain resource ownership: unsafe process cleanup; inspect receipt before recovery');
      await finalize?.();
    } catch (error) {
      receipt.finalizationError = error.message;
      if (receipt.status !== 'cancelled') receipt.status = 'failed';
      failure ??= error;
    }
    const applyCancellation = () => {
      if (!cancellation.signal.aborted) return false;
      receipt.status = 'cancelled'; receipt.error ??= 'Suite cancelled during finalization';
      failure ??= Error(receipt.error); return true;
    };
    try {
      // Yield to queued OS signals too; process.emit alone does not test this boundary.
      await new Promise(setImmediate);
      applyCancellation();
      receipt.finishedAt = new Date().toISOString();
      let writtenStatus;
      do {
        writtenStatus = receipt.status;
        await writeReceipt(filename + '.terminal.tmp', JSON.stringify(receipt, null, 2) + '\n');
        await new Promise(setImmediate);
        applyCancellation();
      } while (writtenStatus !== receipt.status);
      // Single completion commit point. Until this rename, the public receipt is still running.
      // No asynchronous work or cancellation-dependent correction follows the commit.
      renameSync(filename + '.terminal.tmp', filename);
    } finally {
      process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel);
    }
  }
  if (failure) throw failure;
  return receipt;
}

async function main() {
  const directory = process.argv[2];
  if (!directory) throw Error('Usage: npm run test:trial -- <fresh-evidence-directory>');
  const {runVerification} = await import('./verify.mjs');
  await runVerification({scope: 'private', output: path.resolve(directory)});
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
