import {createHash} from 'node:crypto';
import {readFile, readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

// Timing is diagnosis, never a substitute for verify:receipt or current acceptance.
export function summarizeRuns(samples) {
  const ids = new Set(), statusCounts = {}, intervals = [], methods = [];
  let animationWarnings = 0, incompleteRuns = 0;
  const time = value => {
    const result = typeof value === 'string' ? Date.parse(value) : NaN;
    if (!Number.isFinite(result)) throw Error(`Invalid time: ${value}`);
    return result;
  };
  const runs = samples.map(({id, receipt, logs = []}) => {
    if (ids.has(id)) throw Error(`Duplicate receipt: ${id}`);
    ids.add(id);
    if (receipt.schema !== 'fox.trial_suite.v1') throw Error(`Unsupported receipt: ${id}`);
    const start = time(receipt.startedAt), end = receipt.finishedAt ? time(receipt.finishedAt) : null;
    if (end !== null && end < start) throw Error(`Reversed time: ${id}`);
    if (end === null) incompleteRuns++; else intervals.push([start, end]);
    statusCounts[receipt.status] = (statusCounts[receipt.status] ?? 0) + 1;
    for (const log of logs) {
      animationWarnings += (log.text.match(/App animations complete notification not received/g) ?? []).length;
      for (const match of log.text.matchAll(/^Test Case '([^']+)' (passed|failed|skipped) \(([\d.]+) seconds\)\./gm)) {
        methods.push({run: id, step: log.step, name: match[1], status: match[2], seconds: Number(match[3]), integrity: log.integrity});
      }
    }
    const steps = (receipt.steps ?? []).map(step => ({id: step.id, status: step.status,
      seconds: step.finishedAt ? (time(step.finishedAt) - time(step.startedAt)) / 1000 : null}));
    if (steps.some(step => step.seconds !== null && step.seconds < 0)) throw Error(`Reversed step time: ${id}`);
    return {id, status: receipt.status, scope: receipt.scope, commit: receipt.commit,
      durationSeconds: end === null ? null : (end - start) / 1000, steps,
      logs: logs.map(({step, integrity}) => ({step, integrity}))};
  });
  const merged = [];
  for (const interval of intervals.sort((a, b) => a[0] - b[0])) {
    const last = merged.at(-1);
    if (last && interval[0] <= last[1]) last[1] = Math.max(last[1], interval[1]);
    else merged.push([...interval]);
  }
  return {schema: 'fox.verification_timing.v1', acceptanceClaim: false, statusCounts, incompleteRuns,
    accumulatedSeconds: incompleteRuns ? null : runs.reduce((sum, run) => sum + run.durationSeconds, 0),
    occupiedSeconds: incompleteRuns ? null : merged.reduce((sum, [start, end]) => sum + (end - start) / 1000, 0),
    windowSeconds: incompleteRuns || !merged.length ? null : (merged.at(-1)[1] - merged[0][0]) / 1000,
    animationWarnings, methods: methods.sort((a, b) => b.seconds - a.seconds), runs,
    limitations: ['No human-attention estimate.', 'Animation warnings are not a root-cause diagnosis.',
      'Unverified logs remain diagnostic only; receipt success is historical, not current acceptance.']};
}

export async function readTimingSamples(directories) {
  const samples = [];
  async function walk(directory) {
    for (const item of await readdir(directory, {withFileTypes: true})) {
      const location = path.join(directory, item.name);
      if (item.isDirectory() && !item.name.endsWith('.xcresult')) await walk(location);
      else if (item.isFile() && item.name === 'suite.json') {
        const receipt = JSON.parse(await readFile(location, 'utf8')), logs = [];
        for (const step of receipt.steps ?? []) {
          // Use only the sibling produced by runSuite, never follow receipt-supplied paths.
          if (!/^[a-zA-Z0-9_-]+$/.test(step.id)) throw Error(`Invalid step id: ${step.id}`);
          let bytes;
          try { bytes = await readFile(path.join(directory, `${step.id}.log`)); }
          catch (error) { if (error.code === 'ENOENT') continue; throw error; }
          const integrity = step.log?.sha256 === createHash('sha256').update(bytes).digest('hex')
            && step.log?.bytes === bytes.length ? 'verified' : 'unverified';
          logs.push({step: step.id, text: bytes.toString('utf8'), integrity});
        }
        samples.push({id: location, receipt, logs});
      }
    }
  }
  for (const directory of directories) await walk(path.resolve(directory));
  if (!samples.length) throw Error('No suite.json receipts found');
  return samples;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  Promise.resolve().then(async () => {
    if (!args.length || args.some(arg => arg.startsWith('-'))) throw Error('Usage: node scripts/verification-timing.mjs <receipt-directory> [...]');
    console.log(JSON.stringify(summarizeRuns(await readTimingSamples(args)), null, 2));
  }).catch(error => { console.error(error.message); process.exitCode = 1; });
}
