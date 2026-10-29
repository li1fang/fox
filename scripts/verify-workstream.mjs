import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {readFile} from 'node:fs/promises';
import {execFile, spawnSync} from 'node:child_process';
import {promisify, isDeepStrictEqual} from 'node:util';
import {checkedCatalogue} from './test-inventory.mjs';
import {runSuite, execute} from './trial-suite.mjs';
import {artifact} from './trial-readiness.mjs';
import {environment, root, doctor, assertXcodeVersion, evidencePath} from './development-environment.mjs';
import {executeAdmitted, nativeScratchPath, swiftJobs} from './native-resource.mjs';

const lanes = {
  client: {classes: ['TrainingTests', 'TrialConfirmationTests', 'GuidanceTests'],
    boundary: 'Training lifecycle, confirmation and guidance contracts, not SwiftUI, App stores, keyboard, camera or accessibility.'},
  vision: {classes: ['PoseStartGateTests', 'PoseSessionTests', 'MotionStrategyTests', 'PoseTests', 'LatPulldownTests'],
    boundary: 'Explicit 41-test starting subset, not all motion tests, Apple Vision, controller replay or real camera accuracy.'},
  data: {files: ['tests/scripts/test_archive.py', 'tests/scripts/test_archive_batch.py', 'tests/scripts/test_training_store.py'],
    boundary: 'Synthetic archive and record/attachment relations only; no production data, credentials or live analysis.'},
  storage: {targets: ['FoxJournalCoreTests', 'FoxSyncCoreTests'], files: ['tests/scripts/test_personal_sync.py', 'tests/scripts/test_sync_https.py', 'tests/scripts/test_sync_pairing.py'],
    boundary: 'Host storage/transport and synthetic service contracts; no iOS SDK compile, Keychain App-host or physical synchronization.'},
  tooling: {files: ['tests/scripts/native-resource.test.mjs', 'tests/scripts/workstream-verification.test.mjs',
    'tests/scripts/verification.test.mjs', 'tests/scripts/trial-suite.test.mjs'],
    boundary: 'Focused verifier/admission regressions with fake native commands, not product or complete public acceptance.'}
};

export function parseWorkstreamArgs(argv) {
  const args = [...argv], result = {lane: args.shift()};
  if (!Object.hasOwn(lanes, result.lane)) throw Error('Choose workstream lane: client, vision, data, storage or tooling');
  const seen = new Set();
  while (args.length) {
    const key = args.shift();
    if (!['--list', '--output'].includes(key) || seen.has(key)) throw Error(`Invalid workstream option: ${key}`);
    seen.add(key);
    if (key === '--list') result.list = true;
    else {
      const value = args.shift();
      if (!value || value.startsWith('--')) throw Error('Output requires a fresh directory');
      result.output = value;
    }
  }
  return result;
}

export function workstreamPlan(lane, catalogue, directory, platform = process.platform) {
  const spec = lanes[lane];
  if (!spec) throw Error(`Unknown workstream lane: ${lane}`);
  const required = [...(spec.files ?? []), ...(spec.classes ?? []).map(name => `FoxTrainingCoreTests/${name}/`),
    ...(spec.targets ?? []).map(target => `${target}/`)];
  const selectedTests = [];
  for (const selector of required) {
    const matches = catalogue.filter(t => selector.endsWith('/') ? t.id.startsWith(selector) : t.file === selector);
    if (!matches.length) throw Error(`Missing or empty workstream selection: ${selector}`);
    if (matches.some(t => t.scope !== 'public' || t.surface !== 'host')) throw Error(`Workstream selection must be public host: ${selector}`);
    selectedTests.push(...matches.map(t => t.id));
  }
  if (new Set(selectedTests).size !== selectedTests.length) throw Error('Duplicate workstream selection');
  const selected = new Set(selectedTests), bundle = path.join(directory, 'bundle'), python = environment.FOX_JOURNAL_PYTHON;
  const steps = [];
  if (spec.classes) {
    steps.push({id: 'stage', command: python, args: ['scripts/vision-core-offline.py', 'stage', bundle, ...spec.classes.flatMap(name => ['--class', name])]},
      {id: 'bundle-before', command: python, args: ['scripts/vision-core-offline.py', 'check', bundle]},
      {id: `${lane}-contracts`, command: platform === 'darwin' ? 'xcrun' : 'swift',
        args: [...(platform === 'darwin' ? ['swift'] : []), 'test', '--package-path', bundle,
          '--scratch-path', nativeScratchPath(`workstream-${lane}`), '--jobs', String(swiftJobs())],
        ...(platform === 'darwin' ? {resource: 'mac-native'} : {}), native: true, expectedNative: selectedTests,
        env: {FOX_GUIDANCE_REQUIRE_PRIVATE: '0', FOX_GUIDANCE_EVIDENCE_DIR: directory, FOX_M3_EVIDENCE_DIR: directory}},
      {id: 'bundle-after', command: python, args: ['scripts/vision-core-offline.py', 'check', bundle]});
  }
  if (spec.targets) {
    if (platform !== 'darwin') throw Error('Storage Swift packages require macOS; use the data lane for portable archive contracts');
    for (const [id, file, target] of [['journal', 'test-journal.mjs', 'FoxJournalCoreTests'], ['sync-native', 'test-sync-native.mjs', 'FoxSyncCoreTests']]) {
      steps.push({id, command: 'node', args: [`scripts/${file}`, '--host-only'], resource: 'mac-native', native: true,
        expectedNative: catalogue.filter(t => selected.has(t.id) && t.id.startsWith(target + '/')).map(t => t.id)});
    }
  }
  const files = spec.files ?? [];
  if (files.length) steps.push(lane === 'tooling'
    ? {id: 'tooling', command: 'node', args: ['--test', ...files], audit: 'node'}
    : {id: 'data-contracts', command: python, args: ['scripts/run-python-tests.py', ...files], audit: 'python'});
  return {lane, steps, selectedTests, excludedTests: catalogue.filter(t => !selected.has(t.id))
    .map(t => ({id: t.id, scope: t.scope, reason: 'Outside this explicitly scoped development lane; retained in full acceptance.'})),
    evidenceBoundary: spec.boundary, simulatorCount: 0};
}

export async function runWorkstream({lane, output, list = false}) {
  const directory = path.resolve(output ?? path.join(evidencePath('verification'), `workstream-${lane}-${new Date().toISOString().replace(/[:.]/g, '-')}`));
  const catalogue = await checkedCatalogue(), plan = workstreamPlan(lane, catalogue, directory);
  if (list) { console.log(JSON.stringify(plan, null, 2)); return plan; }
  const git = spawnSync('git', ['rev-parse', 'HEAD'], {cwd: root, encoding: 'utf8'});
  if (git.status !== 0) throw Error('Cannot identify workstream source');
  const metadata = {scope: 'development/workstream', component: lane, commit: git.stdout.trim(),
    selectedTests: plan.selectedTests, excludedTests: plan.excludedTests, evidenceBoundary: plan.evidenceBoundary,
    environment: {simulatorsCreated: 0, devicesAccessed: false}};
  let checked = false, manifestPin;
  const preflight = async () => {
    if (process.env.FOX_SIMULATOR_SESSION_TOKEN) throw Error('Nested workstream verification is unsupported; run verify:workstream directly');
    if (process.env.FOX_PRIVATE_INPUT_MANIFEST) throw Error('Workstream lanes must not receive private inputs');
    if (!checked) {
      Object.assign(metadata.environment, doctor({native: false}));
      if (plan.steps.some(s => s.resource)) {
        const xcode = await promisify(execFile)('xcodebuild', ['-version'], {env: environment, timeout: 30000});
        assertXcodeVersion(xcode.stdout.trim());
        metadata.environment.xcode = xcode.stdout.trim();
      }
      checked = true;
    }
    return [];
  };
  const receipt = await runSuite({directory, steps: plan.steps, metadata, preflight,
    execute: async (step, options) => {
      if (manifestPin && !isDeepStrictEqual(await artifact(directory, 'bundle/manifest.json'), manifestPin)) throw Error('Staged manifest changed');
      const result = await (step.resource ? executeAdmitted : execute)(step, options);
      if (step.id === 'stage' && result.code === 0) {
        const manifest = JSON.parse(await readFile(path.join(directory, 'bundle/manifest.json')));
        if (!isDeepStrictEqual([...manifest.expectedTests].sort(), [...plan.selectedTests].sort())) throw Error('Staged selection differs from catalogue plan');
        manifestPin = await artifact(directory, 'bundle/manifest.json');
        metadata.environment.bundleManifest = manifestPin;
      }
      return result;
    }});
  console.log(JSON.stringify({status: receipt.status, scope: receipt.scope, lane, receipt: path.join(directory, 'suite.json'), deviceVerified: false}));
  return receipt;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runWorkstream(parseWorkstreamArgs(process.argv.slice(2))).catch(error => { console.error(error.message); process.exitCode = 1; });
}
