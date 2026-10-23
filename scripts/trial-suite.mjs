#!/usr/bin/env node
import {spawn, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir, readFile, writeFile, rename, lstat, open} from 'node:fs/promises';
import {finished} from 'node:stream/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {isDeepStrictEqual} from 'node:util';
import {artifact} from './trial-readiness.mjs';
import {auditNativeCoverage, auditCommandOutput} from './verification-contracts.mjs';
import {environment} from './development-environment.mjs';

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
    native: true, allowedSkipClasses, expectedNative: tests.split(','), env: {FOX_IOS_UI_TEST: tests, FOX_IOS_SIMULATOR: device,
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
    {id: 'core', command: 'npm', args: ['run', 'test:native'], native: true, env: {
      FOX_GUIDANCE_REQUIRE_PRIVATE: privateScope ? '1' : '0', FOX_GUIDANCE_EVIDENCE_DIR: directory,
      FOX_SWIFT_TEST_FILTER: coreTests.map(x => x.split('/').slice(-2).join('/')).join('|'),
      FOX_R2_EVIDENCE_DIR: directory, FOX_M3_EVIDENCE_DIR: directory}, expectedNative: coreTests},
    {id: 'journal', command: 'npm', args: ['run', 'test:journal'], native: true, expectedNative: selected('FoxJournalCoreTests')},
    {id: 'mapping', command: python, args: ['scripts/run-python-tests.py', ...pythonTests], audit: 'python'},
    {id: 'wire', command: python, args: ['scripts/validate-vision-schema.py', directory, ...(privateScope ? [asset('history.trials')] : [])]},
    {id: 'pulldown-wire', command: python, args: ['scripts/validate-pulldown-schema.py', directory]},
    {id: 'strategy-wire', command: python, args: ['scripts/validate-motion-contracts.py']});
  if (privateScope) steps.push(
    {id: 'private-scripts', command: 'node', args: ['scripts/test-scripts.mjs', 'private'], audit: 'node'},
    {id: 'history', command: 'xcrun', args: ['swift', 'run', '--package-path', 'apps/ipad/FoxTrainingCore',
      '--scratch-path', '.tmp/native-core-build', 'fox-pose-replay',
      asset('history.trials'), '--current-runtime'], historyBaseline: asset('history.baseline')});
  if (scope !== 'fast') steps.push(
    {id: 'native-build', command: 'node', args: ['scripts/ipad.mjs', 'build-simulator']},
    ui('app-host', selected('FoxAppTests', 'ipad').join(','), devices.ipad),
    ui('ipad-ui', selected('FoxUITests', 'ipad').join(','), devices.ipad),
    ui('iphone-ui', [...selected('FoxAppTests', 'iphone'), ...selected('FoxUITests', 'iphone'),
      'FoxUITests/FoxVisionUITests/testGuidanceOverlayAndMuteRemainAvailableAcrossRotation'].join(','), devices.iphone));
  if (privateScope) steps.push(ui('real-speech', catalogue.filter(x => x.scope === 'real-speech').map(x => x.id).join(','), devices.ipad));
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

export async function execute(step, {logPath, signal, openLog = openLogFile} = {}) {
  signal?.throwIfAborted();
  // Secure the log before spawning; a broken log is a failed run, even when the child exits zero.
  const log = await openLog(logPath);
  return new Promise((resolve, reject) => {
    let child, forced, failure;
    let stdout = '', stderr = '';
    const terminate = () => {
      if (!child?.pid) return;
      try { process.kill(-child.pid, 'SIGTERM'); } catch {}
      forced ??= setTimeout(() => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }, 5000);
    };
    const logFinished = finished(log, {cleanup: true}).catch(error => { failure ??= error; terminate(); });
    if (signal?.aborted) {
      log.destroy();
      logFinished.then(() => reject(Error('Command cancelled')));
      return;
    }
    const cancel = () => { failure ??= Error('Command cancelled'); terminate(); };
    child = spawn(step.command, step.args, {cwd: root, env: {...environment, ...step.env},
      detached: true, stdio: ['ignore', 'pipe', 'pipe']});
    const timeout = setTimeout(() => {
      failure ??= Error(`${step.id ?? step.command} timed out`); terminate();
    }, step.timeoutMs ?? 45 * 60 * 1000);
    signal?.addEventListener('abort', cancel, {once: true});
    child.stdout.on('data', chunk => { stdout += chunk.toString(); if (!log.destroyed) log.write(chunk); });
    child.stderr.on('data', chunk => { stderr += chunk.toString(); if (!log.destroyed) log.write(chunk); });
    child.on('error', error => { failure ??= error; });
    child.on('close', async (code, childSignal) => {
      clearTimeout(timeout); clearTimeout(forced); signal?.removeEventListener('abort', cancel);
      if (!log.destroyed) log.end();
      await logFinished;
      clearTimeout(forced);
      if (failure) reject(failure);
      else resolve({code, signal: childSignal, stdout, output: stdout + '\n' + stderr, liveLog: true});
    });
  });
}

export async function runSuite({directory, steps, fingerprint: sourceFingerprint = fingerprint, preflight, execute: run = execute, finalize, metadata = {}}) {
  await mkdir(directory, {recursive: true});
  const filename = path.join(directory, 'suite.json');
  const receipt = {schema: 'fox.trial_suite.v1', status: 'running', startedAt: new Date().toISOString(),
    ...metadata, sourceSHA256: null, inputs: [], steps: [], deviceVerified: false};
  try { await writeFile(filename, JSON.stringify(receipt, null, 2) + '\n', {flag: 'wx'}); }
  catch (error) { if (error.code === 'EEXIST') throw Error('Suite receipt already exists; use a fresh run directory'); throw error; }
  const save = async () => {
    await writeFile(filename + '.tmp', JSON.stringify(receipt, null, 2) + '\n');
    await rename(filename + '.tmp', filename);
  };
  const cancellation = new AbortController();
  const cancel = () => cancellation.abort();
  process.once('SIGINT', cancel); process.once('SIGTERM', cancel);
  try {
    receipt.inputs = await preflight();
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
      } catch (error) { item.status = 'failed'; item.error = error.message; throw error; }
      finally { item.finishedAt = new Date().toISOString(); await save(); }
    }
    // Re-read private bytes at the end too; source stability alone is insufficient.
    if (!isDeepStrictEqual(await preflight(), receipt.inputs)) throw Error('Private inputs changed during suite');
    if (cancellation.signal.aborted) throw Error('Suite cancelled');
    if (await sourceFingerprint() !== receipt.sourceSHA256) throw Error('Source changed during suite; rerun candidate');
    if (cancellation.signal.aborted) throw Error('Suite cancelled');
    receipt.status = 'software_suite_passed';
    return receipt;
  } catch (error) {
    receipt.status = cancellation.signal.aborted ? 'cancelled' : 'failed'; receipt.error = error.message; throw error;
  } finally {
    try {
      await finalize?.();
      if (cancellation.signal.aborted && receipt.status === 'software_suite_passed') {
        receipt.status = 'cancelled'; throw Error('Suite cancelled during finalization');
      }
    } catch (error) {
      receipt.finalizationError = error.message;
      if (receipt.status !== 'cancelled') receipt.status = 'failed';
      throw error;
    } finally {
      process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel);
      receipt.finishedAt = new Date().toISOString(); await save();
    }
  }
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
