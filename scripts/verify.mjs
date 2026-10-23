import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {readFile} from 'node:fs/promises';
import {isDeepStrictEqual} from 'node:util';
import {runSuite, suiteSteps, fingerprint, compareHistory} from './trial-suite.mjs';
import {doctor, root, allocateSimulators, releaseSimulators} from './development-environment.mjs';
import {checkedCatalogue} from './test-inventory.mjs';
import {validatePrivateInputs} from './private-inputs.mjs';
import {artifact} from './trial-readiness.mjs';
import {auditReceipt, auditNativeCoverage, auditCommandOutput} from './verification-contracts.mjs';

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

export async function runVerification({scope = 'fast', component = 'all', output} = {}) {
  if (!['fast', 'public', 'private'].includes(scope) || !['all', 'web', 'native'].includes(component)) throw Error('Invalid verification scope/component');
  if (scope === 'private' && component !== 'all') throw Error('Private acceptance requires the complete suite');
  const directory = path.resolve(output ?? path.join(root, '.tmp/verification', `${scope}-${component}-${new Date().toISOString().replace(/[:.]/g, '-')}`));
  const git = args => {
    const p = spawnSync('git', args, {cwd: root, encoding: 'utf8'});
    if (p.status !== 0) throw Error('Cannot inspect Git identity');
    return p.stdout.trim();
  };
  const metadata = {scope, component, commit: git(['rev-parse', 'HEAD']),
    dirty: !!git(['status', '--porcelain']), environment: {}, excludedTests: [],
    evidenceBoundary: 'Software verification only. No device installation, camera accuracy, audibility, or human acceptance claim.'};
  const steps = [];
  let lease;
  const preflight = async () => {
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
    const result = await runSuite({directory, steps, preflight, finalize, metadata});
    console.log(JSON.stringify({status: result.status, scope, component, receipt: path.join(directory, 'suite.json'), deviceVerified: false}));
    return result;
  } catch (error) { console.error(`Receipt retained: ${path.join(directory, 'suite.json')}`); throw error; }
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2), option = key => args.includes(key) ? args[args.indexOf(key) + 1] : undefined;
  const action = args[0] === 'receipt'
    ? verifyReceipt(args[1],option('--scope') ?? 'public',option('--component') ?? 'all').then(x=>console.log(JSON.stringify(x)))
    : runVerification({scope: args[0], component: option('--component'), output: option('--output')});
  action
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}
