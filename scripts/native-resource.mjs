import {existsSync, readFileSync} from 'node:fs';
import {setTimeout as delay} from 'node:timers/promises';
import {randomUUID} from 'node:crypto';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {acquireSimulatorSession, readSimulatorSession, releaseSimulatorSession,
  sessionDirectory, root, developerDir, evidencePath} from './development-environment.mjs';
export {nativeScratchPath, swiftJobs} from './development-environment.mjs';

const alive = pid => {
  if (!Number.isSafeInteger(pid) || pid <= 0) return false;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code === 'EPERM'; }
};

export function nativeResourceStatus(directory = sessionDirectory) {
  if (!existsSync(directory)) return {state: 'free', resource: 'mac-native'};
  try {
    const {token, ...owner} = JSON.parse(readFileSync(path.join(directory, 'owner.json'), 'utf8'));
    return {state: 'held', owner, ownerAlive: alive(owner.pid),
      recovery: 'Never infer availability from a dead parent; inspect its children and retained receipt.'};
  } catch { return {state: 'unknown', directory, recovery: 'Owner may still be initializing; do not delete the claim.'}; }
}

export async function acquireNativeResource({directory = sessionDirectory, token,
  expectedRoot = root, expectedDeveloperDir = developerDir, purpose = 'native command',
  waitMs = Number(process.env.FOX_NATIVE_WAIT_MS ?? 0), signal} = {}) {
  if (!Number.isSafeInteger(waitMs) || waitMs < 0 || waitMs > 3_600_000) throw Error('Native wait budget must be an integer from 0 to 3600000 ms');
  signal?.throwIfAborted();
  const started = performance.now();
  if (token) {
    const session = readSimulatorSession(token, directory);
    if (session.root !== expectedRoot || session.developerDir !== expectedDeveloperDir) throw Error('Native resource root/toolchain mismatch');
    if (!alive(session.pid)) throw Error('Native resource owner is no longer alive; inspect children before recovery');
    return {session, owned: false, waitMs: 0};
  }
  while (true) {
    signal?.throwIfAborted();
    try {
      const session = acquireSimulatorSession(directory, {purpose});
      return {session, owned: true, waitMs: Math.round(performance.now() - started)};
    } catch (error) {
      if (error.code !== 'FOX_RESOURCE_BUSY') throw error;
      const elapsed = performance.now() - started;
      if (elapsed >= waitMs) {
        error.resourceAdmission = {status: 'busy', waitMs: Math.round(elapsed), holder: nativeResourceStatus(directory)};
        throw error;
      }
      await delay(Math.min(100, waitMs - elapsed), undefined, {signal});
    }
  }
}

export function releaseNativeResource(claim) {
  if (claim.owned) releaseSimulatorSession(claim.session);
}

export function rejectNestedRunner(token = process.env.FOX_SIMULATOR_SESSION_TOKEN) {
  if (token) throw Error('Nested native orchestration is unsupported; invoke this suite directly, without native:run. Only leaf commands may inherit a claim.');
}

export async function executeAdmitted(step, options, admission = {}) {
  const {execute} = await import('./trial-suite.mjs');
  const started = performance.now();
  let claim;
  try {
    rejectNestedRunner(step.env?.FOX_SIMULATOR_SESSION_TOKEN ?? process.env.FOX_SIMULATOR_SESSION_TOKEN);
    claim = await acquireNativeResource({token: step.env?.FOX_SIMULATOR_SESSION_TOKEN ?? process.env.FOX_SIMULATOR_SESSION_TOKEN,
      purpose: step.id ?? step.command, signal: options.signal, ...admission});
  } catch (error) {
    error.resourceAdmission ??= {status: options.signal?.aborted ? 'cancelled' : 'rejected',
      waitMs: Math.round(performance.now() - started)};
    throw error;
  }
  const resource = {resource: 'mac-native', owned: claim.owned, waitMs: claim.waitMs, acquiredAt: new Date().toISOString(), status: 'held'};
  let result, failure;
  try {
    result = await execute({...step, env: {...step.env, FOX_SIMULATOR_SESSION_TOKEN: claim.session.token}}, options);
  } catch (error) { failure = error; }
  finally {
    // execute owns and settles the child's process group before returning.
    if (failure?.resourceCleanupUncertain) resource.status = 'cleanup_uncertain';
    else {
      try { releaseNativeResource(claim); resource.status = claim.owned ? 'released' : 'inherited'; }
      catch (error) { resource.status = 'cleanup_failed'; failure ??= error; }
    }
    resource.finishedAt = new Date().toISOString();
  }
  if (failure) { failure.resourceAdmission = resource; throw failure; }
  return {...result, resourceAdmission: resource};
}

// Direct native scripts re-enter once under the same lease. Inherited children
// stay in their parent's process group; they must not spawn another detached runner.
export async function guardNativeEntry(purpose, args = process.argv.slice(1)) {
  const token = process.env.FOX_SIMULATOR_SESSION_TOKEN;
  if (token) { await acquireNativeResource({token}); return false; }
  await runAdmittedEntry(purpose, process.execPath, args);
  return true;
}

async function runAdmittedEntry(purpose, command, args) {
  rejectNestedRunner();
  const {runSuite} = await import('./trial-suite.mjs');
  const directory = path.join(process.env.FOX_NATIVE_LOG_ROOT ?? evidencePath('native-resource'), randomUUID());
  try {
    await runSuite({directory, steps: [{id: purpose, command, args}], preflight: async () => [],
      execute: (step, options) => executeAdmitted(step, {...options, forwardOutput: true}),
      metadata: {scope: 'development/native-entry', component: purpose,
        evidenceBoundary: 'Command admission only, not full-product or device acceptance.'}});
  } finally { console.error(`Native command receipt: ${path.join(directory, 'suite.json')}`); }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [action, separator, command, ...args] = process.argv.slice(2);
    if (action === 'status' && !separator) console.log(JSON.stringify(nativeResourceStatus(), null, 2));
    else if (action === 'run' && separator === '--' && command) await runAdmittedEntry('native-command', command, args);
    else throw Error('Usage: native-resource.mjs status | run -- command args...');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
