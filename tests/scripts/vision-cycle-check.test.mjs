import test from 'node:test';
import assert from 'node:assert/strict';
import { checkCycleReplay } from '../../scripts/vision-cycle-check.mjs';

function fixture() {
  return {
    labels: { schema: 'fox.video_cycle_labels.v1', videoSHA256: 'a'.repeat(64), labelMethod: 'visual_coarse_intervals', heldOut: false,
      segments: [{ id: 'A03', side: 'left', originSeconds: 120, cycles: [
        { id: '1', status: 'observable_roundtrip', start: [120.5,121.5], peak: [121.5,123], returned: [125,126] }
      ] }] },
    report: { cache: { videoSHA256: 'a'.repeat(64), fullFrame: true, audioInput: false }, cacheSHA256: 'b'.repeat(64), segments: [
      { id: 'A03', side: 'left', originSeconds: 120, candidateRepetitions: [
        { startedAtSeconds: 1.1, peakAtSeconds: 1.7, loweredAtSeconds: 5.7, completedAtSeconds: 5.8 }
      ] }
    ] }
  };
}
test('checks start, peak, returned endpoint and confirmation separately', () => {
  const { labels, report } = fixture();
  assert.equal(checkCycleReplay(labels, report).status, 'coarse-cycle-window-pass');
  report.segments[0].candidateRepetitions[0].loweredAtSeconds = 4.5;
  assert.equal(checkCycleReplay(labels, report).status, 'partial-not-accepted');
});
test('matching final total cannot hide extra, merged or missing cycles', () => {
  const { labels, report } = fixture();
  report.segments[0].candidateRepetitions[0].startedAtSeconds = 0;
  assert.equal(checkCycleReplay(labels, report).status, 'partial-not-accepted');
  report.segments[0].candidateRepetitions = [];
  assert.equal(checkCycleReplay(labels, report).segments[0].unmatchedLabels.length, 1);
});
test('uncertain labels, altered source and early confirmation cannot pass', () => {
  const { labels, report } = fixture();
  labels.segments[0].cycles[0].status = 'uncertain_visibility';
  assert.equal(checkCycleReplay(labels, report).status, 'partial-not-accepted');
  labels.segments[0].cycles[0].status = 'observable_roundtrip';
  report.segments[0].candidateRepetitions[0].completedAtSeconds = 5.6;
  assert.throws(() => checkCycleReplay(labels, report), /timeline/);
  report.cache.audioInput = true;
  assert.throws(() => checkCycleReplay(labels, report), /source/);
});
