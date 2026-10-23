import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

function requireValue(value, message) { if (!value) throw Error(message); }
function finite(value) { return typeof value === 'number' && Number.isFinite(value); }
function p95(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.ceil(sorted.length * 0.95) - 1];
}
function intervals(rows, key) {
  requireValue(rows.every(x => finite(x[key])), `Invalid ${key}`);
  const deltas = rows.slice(1).map((x, i) => x[key] - rows[i][key]);
  requireValue(deltas.every(x => x > 0), `Non-increasing ${key}`);
  return deltas;
}

// A camera/encoder/speech load comparison, not exercise recognition or audibility evidence.
export function analyzeRound({metadata: m, frames, poses, events, speech}) {
  requireValue(m?.schema === 'fox.trial_device_round.v1' && m.source === 'physical_camera', 'Physical camera evidence required');
  requireValue(['off', 'on'].includes(m.mode) && [1, 2, 3].includes(m.round), 'Unknown mode or round');
  requireValue(m.id && m.deviceModel && m.appVersion && m.appBuild && m.camera, 'Missing candidate identity');
  requireValue(m.stopReason === 'benchmarkComplete', 'Interrupted capture');
  requireValue(Array.isArray(frames) && frames.length >= 100 && Array.isArray(poses) && poses.length >= 40, 'Insufficient capture or Vision samples');
  requireValue(m.conditions?.length >= 8 && m.conditions.every(x => x.active === true && [0, 1].includes(x.thermal)), 'Inactive or thermally constrained round');
  requireValue(m.conditions.every(x => x.orientation && x.orientation === m.conditions[0].orientation), 'Orientation changed');
  requireValue(frames.every(x => x.width > 0 && x.height > 0 && x.width === frames[0].width && x.height === frames[0].height && typeof x.encoded === 'boolean'), 'Frame geometry changed or invalid');
  const captureIntervals = intervals(frames, 'capturePTS'), receiveIntervals = intervals(frames, 'receivedUptime');
  intervals(poses, 'capturePTS'); intervals(poses, 'receivedUptime');
  requireValue(frames.at(-1).capturePTS - frames[0].capturePTS >= 8, 'Capture too short');
  requireValue(poses.every(x => finite(x.latencyMs) && x.latencyMs >= 0 && Array.isArray(x.people)), 'Invalid Vision processing metrics');
  requireValue(Array.isArray(events) && Array.isArray(speech), 'Missing event timelines');
  requireValue(!speech.some(x => x.state === 'failed'), 'Speech failed');
  const starts = speech.filter(x => x.state === 'started');
  requireValue(starts.every(x => x.outputKind === 'system_speech_callback_not_audibility'), 'Test double is not real speech evidence');
  const finishes = speech.filter(x => x.state === 'finished' && starts.some(s => s.cueID === x.cueID && s.time <= x.time));
  requireValue(m.mode === 'on' ? finishes.length > 0 : starts.length === 0, 'Wrong speech load for comparison');
  const captureDropped = events.filter(x => x.kind === 'captureDropped').length;
  const encoderDropped = frames.filter(x => !x.encoded).length;
  return {id: m.id, mode: m.mode, round: m.round,
    configuration: {deviceModel: m.deviceModel, appVersion: m.appVersion, appBuild: m.appBuild, camera: m.camera,
      width: frames[0].width, height: frames[0].height, orientation: m.conditions[0].orientation},
    thermalStates: [...new Set(m.conditions.map(x => x.thermal))].sort(),
    frames: frames.length, visionSamples: poses.length, captureDropped, encoderDropped,
    captureIntervalP95: p95(captureIntervals), receiveIntervalP95: p95(receiveIntervals),
    visionLatencyP95Ms: p95(poses.map(x => x.latencyMs)),
    dropRate: (captureDropped + encoderDropped) / (frames.length + captureDropped),
    speechStarted: starts.length, speechFinished: finishes.length,
    networkOffline: m.conditions.every(x => x.network === 'unsatisfied'),
    personPresent: poses.some(x => x.people.length > 0)};
}

export function compareRounds(rounds, review) {
  requireValue(rounds.length === 6 && new Set(rounds.map(x => `${x.mode}-${x.round}`)).size === 6, 'Need exactly three off/on pairs');
  const first = rounds[0], comparable = rounds.every(x =>
    JSON.stringify(x.configuration) === JSON.stringify(first.configuration) &&
    JSON.stringify(x.thermalStates) === JSON.stringify(first.thermalStates));
  const pairs = [1, 2, 3].map(round => {
    const off = rounds.find(x => x.round === round && x.mode === 'off');
    const on = rounds.find(x => x.round === round && x.mode === 'on');
    requireValue(off && on, 'Missing comparison pair');
    const intervalRatio = Math.max(on.captureIntervalP95 / off.captureIntervalP95, on.receiveIntervalP95 / off.receiveIntervalP95);
    const dropRateIncrease = on.dropRate - off.dropRate;
    return {round, offID: off.id, onID: on.id, intervalRatio, dropRateIncrease,
      passed: intervalRatio <= 1.2 && dropRateIncrease <= 0.05};
  });
  const reviewed = review?.sameScene === true && review.scope?.trim() && review.evidence?.length > 0 &&
    rounds.every(x => review.reviewedRoundIDs?.includes(x.id));
  return {schema: 'fox.trial_device_comparison.v1',
    status: !comparable ? 'not_comparable' : !reviewed ? 'scene_review_pending' : pairs.every(x => x.passed) ? 'passed' : 'failed',
    thresholds: {maximumIntervalRatio: 1.2, maximumDropRateIncrease: 0.05},
    offlineSpeechVerified: rounds.filter(x => x.mode === 'on').every(x => x.networkOffline && x.speechFinished > 0),
    personPresent: rounds.every(x => x.personPresent), sceneScope: reviewed ? review.scope : null, pairs, rounds};
}

async function jsonLines(file) { return (await readFile(file, 'utf8')).split('\n').filter(Boolean).map(x => JSON.parse(x)); }
async function main() {
  const [directory, reviewFile] = process.argv.slice(2);
  requireValue(directory, 'Usage: node scripts/trial-device-metrics.mjs <exported-run-directory> [scene-review.json]');
  const index = JSON.parse(await readFile(path.join(directory, 'run.json'), 'utf8'));
  const rounds = [];
  for (const item of index.rounds) {
    requireValue(/^[A-Za-z0-9-]+$/.test(item.id), 'Invalid round path');
    const folder = path.join(directory, item.id);
    rounds.push(analyzeRound({metadata: JSON.parse(await readFile(path.join(folder, 'round.json'), 'utf8')),
      frames: await jsonLines(path.join(folder, 'frames.jsonl')), poses: await jsonLines(path.join(folder, 'poses.jsonl')),
      events: await jsonLines(path.join(folder, 'events.jsonl')), speech: JSON.parse(await readFile(path.join(folder, 'speech.json'), 'utf8'))}));
  }
  const review = reviewFile ? JSON.parse(await readFile(reviewFile, 'utf8')) : undefined;
  const result = compareRounds(rounds, review);
  await writeFile(path.join(directory, 'comparison.json'), JSON.stringify(result, null, 2) + '\n');
  console.log(JSON.stringify(result, null, 2));
  // This command qualifies performance. Network provenance remains a separate fact.
  if (result.status !== 'passed') process.exitCode = 1;
}
if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
