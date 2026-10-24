import {createHash} from 'node:crypto';
import {readFile, writeFile, mkdir, lstat, realpath} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const legacyGates = [
  ['baseline', 'baseline'], ['module-boundaries', 'software'], ['guidance-policy', 'software'],
  ['guidance-integration', 'software'], ['confirmation-and-bundles', 'software'],
  ['full-flow-regression', 'software'], ['ui-matrix', 'software'],
  ['camera-audio-performance', 'device'], ['offline-speech', 'device'],
  ['installation-and-launch', 'device'], ['record-preservation', 'device']
];
// The user explicitly deferred disruptive offline checks on 2026-10-23.
// Keep old receipts strict; v2 qualifies a connected trial, not offline support.
const gates = legacyGates.filter(([id]) => id !== 'offline-speech');
const trialScope = 'connected-trial-user-decision-20261023';

export function createManifest() {
  return {
    schema: 'fox.trial_readiness.v2', trialScope, createdAt: new Date().toISOString(), candidateBuild: null,
    deferredChecks: [{id: 'offline-speech', status: 'not_evaluated', reason: 'User deferred network toggling and offline qualification; no offline guarantee.'}],
    baseline: null, inputAssets: [], capabilities: [],
    requiredGates: gates.map(([id, scope]) => ({id, scope, status: 'pending', sourceSHA256: null, evidence: []})),
    deviceCheck: null, recordPreservation: null, pendingHumanActions: [],
    evidenceBoundary: 'Readiness is not human acceptance. Evidence checks protect integrity, not the truth of arbitrary receipt content.'
  };
}

export async function artifact(root, relative) {
  if (typeof relative !== 'string' || path.isAbsolute(relative) || relative.split(/[\\/]/).includes('..')) throw Error('unsafe artifact path');
  const base = await realpath(root), filename = path.join(base, relative);
  const resolved = await realpath(filename);
  if (!resolved.startsWith(base + path.sep) || (await lstat(filename)).isSymbolicLink()) throw Error('unsafe artifact link');
  const bytes = await readFile(filename);
  return {path: relative, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex')};
}

export async function assessReadiness(manifest, root, now = new Date()) {
  if (!['fox.trial_readiness.v1', 'fox.trial_readiness.v2'].includes(manifest.schema)) throw Error('Unsupported readiness schema');
  const required = manifest.schema === 'fox.trial_readiness.v1' ? legacyGates : gates;
  if (manifest.schema === 'fox.trial_readiness.v2' && (manifest.trialScope !== trialScope ||
      manifest.deferredChecks?.length !== 1 || manifest.deferredChecks[0].id !== 'offline-speech' ||
      manifest.deferredChecks[0].status !== 'not_evaluated' || !manifest.deferredChecks[0].reason?.trim())) {
    throw Error('Invalid connected-trial scope or deferred offline claim');
  }
  const missing = [], reasons = {};
  const invalidShape = manifest.requiredGates.length !== required.length || required.some(([id, scope]) =>
    manifest.requiredGates.filter(g => g.id === id && g.scope === scope).length !== 1);
  for (const [id, scope] of required) {
    const matches = manifest.requiredGates.filter(g => g.id === id);
    const gate = matches[0];
    let reason;
    if (matches.length !== 1 || gate.scope !== scope || gate.status !== 'verified') reason = 'not_verified';
    else if (scope !== 'baseline' && (!/^[a-f0-9]{64}$/.test(gate.sourceSHA256 ?? '') ||
        gate.sourceSHA256 !== manifest.candidateBuild?.sourceSHA256)) reason = 'candidate_source_mismatch';
    else if (!gate.evidence?.length) reason = 'missing_evidence';
    else {
      for (const expected of gate.evidence) {
        try {
          const actual = await artifact(root, expected.path);
          if (actual.sha256 !== expected.sha256 || actual.bytes !== expected.bytes) reason = 'evidence_changed';
        } catch { reason = 'evidence_missing_or_unsafe'; }
      }
    }
    if (reason) { missing.push(id); reasons[id] = reason; }
  }
  const nonDevice = required.filter(([, scope]) => scope !== 'device').map(([id]) => id);
  const softwareReady = !invalidShape && !missing.some(id => nonDevice.includes(id));
  const device = manifest.deviceCheck;
  const expires = Date.parse(device?.signatureExpiresAt ?? '');
  const installed = device?.launched === true && !!manifest.candidateBuild?.build &&
    device.installedBuild === manifest.candidateBuild.build && device.installedVersion === manifest.candidateBuild.version;
  const deviceReady = installed && Number.isFinite(expires) && expires > now.getTime() &&
    manifest.recordPreservation?.verified === true && manifest.pendingHumanActions.length === 0;
  const status = !softwareReady ? 'incomplete' : missing.length || !deviceReady ? 'software_ready_device_pending' : 'trial_ready';
  return {status, missing, reasons, deviceReady, deferredChecks: manifest.deferredChecks ?? [], assessedAt: now.toISOString()};
}

async function main() {
  const [command, directory] = process.argv.slice(2);
  if (!directory || !['init', 'check'].includes(command)) throw Error('Usage: node scripts/trial-readiness.mjs init|check <run-directory>');
  const root = path.resolve(directory), filename = path.join(root, 'trial-readiness.v1.json');
  if (command === 'init') {
    await mkdir(root, {recursive: true});
    await writeFile(filename, JSON.stringify(createManifest(), null, 2) + '\n', {flag: 'wx'});
  }
  const manifest = JSON.parse(await readFile(filename, 'utf8'));
  const assessment = await assessReadiness(manifest, root);
  console.log(JSON.stringify(assessment, null, 2));
  if (command === 'check' && assessment.status !== 'trial_ready') process.exitCode = 2;
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
