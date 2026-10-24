import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function checkVideoReplay(manifest, report) {
  if (manifest.schema !== 'fox.video_corpus.v1' || report.schema !== 'fox.video_replay_evaluation.v1' ||
      report.cache?.videoSHA256 !== manifest.sha256 || !report.cache.fullFrame || report.cache.audioInput !== false ||
      !/^[0-9a-f]{64}$/.test(report.cacheSHA256 ?? '')) throw new Error('Missing or mismatched replay provenance');
  const targets = [['A01', 'left'], ['A02', 'right'], ['A03', 'left'], ['A03', 'right']];
  const checks = targets.map(([id, side]) => {
    const segment = manifest.segments.find(item => item.id === id);
    const result = report.segments.find(item => item.id === id && item.side === side);
    if (!segment || !result) throw new Error(`Missing ${id}/${side}`);
    const events = result.candidateEventEvaluation ?? result.eventEvaluation;
    const count = result.selectedCandidateCount ?? result.selectedV3Count;
    if (result.candidateEventEvaluation && !['curl_2d_v3', 'curl_2d_v4', 'lateral_raise_2d_v3', 'lateral_raise_2d_v4'].includes(result.candidateAlgorithm)) throw new Error('Missing candidate algorithm provenance');
    const matched = events.events.filter(event => event.status === 'one-peak-in-observed-cycle' && event.candidatePeaks.length === 1);
    const allLabels = [...events.events.flatMap(event => event.candidatePeaks), ...events.unmatchedPeakCandidates];
    const sourceLabels = segment.peak_candidates_seconds;
    const labelsValid = allLabels.length === sourceLabels.length && new Set(allLabels).size === allLabels.length &&
      allLabels.every(value => sourceLabels.includes(value));
    const eventsValid = events.events.every(event => Number.isFinite(event.start) && event.start <= event.peak && event.peak <= event.end &&
      event.candidatePeaks.every(value => event.start <= value && value <= event.end));
    const passes = labelsValid && eventsValid && matched.length === sourceLabels.length &&
      count === matched.length && events.events.length === matched.length && events.unmatchedPeakCandidates.length === 0;
    return { id, side, peakLabels: sourceLabels.length, matchedEvents: matched.length,
      unmatchedLabels: events.unmatchedPeakCandidates, algorithm: result.candidateAlgorithm ?? 'historical-v3', status: passes ? 'peak-event-alignment-pass' : 'needs-review' };
  });
  const allCheckpoints = report.segments.flatMap(item => item.checkpoints);
  const allNegative = report.segments.flatMap(item => Object.values(item.negativeWindowCounts));
  const subjectsPass = allCheckpoints.length >= 8 && allCheckpoints.every(item => item.state === 'bound' && item.status === 'within-reviewed-subject-region') &&
    allNegative.length >= 2 && allNegative.every(count => count === 0);
  const totalPass = subjectsPass && checks.every(item => item.status === 'peak-event-alignment-pass');
  return { status: totalPass ? 'offline-peak-alignment-pass' : 'partial-not-accepted',
    subjects: subjectsPass ? 'coarse-checkpoints-and-negative-windows-pass' : 'needs-review',
    evidenceBoundary: 'Provisional peak labels and macOS Vision only; no iPad or movement-form acceptance', checks };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 4) throw new Error('Usage: vision-video-check <manifest.json> <replay.json>');
    const result = checkVideoReplay(JSON.parse(await readFile(process.argv[2], 'utf8')), JSON.parse(await readFile(process.argv[3], 'utf8')));
    console.log(JSON.stringify(result, null, 2));
    if (result.status === 'partial-not-accepted') process.exitCode = 2;
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
