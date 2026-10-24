import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, rm, readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createManifest, assessReadiness, artifact} from '../../scripts/trial-readiness.mjs';

test('connected trial explicitly defers offline speech without weakening the other gates', async () => {
  const m = createManifest();
  assert.equal(m.schema, 'fox.trial_readiness.v2');
  assert.equal(m.trialScope, 'connected-trial-user-decision-20261023');
  assert.ok(!m.requiredGates.some(x => x.id === 'offline-speech'));
  assert.deepEqual(m.deferredChecks.map(x => [x.id, x.status]), [['offline-speech', 'not_evaluated']]);
  assert.ok(m.requiredGates.some(x => x.id === 'camera-audio-performance'));
  m.deferredChecks[0].status = 'verified';
  await assert.rejects(assessReadiness(m, process.cwd()), /deferred/);
});

test('legacy manifests retain the original offline requirement', async () => {
  const m = createManifest(); m.schema = 'fox.trial_readiness.v1';
  const result = await assessReadiness(m, process.cwd());
  assert.equal(result.status, 'incomplete');
  assert.ok(result.missing.includes('offline-speech'));
});

test('readiness starts incomplete and cannot be approved by an arbitrary overall passed field', async () => {
  const m = createManifest(); m.status = 'trial_ready';
  const result = await assessReadiness(m, process.cwd());
  assert.equal(result.status, 'incomplete');
  assert.ok(result.missing.includes('baseline'));
});

test('gate evidence must exist, match digest and match the current source candidate', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-readiness-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  await writeFile(path.join(dir, 'result.json'), '{}');
  const a = await artifact(dir, 'result.json');
  const m = createManifest(); m.candidateBuild = {sourceSHA256: 'a'.repeat(64)};
  const gate = m.requiredGates.find(x => x.id === 'guidance-policy');
  gate.status = 'verified'; gate.sourceSHA256 = 'b'.repeat(64); gate.evidence = [a];
  assert.ok((await assessReadiness(m, dir)).missing.includes(gate.id));
  gate.sourceSHA256 = m.candidateBuild.sourceSHA256;
  assert.ok(!(await assessReadiness(m, dir)).missing.includes(gate.id));
  await writeFile(path.join(dir, 'result.json'), 'changed');
  assert.ok((await assessReadiness(m, dir)).missing.includes(gate.id));
  await assert.rejects(artifact(dir, '../outside'), /unsafe/);
});

test('device pending stays distinct and expired signature blocks readiness', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-readiness-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  await writeFile(path.join(dir, 'receipt'), 'synthetic test receipt only');
  const a = await artifact(dir, 'receipt');
  const m = createManifest(); m.candidateBuild = {version: 'test', build: '1', sourceSHA256: 'a'.repeat(64)};
  for (const gate of m.requiredGates.filter(x => x.scope !== 'device')) {
    Object.assign(gate, {status: 'verified', sourceSHA256: m.candidateBuild.sourceSHA256, evidence: [a]});
  }
  assert.equal((await assessReadiness(m, dir)).status, 'software_ready_device_pending');
  for (const gate of m.requiredGates.filter(x => x.scope === 'device')) {
    Object.assign(gate, {status: 'verified', sourceSHA256: m.candidateBuild.sourceSHA256, evidence: [a]});
  }
  m.deviceCheck = {installedBuild: '1', installedVersion: 'test', launched: true, signatureExpiresAt: '2026-10-30T00:00:00Z'};
  m.recordPreservation = {verified: true};
  assert.equal((await assessReadiness(m, dir, new Date('2026-10-23'))).status, 'trial_ready');
  assert.equal((await assessReadiness(m, dir, new Date('2026-10-31'))).status, 'software_ready_device_pending');
  m.requiredGates = m.requiredGates.filter(x => x.id !== 'camera-audio-performance');
  assert.equal((await assessReadiness(m, dir)).status, 'incomplete', 'Removing a required gate cannot make the candidate pass');
});

test('guidance has no UI, audio, network or persistence dependency and counters do not depend on it', async () => {
  const root = 'apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore';
  for (const file of await readdir(`${root}/Guidance`)) {
    if (!file.endsWith('.swift')) continue;
    const text = await readFile(`${root}/Guidance/${file}`, 'utf8');
    const imports = [...text.matchAll(/^import (\w+)/gm)].map(x => x[1]);
    assert.deepEqual(imports, ['Foundation'], file);
    assert.doesNotMatch(text, /LocalTrainingRepository|URLSession|FileManager|AVSpeechSynthesizer|TrainingStore/, file);
  }
  for (const file of ['PoseTracking.swift', 'LatPulldown.swift', 'PoseEccentric.swift']) {
    assert.doesNotMatch(await readFile(`${root}/${file}`, 'utf8'), /import (SwiftUI|AVFoundation)|GuidancePolicy|GuidanceQueue/);
  }
});
