import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { checkCycleReplay } from './vision-cycle-check.mjs';

export function summarizeComparison(plan, labels, reports) {
  if (plan.schema !== 'fox.pose_comparison_plan.v1' || labels.videoSHA256 !== plan.videoSHA256 || !reports.length) {
    throw new Error('Invalid experiment source');
  }
  const backends = new Set(), inputs = new Set();
  for (const report of reports) {
    if (report.schema !== 'fox.pose_comparison_evaluation.v1' || report.videoSHA256 !== plan.videoSHA256) throw new Error('Invalid report source');
    if (backends.has(report.backend)) throw new Error('Duplicate backend');
    backends.add(report.backend); inputs.add(report.inputSHA256);
  }
  if (inputs.size !== 1) throw new Error('Models did not use the same input cache');
  if (reports.some(r => JSON.stringify(r.configuration) !== JSON.stringify(reports[0].configuration)
    || JSON.stringify(r.runtimePolicy) !== JSON.stringify(reports[0].runtimePolicy))) throw new Error('Counter configuration differs between models');
  const targets = [];
  for (const report of reports) {
    for (const target of plan.targets) {
      const segment = report.segments.find(s => s.id === target.segment && s.side === target.side);
      const label = labels.segments.find(s => s.id === target.segment && s.side === target.side);
      if (!segment || !label) throw new Error('Missing target or labels');
      const modes = {};
      for (const mode of ['diagnostic', 'gated']) {
        const value = segment[mode];
        if (value.count !== value.repetitions.length) throw new Error('Count disagrees with events');
        // Rebase to the label origin without changing the measured event timestamps.
        const offset = value.originSeconds - label.originSeconds;
        const repetitions = value.repetitions.map(rep => {
          const result = { ...rep };
          for (const key of ['startedAtSeconds', 'peakAtSeconds', 'loweredAtSeconds', 'completedAtSeconds']) {
            if (!Number.isFinite(rep[key])) throw new Error('Missing measured event timestamp');
            result[key] += offset;
          }
          return result;
        });
        const checked = checkCycleReplay({ ...labels, segments: [label] }, {
          cache: { videoSHA256: report.videoSHA256, fullFrame: true, audioInput: false },
          cacheSHA256: report.inputSHA256,
          segments: [{ id: segment.id, side: segment.side, originSeconds: label.originSeconds, candidateRepetitions: repetitions }]
        }).segments[0];
        modes[mode] = { count: value.count, matched: checked.events.filter(e => e.labelId !== null).length,
          missed: checked.unmatchedLabels.length, extra: checked.events.filter(e => e.labelId === null).length,
          resetCounts: value.resetCounts, eventMatches: checked.events, unmatchedLabels: checked.unmatchedLabels };
      }
      targets.push({ backend: report.backend, id: segment.id, side: segment.side,
        referenceCount: label.cycles.length, countdownReadyAt: segment.countdownReadyAt ?? null,
        startupDelaySeconds: segment.countdownReadyAt == null ? null : segment.countdownReadyAt - label.originSeconds,
        countdownResets: segment.countdownResets,
        referenceCyclesBeforeReady: segment.countdownReadyAt == null ? label.cycles.length
          : label.cycles.filter(c => c.start[0] < segment.countdownReadyAt).length,
        firstLostAt: segment.firstLostAt ?? null, frames: segment.frames,
        subjectStates: segment.subjectStates, geometryStates: segment.geometryStates,
        selectedNoneWithDetectedPerson: segment.selectedNoneWithDetectedPerson,
        subjectCheckpoints: segment.subjectCheckpoints ?? [],
        negativeWindowDiagnosticCount: segment.negativeWindowDiagnosticCount,
        negativeWindowGatedCount: segment.negativeWindowGatedCount, ...modes });
    }
  }
  const nativeCounterRuns = reports.flatMap(report => report.appleCounterRuns.map(run => {
    if (run.points.some(point => !Number.isFinite(point.cumulativeCount))) throw new Error('Invalid native counter output');
    if (run.points.some(point => point.windowStart < run.startedAt || point.windowEnd <= point.windowStart)
      || (run.points.length && Math.abs(run.points[0].windowEnd - run.startedAt - 90 / run.hz) > 1 / run.hz)) {
      throw new Error('Invalid native window timebase');
    }
    return { id: run.id, side: run.side, hz: run.hz, joints: run.joints, frames: run.frames,
      chunkStart: run.startedAt, firstOutputWindowEnd: run.points[0]?.windowEnd ?? null,
      rawCumulativeCount: run.points.at(-1)?.cumulativeCount ?? null, outputs: run.points.length,
      status: run.error ? 'error' : (run.points.length ? 'raw-periodic-estimate' : 'no-output'), error: run.error ?? null };
  }));
  return { schema: 'fox.pose_comparison_summary.v1', heldOut: labels.heldOut,
    evidenceBoundary: 'macOS offline development video; coarse labels; not M4 realtime, independent accuracy or form assessment',
    inputSHA256: reports[0].inputSHA256, videoSHA256: plan.videoSHA256, targets, nativeCounterRuns };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [planPath, labelsPath, output, ...reportPaths] = process.argv.slice(2);
    if (!planPath || !labelsPath || !output || !reportPaths.length) throw new Error('Usage: pose-experiment-report <plan> <labels> <new-output> <reports...>');
    const load = async name => JSON.parse(await readFile(name, 'utf8'));
    const reports = [];
    for (const name of reportPaths) reports.push(await load(name));
    const result = summarizeComparison(await load(planPath), await load(labelsPath), reports);
    await writeFile(output, JSON.stringify(result, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    console.log(`Comparison summary: ${output}`);
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
