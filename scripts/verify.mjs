import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {isDeepStrictEqual} from 'node:util';
import {runSuite, suiteSteps, fingerprint, compareHistory, execute} from './trial-suite.mjs';
import {doctor, root, allocateSimulators, releaseSimulators, isolateSimulatorStep} from './development-environment.mjs';
import {checkedCatalogue} from './test-inventory.mjs';
import {validatePrivateInputs} from './private-inputs.mjs';
import {artifact} from './trial-readiness.mjs';
import {auditReceipt, auditNativeCoverage, auditCommandOutput} from './verification-contracts.mjs';

function checkCandidateCommit(commit) {
  if (typeof commit !== 'string' || !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(commit)) {
    throw Error('Candidate commit must be an explicit full Git object ID, not HEAD or a branch');
  }
}

export function checkCandidate(expectedCommit, cwd = root) {
  checkCandidateCommit(expectedCommit);
  const git = args => {
    const result = spawnSync('git', args, {cwd, encoding: 'utf8'});
    if (result.error || result.status !== 0) throw Error('Candidate Git inspection failed');
    return result.stdout;
  };
  const commit = git(['rev-parse', '--verify', 'HEAD^{commit}']).trim();
  if (commit !== expectedCommit) throw Error(`Candidate commit mismatch: expected ${expectedCommit}, current ${commit}`);
  // NUL output is only checked for emptiness, so unusual filenames cannot hide changes.
  if (git(['status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none']).length) {
    throw Error('Candidate worktree is dirty; preserve changes and finish the candidate before acceptance');
  }
  return {commit};
}

export function parseVerificationArgs(argv) {
  const args = [...argv], mode = args.shift();
  const result = {action: mode === 'receipt' ? 'receipt' : 'run'};
  if (mode === 'receipt') {
    result.filename = args.shift();
    if (!result.filename || result.filename.startsWith('--')) throw Error('Receipt usage requires a filename');
    result.scope = 'public';
  } else result.scope = mode === 'candidate' ? args.shift() : mode;
  result.component = 'all';
  const allowed = mode === 'receipt' ? ['--scope', '--component']
    : mode === 'candidate' ? ['--commit', '--component', '--output'] : ['--component', '--output'];
  const seen = new Set();
  while (args.length) {
    const key = args.shift(), value = args.shift();
    if (!allowed.includes(key) || seen.has(key) || !value || value.startsWith('--')) {
      throw Error(`Invalid or duplicate verification option: ${key}`);
    }
    seen.add(key);
    result[key === '--commit' ? 'candidateCommit' : key.slice(2)] = value;
  }
  if (!['fast', 'public', 'private'].includes(result.scope) || !['all', 'web', 'native'].includes(result.component)) {
    throw Error('Invalid verification scope/component');
  }
  if (result.scope === 'private' && result.component !== 'all') throw Error('Private scope requires the complete suite');
  if (mode === 'candidate') {
    if (result.scope === 'fast') throw Error('Candidate acceptance requires public or private scope');
    checkCandidateCommit(result.candidateCommit);
  }
  return result;
}

export async function verifyReceipt(filename, scope, component = 'all') {
  const file = path.resolve(filename), directory = path.dirname(file), receipt = JSON.parse(await readFile(file));
  const commit = spawnSync('git', ['rev-parse', 'HEAD'], {cwd:root,encoding:'utf8'});
  if (commit.status !== 0) throw Error('Cannot identify current commit');
  const inputs = scope === 'private' ? await validatePrivateInputs(process.env.FOX_PRIVATE_INPUT_MANIFEST) : [];
  if (!isDeepStrictEqual(receipt.inputs, inputs)) throw Error('Receipt inputs mismatch');
  const steps = suiteSteps(directory, {}, inputs, {scope, component, catalogue:await checkedCatalogue()});
  auditReceipt(receipt, {commit:commit.stdout.trim(), sourceSHA256:await fingerprint(), scope, component, stepIds:steps.map(s=>s.id)});
  for (const step of steps) {
    const row = receipt.steps.find(x => x.id === step.id), log = `${step.id}.log`;
    if (row.exitCode !== 0 || !isDeepStrictEqual(await artifact(directory,log),row.log)) throw Error(`Receipt log mismatch: ${step.id}`);
    const output = await readFile(path.join(directory,log),'utf8');
    if (step.native) auditNativeCoverage(output,step.expectedNative);
    if (step.audit) auditCommandOutput(output,step.audit);
    if (step.historyBaseline) compareHistory(JSON.parse(await readFile(step.historyBaseline)),JSON.parse(await readFile(path.join(directory,'history-candidate.json'))));
  }
  return {status:'receipt_verified',scope,component,commit:receipt.commit,deviceVerified:false};
}

export async function runVerification({scope = 'fast', component = 'all', output, candidateCommit} = {}) {
  if (!['fast', 'public', 'private'].includes(scope) || !['all', 'web', 'native'].includes(component)) throw Error('Invalid verification scope/component');
  if (scope === 'private' && component !== 'all') throw Error('Private acceptance requires the complete suite');
  if (candidateCommit !== undefined) {
    checkCandidateCommit(candidateCommit);
    if (scope === 'fast') throw Error('Candidate acceptance requires public or private scope');
  }
  const directory = path.resolve(output ?? path.join(root, '.tmp/verification', `${scope}-${component}-${new Date().toISOString().replace(/[:.]/g, '-')}`));
  const git = args => {
    const p = spawnSync('git', args, {cwd: root, encoding: 'utf8'});
    if (p.status !== 0) throw Error('Cannot inspect Git identity');
    return p.stdout.trim();
  };
  const metadata = {scope, component, commit: git(['rev-parse', 'HEAD']),
    ...(candidateCommit !== undefined ? {candidateCommit} : {}),
    dirty: !!git(['status', '--porcelain']), environment: {simulatorIsolation: []}, excludedTests: [],
    evidenceBoundary: 'Software verification only. No device installation, camera accuracy, audibility, or human acceptance claim.'};
  const steps = [];
  let lease;
  const preflight = async () => {
    // Run before private input reads, catalogue scans, doctor or simulator allocation; recheck at completion.
    if (candidateCommit !== undefined) checkCandidate(candidateCommit);
    if (scope !== 'private' && process.env.FOX_PRIVATE_INPUT_MANIFEST) throw Error('Public/fast runs must not receive private input locations');
    const inputs = scope === 'private' ? await validatePrivateInputs(process.env.FOX_PRIVATE_INPUT_MANIFEST) : [];
    if (!steps.length) {
      const catalogue = await checkedCatalogue();
      const info = doctor({native: component !== 'web'});
      Object.assign(metadata.environment, info);
      if (component !== 'web' && scope !== 'fast') {
        lease = await allocateSimulators(info);
        metadata.environment.simulatorLifecycle = {status: 'allocated', ...lease};
      }
      const devices = lease?.devices ?? {};
      steps.push(...suiteSteps(directory, devices, inputs, {scope, component, catalogue}));
      const selected = new Set(steps.flatMap(s => s.expectedNative ?? []));
      for (const row of catalogue) {
        if (row.id.startsWith('Fox') && !selected.has(row.id)) metadata.excludedTests.push({id: row.id, scope: row.scope,
          reason: row.scope === 'physical' ? 'Physical device gate requires separate authorization; never simulated' :
            row.scope !== 'public' && scope !== 'private' ? 'Not in public/synthetic evidence scope' : 'Not in this tier/component; retained in the full suite'});
        if (!row.id.startsWith('Fox') && row.scope !== 'public' && scope !== 'private') metadata.excludedTests.push({id: row.id, scope: row.scope, reason: 'Private corpus, explicitly not evaluated'});
      }
    }
    return inputs;
  };
  const finalize = async () => {
    if (!lease) return;
    try {
      await releaseSimulators(lease);
      metadata.environment.simulatorLifecycle.status = 'released';
    } catch (error) {
      metadata.environment.simulatorLifecycle.status = 'cleanup_failed';
      throw error;
    }
  };
  try {
    const result = await runSuite({directory, steps, preflight, finalize, metadata,
      execute: async (step, options) => {
        const isolation = await isolateSimulatorStep(lease, step);
        if (isolation) metadata.environment.simulatorIsolation.push(isolation);
        return execute(step, options);
      }
    });
    console.log(JSON.stringify({status: result.status, scope, component, receipt: path.join(directory, 'suite.json'), deviceVerified: false}));
    return result;
  } catch (error) { console.error(`Receipt retained: ${path.join(directory, 'suite.json')}`); throw error; }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  Promise.resolve().then(() => {
    const options = parseVerificationArgs(process.argv.slice(2));
    return options.action === 'receipt'
      ? verifyReceipt(options.filename, options.scope, options.component).then(x=>console.log(JSON.stringify(x)))
      : runVerification(options);
  })
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}
