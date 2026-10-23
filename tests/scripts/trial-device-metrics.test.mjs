import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {analyzeRound, compareRounds} from '../../scripts/trial-device-metrics.mjs';

function sample(mode = 'off', round = 1) {
  return {metadata: {schema: 'fox.trial_device_round.v1', id: `${mode}-${round}`, mode, round,
    source: 'physical_camera', deviceModel: 'iPad16,5', appVersion: '0.6.8', appBuild: '24', camera: 'front',
    durationSeconds: 15, stopReason: 'benchmarkComplete',
    conditions: Array.from({length: 16}, (_, time) => ({time, active: true, thermal: 0, orientation: 'portrait', network: 'unsatisfied'}))},
    frames: Array.from({length: 451}, (_, i) => ({capturePTS: i / 30, receivedUptime: 100 + i / 30, width: 720, height: 1280, encoded: true})),
    poses: Array.from({length: 151}, (_, i) => ({capturePTS: i / 10, receivedUptime: 100 + i / 10, latencyMs: 8, people: [], screenOrientation: 'portrait'})),
    events: [], speech: mode === 'on' ? [{cueID: 'one', state: 'started', time: 100, outputKind: 'system_speech_callback_not_audibility'},
      {cueID: 'one', state: 'finished', time: 100.4, outputKind: 'system_speech_callback_not_audibility'}] : []};
}
const all = () => [1, 2, 3].flatMap(i => [sample('off', i), sample('on', i)]);
const review = {sameScene: true, reviewedRoundIDs: ['off-1', 'on-1', 'off-2', 'on-2', 'off-3', 'on-3'],
  evidence: ['six-round-contact-sheet.png'], scope: 'stationary scene without person; not exercise accuracy'};

test('CLI accepts reviewed connected performance without claiming offline speech', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-connected-metrics-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const values = all();
  for (const item of values) {
    item.metadata.conditions.forEach(x => x.network = 'satisfied');
    const folder = path.join(dir, item.metadata.id); await mkdir(folder);
    await writeFile(path.join(folder, 'round.json'), JSON.stringify(item.metadata));
    await writeFile(path.join(folder, 'speech.json'), JSON.stringify(item.speech));
    for (const key of ['frames', 'poses', 'events']) {
      await writeFile(path.join(folder, `${key}.jsonl`), item[key].map(x => JSON.stringify(x)).join('\n'));
    }
  }
  await writeFile(path.join(dir, 'run.json'), JSON.stringify({rounds: values.map(x => ({id: x.metadata.id}))}));
  await writeFile(path.join(dir, 'review.json'), JSON.stringify(review));
  const result = spawnSync(process.execPath, ['scripts/trial-device-metrics.mjs', dir, path.join(dir, 'review.json')], {encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(await readFile(path.join(dir, 'comparison.json'), 'utf8'));
  assert.equal(report.status, 'passed');
  assert.equal(report.offlineSpeechVerified, false);
});

test('six physical rounds require separate scene review and preserve limited scope', () => {
  const results = all().map(analyzeRound);
  assert.equal(compareRounds(results).status, 'scene_review_pending');
  const report = compareRounds(results, review);
  assert.equal(report.status, 'passed');
  assert.equal(report.pairs.length, 3);
  assert.equal(report.offlineSpeechVerified, true);
  assert.equal(report.personPresent, false);
  assert.equal(report.sceneScope, review.scope);
});

test('reject empty, malformed, fixture, too short and interrupted samples', () => {
  for (const mutate of [x => x.frames = [], x => x.poses = [], x => x.frames[2].capturePTS = 0,
    x => x.frames[2].receivedUptime = NaN, x => x.metadata.source = 'fixture',
    x => x.frames = x.frames.slice(0, 30), x => x.metadata.stopReason = 'background',
    x => x.metadata.conditions[3].active = false, x => x.metadata.conditions[3].thermal = 2,
    x => x.frames[20].width = 1280, x => x.poses[3].latencyMs = -1]) {
    const value = sample(); mutate(value); assert.throws(() => analyzeRound(value));
  }
});

test('enabled round needs completed actual speech and off round must be silent', () => {
  const on = sample('on'); on.speech = []; assert.throws(() => analyzeRound(on));
  const failed = sample('on'); failed.speech.push({state: 'failed'}); assert.throws(() => analyzeRound(failed));
  const fake = sample('on'); fake.speech.forEach(x => x.outputKind = 'test_double_not_audio'); assert.throws(() => analyzeRound(fake));
  const off = sample(); off.speech = sample('on').speech; assert.throws(() => analyzeRound(off));
});

test('no averaging away one bad pair or accepting partial matrix', () => {
  assert.throws(() => compareRounds(all().slice(0, 5).map(analyzeRound), review));
  const values = all();
  values[5].frames = values[5].frames.map((f, i) => ({...f, capturePTS: i / 20, receivedUptime: 100 + i / 20}));
  assert.equal(compareRounds(values.map(analyzeRound), review).status, 'failed');
  const dropped = all();
  dropped[3].events = Array.from({length: 40}, () => ({kind: 'captureDropped'}));
  assert.equal(compareRounds(dropped.map(analyzeRound), review).status, 'failed');
});

test('different configuration, thermal state or incomplete review is not comparable', () => {
  const values = all(); values[1].metadata.camera = 'back';
  assert.equal(compareRounds(values.map(analyzeRound), review).status, 'not_comparable');
  const thermal = all(); thermal[1].metadata.conditions.forEach(x => x.thermal = 1);
  assert.equal(compareRounds(thermal.map(analyzeRound), review).status, 'not_comparable');
  assert.equal(compareRounds(all().map(analyzeRound), {...review, reviewedRoundIDs: ['off-1']}).status, 'scene_review_pending');
});

test('online playback is not offline proof and metrics include encoder backpressure', () => {
  const values = all(); values[1].metadata.conditions[3].network = 'satisfied';
  values[1].frames[3].encoded = false;
  const results = values.map(analyzeRound), report = compareRounds(results, review);
  assert.equal(report.status, 'passed');
  assert.equal(report.offlineSpeechVerified, false);
  assert.equal(results[1].encoderDropped, 1);
  assert.ok(results[1].dropRate > 0);
});
