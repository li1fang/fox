import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export function checkCycleReplay(labels, report) {
  if (labels.schema !== 'fox.video_cycle_labels.v1' || labels.labelMethod !== 'visual_coarse_intervals' ||
      typeof labels.heldOut !== 'boolean' || !/^[0-9a-f]{64}$/.test(labels.videoSHA256 ?? '') ||
      labels.videoSHA256 !== report.cache?.videoSHA256 || !report.cache.fullFrame || report.cache.audioInput !== false ||
      !/^[0-9a-f]{64}$/.test(report.cacheSHA256 ?? '') || !labels.segments?.length) throw new Error('Invalid cycle label source');
  const keys = new Set();
  const segments = labels.segments.map(label => {
    const key = `${label.id}/${label.side}`;
    if (keys.has(key) || !['left','right'].includes(label.side)) throw new Error('Duplicate or invalid cycle label segment');
    keys.add(key);
    const result = report.segments.find(item => item.id === label.id && item.side === label.side);
    if (!result || result.originSeconds !== label.originSeconds || !Number.isFinite(result.originSeconds) || result.originSeconds < 0) throw new Error('Missing cycle timeline origin');
    const seen = new Set();
    let previousPeak = -1;
    for (const cycle of label.cycles) {
      if (!cycle.id || seen.has(cycle.id) || !['observable_roundtrip','uncertain_visibility'].includes(cycle.status) ||
          ![cycle.start,cycle.peak,cycle.returned].every(window => Array.isArray(window) && window.length === 2 && window.every(Number.isFinite) && window[0] >= label.originSeconds && window[0] <= window[1]) ||
          cycle.peak[0] <= previousPeak || cycle.start[0] > cycle.peak[0] || cycle.peak[0] > cycle.returned[0]) throw new Error('Invalid cycle label timeline');
      previousPeak = cycle.peak[1]; seen.add(cycle.id);
    }
    const claimed = new Set();
    let previousEnd = -1;
    const events = result.candidateRepetitions.map((rep, index) => {
      const values = [rep.startedAtSeconds,rep.peakAtSeconds,rep.loweredAtSeconds,rep.completedAtSeconds];
      if (!values.every(Number.isFinite) || values[0] < previousEnd || values[0] > values[1] || values[1] > values[2] || values[2] > values[3]) throw new Error('Invalid predicted cycle timeline');
      previousEnd = values[3];
      const times = values.map(value => value + result.originSeconds);
      const matches = label.cycles.filter(cycle => !claimed.has(cycle.id) && cycle.status === 'observable_roundtrip' &&
        [cycle.start,cycle.peak,cycle.returned].every((window, i) => times[i] >= window[0] && times[i] <= window[1]));
      const matched = matches.length === 1 ? matches[0] : null;
      if (matched) claimed.add(matched.id);
      return { index: index + 1, start: times[0], peak: times[1], returned: times[2], confirmed: times[3], labelId: matched?.id ?? null,
        status: matched ? 'one-cycle-in-reviewed-windows' : 'unmatched-predicted-cycle' };
    });
    const unmatchedLabels = label.cycles.filter(cycle => !claimed.has(cycle.id)).map(cycle => ({ id: cycle.id, status: cycle.status }));
    return { id: label.id, side: label.side, events, unmatchedLabels,
      status: unmatchedLabels.length === 0 && events.length === label.cycles.length && events.every(event => event.labelId !== null) ? 'pass' : 'needs-review' };
  });
  return { schema: 'fox.video_cycle_evaluation.v1', status: segments.every(segment => segment.status === 'pass') ? 'coarse-cycle-window-pass' : 'partial-not-accepted',
    labelMethod: labels.labelMethod, heldOut: labels.heldOut,
    evidenceBoundary: 'Coarse visual intervals on a development video, not framewise truth, form assessment or M4 acceptance', segments };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv.length !== 4) throw new Error('Usage: vision-cycle-check <cycle-labels.json> <replay.json>');
    const result = checkCycleReplay(JSON.parse(await readFile(process.argv[2], 'utf8')), JSON.parse(await readFile(process.argv[3], 'utf8')));
    console.log(JSON.stringify(result, null, 2));
    if (result.status === 'partial-not-accepted') process.exitCode = 2;
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
