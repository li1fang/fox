import {spawnSync, execFile} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';

export const root = fileURLToPath(new URL('..', import.meta.url));
export const developerDir = process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer';
export const python = process.env.FOX_JOURNAL_PYTHON ?? path.join(root, '.venv/bin/python');
export const environment = {...process.env, PATH: `${path.dirname(process.execPath)}:${process.env.PATH}`,
  DEVELOPER_DIR: developerDir, FOX_JOURNAL_PYTHON: python, PYTHONDONTWRITEBYTECODE: '1'};

function capture(command, args) {
  const result = spawnSync(command, args, {cwd: root, env: environment, encoding: 'utf8'});
  if (result.error || result.status !== 0) throw Error(`environment_failure: ${command}: ${result.error?.message ?? result.stderr}`);
  return result.stdout.trim();
}
async function captureAsync(command, args) {
  const result = await promisify(execFile)(command, args, {cwd: root, env: environment, encoding: 'utf8',
    timeout: 60_000, killSignal: 'SIGKILL'});
  return result.stdout.trim();
}
function run(command, args) {
  const result = spawnSync(command, args, {cwd: root, env: environment, stdio: 'inherit'});
  if (result.error || result.status !== 0) throw Error(`Environment setup failed: ${command}`);
}

export function doctor({native = process.platform === 'darwin', dependencies = true} = {}) {
  if (Number(process.versions.node.split('.')[0]) !== 22) throw Error('environment_failure: Node 22 required; use .node-version (no global runtime is changed)');
  const result = {node: process.version, platform: process.platform, arch: process.arch,
    npm: capture('npm', ['--version']), physicalDevicesInspected: false};
  if (dependencies && !existsSync(path.join(root, 'node_modules/.package-lock.json'))) throw Error('environment_failure: run npm run bootstrap first');
  if (native) {
    if (process.platform !== 'darwin') throw Error('environment_failure: native tier requires macOS');
    result.python = capture(python, ['--version']);
    if (!/^Python 3\.12\./.test(result.python)) throw Error('environment_failure: Python 3.12 required');
    result.schemaLibraries = JSON.parse(capture(python, ['-c', 'import importlib.metadata as m,json; from jsonschema import FormatChecker; assert "date-time" in FormatChecker.checkers; print(json.dumps({n:m.version(n) for n in ["jsonschema","referencing"]}))']));
    result.xcode = capture('xcodebuild', ['-version']);
    if (result.xcode !== 'Xcode 26.3\nBuild version 17C529') throw Error('environment_failure: expected Xcode 26.3 (17C529); set DEVELOPER_DIR explicitly');
    result.xcodegen = capture('xcodegen', ['--version']);
    if (!/^Version: 2\.45\./.test(result.xcodegen)) throw Error('environment_failure: XcodeGen 2.45.x required');
    result.swift = capture('xcrun', ['swift', '--version']);
    result.sdk = capture('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-version']);
    result.simulators = JSON.parse(capture('xcrun', ['simctl', 'list', 'devices', 'available', '--json'])).devices;
  }
  return result;
}

export async function allocateSimulators(info, {execute = captureAsync, overrides = {
  ipad: process.env.FOX_TRIAL_IPAD_SIMULATOR, iphone: process.env.FOX_TRIAL_IPHONE_SIMULATOR}} = {}) {
  const available = Object.entries(info.simulators ?? {}).flatMap(([runtime, devices]) => devices.map(d => ({...d, runtime})));
  const lease = {devices: {}, created: [], selection: {}};
  try {
    for (const [key, family] of [['ipad', 'iPad'], ['iphone', 'iPhone']]) {
      const candidates = available.filter(d => d.deviceTypeIdentifier?.includes(`.${family}-`));
      const template = overrides[key] ? candidates.find(d => d.udid === overrides[key])
        : candidates.find(d => family !== 'iPad' || d.deviceTypeIdentifier.includes('11-inch')) ?? candidates[0];
      if (!template) throw Error(`environment_failure: missing ${family} simulator runtime or invalid override; install a compatible runtime in Xcode`);
      const id = overrides[key] ?? (await execute('xcrun', ['simctl', 'create', `FoxVerification-${family}-${randomUUID()}`,
        template.deviceTypeIdentifier, template.runtime])).trim();
      if (!overrides[key]) {
        if (!/^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(id)) throw Error('environment_failure: simulator creation returned an invalid identifier');
        lease.created.push(id);
      }
      lease.devices[key] = id;
      lease.selection[key] = {id, runtime: template.runtime, deviceType: template.deviceTypeIdentifier, owned: !overrides[key]};
    }
    return lease;
  } catch (error) {
    try { await releaseSimulators(lease, execute); }
    catch (cleanup) { throw Error(`${error.message}; ${cleanup.message}`); }
    throw error;
  }
}

export async function isolateSimulatorStep(lease, step, execute = captureAsync) {
  const target = step.env?.FOX_IOS_SIMULATOR;
  if (!target) return;
  if (!lease || !Object.values(lease.devices).includes(target)) throw Error('Simulator target does not belong to this lease');
  const parked = [];
  // Keep the selected simulator's data; stop only peers created by this run, never user overrides.
  for (const id of lease.created.filter(id => id !== target)) {
    try { await execute('xcrun', ['simctl', 'shutdown', id]); }
    catch (error) { if (!/current state: Shutdown/i.test(error.message)) throw error; }
    parked.push(id);
  }
  return {step: step.id, target, parked};
}

export async function releaseSimulators(lease, execute = captureAsync) {
  const errors = [];
  // Only IDs created by this invocation belong to this invocation. Overrides are never deleted.
  for (const id of lease.created) {
    try { await execute('xcrun', ['simctl', 'shutdown', id]); }
    catch (error) { if (!/current state: Shutdown/i.test(error.message)) errors.push(`${id}: ${error.message}`); }
    try { await execute('xcrun', ['simctl', 'delete', id]); }
    catch (error) { errors.push(`${id}: ${error.message}`); }
  }
  if (errors.length) throw Error(`simulator cleanup failed: ${errors.join('; ')}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv[2] === 'bootstrap') {
      if (Number(process.versions.node.split('.')[0]) !== 22) throw Error('Select Node 22 before bootstrap');
      run('npm', ['ci']);
      run('npx', ['playwright', 'install', 'chromium']);
      if (process.platform === 'darwin') {
        if (!existsSync(python)) {
          const interpreter = process.env.FOX_BOOTSTRAP_PYTHON ?? 'python3.12';
          run(interpreter, ['-m', 'venv', path.join(root, '.venv')]);
        }
        run(python, ['-m', 'pip', 'install', '-r', 'scripts/journal-schema-requirements.txt']);
      }
    }
    console.log(JSON.stringify(doctor(), null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
