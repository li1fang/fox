import test from 'node:test';
import assert from 'node:assert/strict';
import { checkVideoReplay } from '../../scripts/vision-video-check.mjs';

function fixture() {
  const sha256 = 'a'.repeat(64);
  const manifest = { schema: 'fox.video_corpus.v1', sha256,
    segments: ['A01', 'A02', 'A03'].map(id => ({ id, peak_candidates_seconds: [1] })) };
  const report = { schema: 'fox.video_replay_evaluation.v1', cacheSHA256: 'b'.repeat(64),
    cache: { videoSHA256: sha256, fullFrame: true, audioInput: false },
    segments: [['A01', 'left'], ['A02', 'right'], ['A03', 'left'], ['A03', 'right']].map(([id, side]) => ({
      id, side, selectedV3Count: 1,
      checkpoints: [0, 1].map(seconds => ({ seconds, state: 'bound', status: 'within-reviewed-subject-region' })),
      negativeWindowCounts: { exit: 0 },
      eventEvaluation: { events: [{ start: 0, peak: 1, end: 2, candidatePeaks: [1], status: 'one-peak-in-observed-cycle' }], unmatchedPeakCandidates: [] }
    })) };
  return { manifest, report };
}
test('event and subject gates stay independent; matching totals alone cannot pass', () => {
  const { manifest, report } = fixture();
  assert.equal(checkVideoReplay(manifest, report).status, 'offline-peak-alignment-pass');
  report.segments[0].eventEvaluation = { events: [{ start: 3, peak: 4, end: 5, candidatePeaks: [], status: 'unmatched-predicted-event' }], unmatchedPeakCandidates: [1] };
  const result = checkVideoReplay(manifest, report);
  assert.equal(result.subjects, 'coarse-checkpoints-and-negative-windows-pass');
  assert.equal(result.status, 'partial-not-accepted');
  assert.equal(result.checks[0].matchedEvents, 0);
});
test('audio-based, cropped, wrong-source or bystander evidence cannot pass', () => {
  const { manifest, report } = fixture();
  report.segments[0].checkpoints[0].status = 'outside-reviewed-subject-region';
  assert.equal(checkVideoReplay(manifest, report).subjects, 'needs-review');
  report.cache.audioInput = true;
  assert.throws(() => checkVideoReplay(manifest, report), /provenance/);
});
test('versioned candidate is checked independently of retained v3 counts', () => {
  const { manifest, report } = fixture();
  const result = report.segments[2];
  result.selectedV3Count = 0;
  result.candidateAlgorithm = 'lateral_raise_2d_v4';
  result.selectedCandidateCount = 1;
  result.candidateEventEvaluation = structuredClone(result.eventEvaluation);
  assert.equal(checkVideoReplay(manifest, report).status, 'offline-peak-alignment-pass');
  result.candidateEventEvaluation.events[0].candidatePeaks = [];
  assert.equal(checkVideoReplay(manifest, report).status, 'partial-not-accepted');
  delete result.candidateAlgorithm;
  assert.throws(() => checkVideoReplay(manifest, report), /provenance/);
});
test('curl v4 retains provenance and event alignment checks', () => {
  const { manifest, report } = fixture();
  const result = report.segments[0];
  result.candidateAlgorithm = 'curl_2d_v4';
  result.selectedCandidateCount = 1;
  result.candidateEventEvaluation = structuredClone(result.eventEvaluation);
  assert.equal(checkVideoReplay(manifest, report).status, 'offline-peak-alignment-pass');
});
