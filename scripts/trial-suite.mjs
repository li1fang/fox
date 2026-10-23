#!/usr/bin/env node
import {spawn, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdir, readFile, writeFile, rename, lstat} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {isDeepStrictEqual} from 'node:util';
import {artifact} from './trial-readiness.mjs';

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

export function suiteSteps(directory, devices, baseline) {
  const python = process.env.FOX_JOURNAL_PYTHON ?? 'python3';
  const ui = (id, tests, device, allowedSkipClasses = []) => ({id, command: 'node', args: ['scripts/ipad.mjs', 'test-ui'],
    native: true, allowedSkipClasses, env: {FOX_IOS_UI_TEST: tests, FOX_IOS_SIMULATOR: device,
      TEST_RUNNER_FOX_REAL_SPEECH: '1', TEST_RUNNER_FOX_GUIDANCE_REPLAY_INPUT: path.join(directory, 'guidance-cache-evidence.json')}});
  return [
    {id: 'core', command: 'npm', args: ['run', 'test:native'], native: true, env: {
      FOX_GUIDANCE_REQUIRE_PRIVATE: '1', FOX_GUIDANCE_EVIDENCE_DIR: directory,
      FOX_R2_EVIDENCE_DIR: directory, FOX_M3_EVIDENCE_DIR: directory}},
    {id: 'journal', command: 'npm', args: ['run', 'test:journal'], native: true},
    {id: 'wire', command: python, args: ['scripts/validate-vision-schema.py', directory,
      '.tmp/strategy-v1/records-before/vision-trials.v1.json']},
    {id: 'pulldown-wire', command: python, args: ['scripts/validate-pulldown-schema.py', directory]},
    {id: 'strategy-wire', command: python, args: ['scripts/validate-motion-contracts.py']},
    {id: 'history', command: 'xcrun', args: ['swift', 'run', '--package-path', 'apps/ipad/FoxTrainingCore',
      '--scratch-path', '.tmp/native-core-build', 'fox-pose-replay',
      '.tmp/strategy-v1/records-before/vision-trials.v1.json', '--current-runtime'], historyBaseline: path.join(baseline, 'history-baseline.json')},
    // Phone-only host/layout skips on iPad are covered by a second, explicit phone batch.
    ui('app-host', 'FoxAppTests', devices.ipad, ['PhoneCameraLayoutTests']),
    ui('ipad-ui', 'FoxUITests', devices.ipad, ['FoxPhoneLayoutUITests']),
    ui('iphone-ui', 'FoxAppTests/PhoneCameraLayoutTests,FoxUITests/FoxPhoneLayoutUITests,FoxUITests/FoxVisionUITests/testGuidanceOverlayAndMuteRemainAvailableAcrossRotation', devices.iphone),
    ui('real-speech', 'FoxAppTests/NativeSpeechTests', devices.ipad),
    {id: 'web', command: 'npm', args: ['run', 'verify']},
    {id: 'web-flow', command: 'npm', args: ['run', 'test:e2e']}
  ];
}

async function fingerprint() {
  const result = spawnSync('git', ['ls-files', '-co', '--exclude-standard', '-z'], {cwd: root, encoding: 'utf8'});
  if (result.status !== 0) throw Error('Cannot enumerate candidate sources');
  const files = [...new Set(result.stdout.split('\0'))].filter(p => p && !p.startsWith('docs/') && p !== 'README.md').sort();
  const rows = [];
  for (const file of files) {
    const location = path.join(root, file), stat = await lstat(location);
    if (!stat.isFile()) throw Error(`Unsupported candidate source: ${file}`);
    rows.push({path: file, sha256: createHash('sha256').update(await readFile(location)).digest('hex')});
  }
  if (!rows.length) throw Error('Empty candidate source');
  return createHash('sha256').update(JSON.stringify(rows)).digest('hex');
}

async function execute(step) {
  return new Promise((resolve, reject) => {
    const child = spawn(step.command, step.args, {cwd: root, env: {...process.env, DEVELOPER_DIR: developerDir, ...step.env}, stdio: ['ignore', 'pipe', 'pipe']});
    let stdout = '', stderr = '';
    child.stdout.on('data', chunk => { stdout += chunk.toString(); });
    child.stderr.on('data', chunk => { stderr += chunk.toString(); });
    child.on('error', reject);
    child.on('close', (code, signal) => resolve({code, signal, stdout, output: stdout + '\n' + stderr}));
  });
}

export async function runSuite({directory, steps, fingerprint: sourceFingerprint = fingerprint, preflight, execute: run = execute}) {
  await mkdir(directory, {recursive: true});
  const filename = path.join(directory, 'suite.json');
  const receipt = {schema: 'fox.trial_suite.v1', status: 'running', startedAt: new Date().toISOString(),
    sourceSHA256: null, inputs: [], steps: [], deviceVerified: false};
  try { await writeFile(filename, JSON.stringify(receipt, null, 2) + '\n', {flag: 'wx'}); }
  catch (error) { if (error.code === 'EEXIST') throw Error('Suite receipt already exists; use a fresh run directory'); throw error; }
  const save = async () => {
    await writeFile(filename + '.tmp', JSON.stringify(receipt, null, 2) + '\n');
    await rename(filename + '.tmp', filename);
  };
  try {
    receipt.inputs = await preflight();
    receipt.sourceSHA256 = await sourceFingerprint();
    await save();
    for (const step of steps) {
      if (await sourceFingerprint() !== receipt.sourceSHA256) throw Error('Source changed during suite; rerun candidate');
      const item = {id: step.id, command: [step.command, ...step.args], environment: step.env ?? {}, status: 'running', startedAt: new Date().toISOString()};
      receipt.steps.push(item); await save();
      process.stdout.write(`trial-suite: ${step.id}\n`);
      try {
        const result = await run(step);
        item.exitCode = result.code; item.signal = result.signal ?? null;
        await writeFile(path.join(directory, `${step.id}.log`), result.output);
        item.log = await artifact(directory, `${step.id}.log`);
        if (result.code !== 0) throw Error(`${step.id} failed (exit ${result.code})`);
        if (step.native) item.tests = checkXCTestLog(result.output, step.allowedSkipClasses);
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
    receipt.status = 'software_suite_passed';
    return receipt;
  } catch (error) {
    receipt.status = 'failed'; receipt.error = error.message; throw error;
  } finally { receipt.finishedAt = new Date().toISOString(); await save(); }
}

async function main() {
  const directory = process.argv[2];
  if (!directory) throw Error('Usage: npm run test:trial -- <fresh-evidence-directory>');
  const output = path.resolve(directory);
  const baseline = path.join(root, '.data/trial-readiness/a0-20261023');
  const devicesResult = spawnSync('xcrun', ['simctl', 'list', 'devices', 'available', '--json'],
    {encoding: 'utf8', env: {...process.env, DEVELOPER_DIR: developerDir}});
  if (devicesResult.status !== 0) throw Error('Cannot enumerate iOS simulators');
  const devices = Object.values(JSON.parse(devicesResult.stdout).devices).flat();
  const selection = {
    ipad: process.env.FOX_TRIAL_IPAD_SIMULATOR ?? devices.find(x => x.name.includes('iPad') && x.name.includes('11-inch'))?.udid,
    iphone: process.env.FOX_TRIAL_IPHONE_SIMULATOR ?? devices.find(x => x.name.includes('iPhone'))?.udid
  };
  for (const [family, id] of Object.entries(selection)) {
    if (!devices.some(x => x.udid === id && x.name.includes(family === 'ipad' ? 'iPad' : 'iPhone'))) throw Error(`Missing ${family} simulator`);
  }
  const inputs = JSON.parse(await readFile(path.join(baseline, 'inputs.json'), 'utf8'));
  if (inputs.length !== 6) throw Error('Unexpected A0 input manifest');
  const preflight = async () => {
    const checked = [];
    for (const expected of inputs) {
      const actual = await artifact(root, expected.path);
      if (!isDeepStrictEqual(actual, expected)) throw Error(`Private input changed: ${expected.path}`);
      checked.push(actual);
    }
    checked.push(await artifact(baseline, 'history-baseline.json'));
    return checked;
  };
  const result = await runSuite({directory: output, steps: suiteSteps(output, selection, baseline), preflight});
  console.log(JSON.stringify({status: result.status, sourceSHA256: result.sourceSHA256, deviceVerified: false, receipt: path.join(output, 'suite.json')}));
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
