import test from 'node:test';
import assert from 'node:assert/strict';
import { summarizeComparison } from '../../scripts/pose-experiment-report.mjs';

function fixture() {
  const hash = 'a'.repeat(64);
  const labels = { schema: 'fox.video_cycle_labels.v1', videoSHA256: hash, labelMethod: 'visual_coarse_intervals', heldOut: false,
    segments: [{ id: 'A01', side: 'left', originSeconds: 7, cycles: [
      { id: '1', status: 'observable_roundtrip', start: [7, 8], peak: [8, 9], returned: [9, 10] }
    ] }] };
  const mode = { originSeconds: 7, count: 1, resetCounts: {}, repetitions: [
    { startedAtSeconds: 0.5, peakAtSeconds: 1.5, loweredAtSeconds: 2.5, completedAtSeconds: 2.7 }
  ] };
  const report = { schema: 'fox.pose_comparison_evaluation.v1', backend: 'vision', inputSHA256: 'b'.repeat(64), videoSHA256: hash,
    segments: [{ id: 'A01', side: 'left', frames: 100, subjectStates: { bound: 100 }, geometryStates: { valid: 100 },
      countdownReadyAt: 10.5, diagnostic: mode, gated: { originSeconds: 10.5, count: 0, repetitions: [], resetCounts: {} },
      negativeWindowDiagnosticCount: 0, negativeWindowGatedCount: 0 }],
    appleCounterRuns: [{ id: 'A01', side: 'left', hz: 10, joints: 'observed_arm', frames: 100, startedAt: 7,
      points: [{ windowStart: 7, windowEnd: 16, cumulativeCount: 0.65 }], processingSeconds: 1 }] };
  const plan = { schema: 'fox.pose_comparison_plan.v1', videoSHA256: hash, heldOut: false, targets: [{ segment: 'A01', side: 'left' }] };
  return { plan, labels, reports: [report] };
}
test('reports startup gating separately from diagnostic counting', () => {
  const f = fixture();
  const result = summarizeComparison(f.plan, f.labels, f.reports);
  assert.equal(result.targets[0].diagnostic.matched, 1);
  assert.equal(result.targets[0].gated.missed, 1);
  assert.equal(result.targets[0].referenceCyclesBeforeReady, 1);
  assert.equal(result.heldOut, false);
});
test('equal final totals do not conceal per-cycle timing errors', () => {
  const f = fixture();
  f.reports[0].segments[0].diagnostic.repetitions[0].peakAtSeconds = 2.1;
  const event = summarizeComparison(f.plan, f.labels, f.reports).targets[0].diagnostic;
  assert.equal(event.count, 1);
  assert.equal(event.matched, 0);
  assert.equal(event.missed, 1);
  assert.equal(event.extra, 1);
});
test('fractional native counters remain raw and are never rounded into accepted events', () => {
  const f = fixture();
  const result = summarizeComparison(f.plan, f.labels, f.reports);
  assert.equal(result.nativeCounterRuns[0].rawCumulativeCount, 0.65);
  assert.equal(result.nativeCounterRuns[0].acceptedRepetitions, undefined);
});
test('unavailable native counter output is not a zero-count success', () => {
  const f = fixture();
  f.reports[0].appleCounterRuns[0].points = [];
  const result = summarizeComparison(f.plan, f.labels, f.reports);
  assert.equal(result.nativeCounterRuns[0].rawCumulativeCount, null);
  assert.equal(result.nativeCounterRuns[0].status, 'no-output');
});
test('rejects mismatched input pixels, video labels and unmeasured native output', () => {
  const f = fixture();
  const other = structuredClone(f.reports[0]);
  other.backend = 'mediapipe'; other.inputSHA256 = 'c'.repeat(64);
  assert.throws(() => summarizeComparison(f.plan, f.labels, [...f.reports, other]), /input/);
  f.labels.videoSHA256 = 'c'.repeat(64);
  assert.throws(() => summarizeComparison(f.plan, f.labels, f.reports), /source/);
});
test('missing labeled target cannot silently disappear from results', () => {
  const f = fixture(); f.reports[0].segments = [];
  assert.throws(() => summarizeComparison(f.plan, f.labels, f.reports), /target/);
});
test('duplicate model results cannot inflate the comparison', () => {
  const f = fixture();
  assert.throws(() => summarizeComparison(f.plan, f.labels, [...f.reports, f.reports[0]]), /Duplicate/);
});
test('changing counter rules between models rejects a claimed controlled comparison', () => {
  const f = fixture();
  const other = structuredClone(f.reports[0]);
  other.backend = 'mediapipe'; other.runtimePolicy = { retentionSeconds: 2 };
  assert.throws(() => summarizeComparison(f.plan, f.labels, [...f.reports, other]), /configuration/);
});
test('rejects native output frame indices misinterpreted as presentation time ticks', () => {
  const f = fixture();
  f.reports[0].appleCounterRuns[0].points[0].windowEnd = 0.0015;
  assert.throws(() => summarizeComparison(f.plan, f.labels, f.reports), /timebase/);
});
