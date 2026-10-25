import {spawnSync, execFile} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, writeFileSync, renameSync, rmSync} from 'node:fs';
import {homedir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';

export const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
export const developerDir = process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer';
export const python = process.env.FOX_JOURNAL_PYTHON ?? path.join(root, '.venv/bin/python');
export function xcodeConfiguration(id = process.env.FOX_XCODE_PROFILE ?? 'xcode-26.3') {
  const profiles = {
    'xcode-26.3': {version: 'Xcode 26.3\nBuild version 17C529', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-26-3'},
    'xcode-27.1': {version: 'Xcode 27.1\nBuild version 27A9275', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-1'}
  };
  if (!Object.hasOwn(profiles, id)) throw Error(`environment_failure: Unknown Xcode profile: ${id}`);
  return {id, ...profiles[id]};
}
const toolchain = xcodeConfiguration();
export const simulatorRuntime = process.env.FOX_SIMULATOR_RUNTIME ?? toolchain.runtime;
export function assertXcodeVersion(actual, profile = toolchain.id) {
  const expected = xcodeConfiguration(profile);
  if (actual !== expected.version) throw Error(`environment_failure: expected ${expected.version}; select FOX_XCODE_PROFILE and DEVELOPER_DIR explicitly`);
}
const sessionDirectory = path.join(homedir(), '.cache', 'fox', 'simulator-session');
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
    assertXcodeVersion(result.xcode);
    result.xcodeProfile = toolchain.id;
    result.xcodegen = capture('xcodegen', ['--version']);
    if (!/^Version: 2\.45\./.test(result.xcodegen)) throw Error('environment_failure: XcodeGen 2.45.x required');
    result.swift = capture('xcrun', ['swift', '--version']);
    result.sdk = capture('xcrun', ['--sdk', 'iphonesimulator', '--show-sdk-version']);
    result.simulators = JSON.parse(capture('xcrun', ['simctl', 'list', 'devices', 'available', '--json'])).devices;
    result.simulatorTypes = JSON.parse(capture('xcrun', ['simctl', 'list', 'devicetypes', '--json'])).devicetypes;
    result.simulatorRuntime = simulatorRuntime;
  }
  return result;
}

export function simulatorCandidates(info, runtime = info.simulatorRuntime ?? simulatorRuntime) {
  const devices = info.simulators?.[runtime];
  if (!devices?.length) throw Error(`environment_failure: simulator runtime unavailable: ${runtime}; no fallback`);
  return devices.map(d => ({...d, runtime}));
}

// One claim across worktrees. Never steal a stale claim: a dead parent may still have live test children.
export function acquireSimulatorSession(directory = sessionDirectory) {
  mkdirSync(path.dirname(directory), {recursive: true});
  try { mkdirSync(directory); }
  catch (error) {
    if (error.code === 'EEXIST') throw Error(`environment_failure: simulator session busy; inspect ${path.join(directory, 'owner.json')} and its processes before recovery`);
    throw error;
  }
  const session = {directory, token: randomUUID(), pid: process.pid, root, developerDir, startedAt: new Date().toISOString()};
  try { writeFileSync(path.join(directory, 'owner.json'), JSON.stringify({...session, created: [], devices: {}}, null, 2)); }
  catch (error) { rmSync(directory, {recursive: true}); throw error; }
  return session;
}

export function readSimulatorSession(token, directory = sessionDirectory) {
  const owner = JSON.parse(readFileSync(path.join(directory, 'owner.json'), 'utf8'));
  if (!token || owner.token !== token || owner.directory !== directory) throw Error('Simulator session ownership mismatch');
  return owner;
}

export function saveSimulatorSession(session, lease) {
  const owner = readSimulatorSession(session.token, session.directory);
  const file = path.join(session.directory, 'owner.json');
  writeFileSync(`${file}.next`, JSON.stringify({...owner, created: lease.created, devices: lease.devices,
    selection: lease.selection, creationIntents: lease.creationIntents, released: lease.released}, null, 2));
  renameSync(`${file}.next`, file);
}

export function releaseSimulatorSession(session) {
  readSimulatorSession(session.token, session.directory);
  rmSync(session.directory, {recursive: true});
}

export async function assertSimulatorAvailability(allowed, execute = captureAsync) {
  const inventory = JSON.parse(await execute('xcrun', ['simctl', 'list', 'devices', '--json']));
  const foreign = Object.values(inventory.devices).flat().filter(d => d.state !== 'Shutdown' && !allowed.includes(d.udid));
  if (foreign.length) throw Error(`environment_failure: other simulators active: ${foreign.map(d => `${d.udid} (${d.name ?? d.state})`).join(', ')}; coordinate shutdown with their owner; nothing was stopped`);
}

export async function allocateSimulators(info, {execute = captureAsync, coordinate = true, sessionPath = sessionDirectory, families = ['ipad', 'iphone'], models = {
  ipad: 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB',
  iphone: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}, overrides = {
  ipad: process.env.FOX_TRIAL_IPAD_SIMULATOR, iphone: process.env.FOX_TRIAL_IPHONE_SIMULATOR}} = {}) {
  const available = simulatorCandidates(info);
  const lease = {devices: {}, created: [], selection: {}, creationIntents: []};
  if (coordinate) lease.session = acquireSimulatorSession(sessionPath);
  try {
    if (coordinate) await assertSimulatorAvailability(Object.values(overrides).filter(Boolean), execute);
    for (const [key, family] of [['ipad', 'iPad'], ['iphone', 'iPhone']].filter(([key]) => families.includes(key))) {
      const candidates = available.filter(d => d.deviceTypeIdentifier?.includes(`.${family}-`));
      // A freshly installed runtime need not have permanent template instances. The type must still be installed.
      const installedType = info.simulatorTypes?.find(d => d.identifier === models[key]);
      const template = overrides[key] ? candidates.find(d => d.udid === overrides[key])
        : candidates.find(d => d.deviceTypeIdentifier === models[key])
          ?? (installedType && {deviceTypeIdentifier: installedType.identifier, runtime: info.simulatorRuntime ?? simulatorRuntime});
      if (!template) throw Error(`environment_failure: missing ${family} simulator runtime or invalid override; install a compatible runtime in Xcode`);
      const name = `FoxVerification-${family}-${randomUUID()}`;
      if (!overrides[key]) {
        lease.creationIntents.push({name, runtime: template.runtime, deviceType: template.deviceTypeIdentifier});
        if (lease.session) saveSimulatorSession(lease.session, lease);
      }
      const id = overrides[key] ?? (await execute('xcrun', ['simctl', 'create', name,
        template.deviceTypeIdentifier, template.runtime])).trim();
      if (!overrides[key]) {
        if (!/^[\da-f]{8}-(?:[\da-f]{4}-){3}[\da-f]{12}$/i.test(id)) throw Error('environment_failure: simulator creation returned an invalid identifier');
        lease.created.push(id);
        lease.creationIntents.at(-1).id = id;
      }
      lease.devices[key] = id;
      lease.selection[key] = {id, runtime: template.runtime, deviceType: template.deviceTypeIdentifier, owned: !overrides[key]};
      if (lease.session) saveSimulatorSession(lease.session, lease);
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
  if (lease.session) {
    await assertSimulatorAvailability([target], execute);
    step.env.FOX_SIMULATOR_SESSION_TOKEN = lease.session.token;
  }
  return {step: step.id, target, parked};
}

export async function releaseSimulators(lease, execute = captureAsync) {
  const errors = [];
  // Only IDs created by this invocation belong to this invocation. Overrides are never deleted.
  lease.released ??= [];
  for (const id of lease.created.filter(id => !lease.released.includes(id))) {
    try { await execute('xcrun', ['simctl', 'shutdown', id]); }
    catch (error) { if (!/current state: Shutdown/i.test(error.message)) errors.push(`${id}: ${error.message}`); }
    try {
      await execute('xcrun', ['simctl', 'delete', id]);
      lease.released.push(id);
      if (lease.session) saveSimulatorSession(lease.session, lease);
    }
    catch (error) { errors.push(`${id}: ${error.message}`); }
  }
  if (lease.session && lease.creationIntents?.some(intent => !intent.id)) errors.push('creation outcome uncertain; inspect exact creationIntents names before releasing session');
  if (errors.length) throw Error(`simulator cleanup failed: ${errors.join('; ')}`);
  if (lease.session) releaseSimulatorSession(lease.session);
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
