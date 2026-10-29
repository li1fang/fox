import test from 'node:test';
import assert from 'node:assert/strict';
import path from 'node:path';
import {mkdtemp, rm, readFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {checkedCatalogue} from '../../scripts/test-inventory.mjs';
import * as streams from '../../scripts/verify-workstream.mjs';
import * as verification from '../../scripts/verify.mjs';
import {suiteSteps, runSuite} from '../../scripts/trial-suite.mjs';
import {auditNativeSelection, auditReceipt} from '../../scripts/verification-contracts.mjs';

test('workstream plans use original registered public tests and never create simulators', async () => {
  const catalogue = await checkedCatalogue();
  for (const lane of ['client', 'vision', 'data', 'storage', 'tooling']) {
    const plan = streams.workstreamPlan(lane, catalogue, '/fresh', 'darwin');
    assert.ok(plan.selectedTests.length);
    assert.equal(new Set(plan.selectedTests).size, plan.selectedTests.length);
    assert.ok(plan.selectedTests.every(id => catalogue.some(t => t.id === id && t.scope === 'public' && t.surface === 'host')));
    assert.ok(plan.steps.every(s => !s.args.includes('test-ui') && !s.args.includes('build-simulator') && !s.args.includes('simctl')));
    const omitted = new Set(plan.excludedTests.map(t => t.id));
    assert.ok(catalogue.every(t => omitted.has(t.id) !== plan.selectedTests.includes(t.id)));
  }
  const data = streams.workstreamPlan('data', catalogue, '/fresh', 'linux');
  assert.ok(data.steps.every(s => !s.resource));
  const vision = streams.workstreamPlan('vision', catalogue, '/fresh', 'linux');
  assert.ok(vision.steps.every(s => s.command !== 'xcrun' && !s.resource));
  assert.ok(vision.steps.some(s => s.command === 'swift' && s.expectedNative.length === 41));
});

test('selection fails closed on missing classes, private classification and unknown lane', async () => {
  const catalogue = await checkedCatalogue();
  assert.throws(() => streams.workstreamPlan('unknown', catalogue, '/fresh'), /lane/);
  assert.throws(() => streams.workstreamPlan('client', [], '/fresh'), /missing|empty/i);
  const changed = structuredClone(catalogue);
  changed.find(t => t.id.startsWith('FoxTrainingCoreTests/TrainingTests/')).scope = 'private';
  assert.throws(() => streams.workstreamPlan('client', changed, '/fresh'), /public/);
  const missing = catalogue.filter(t => !t.file.endsWith('/test_archive.py'));
  assert.throws(() => streams.workstreamPlan('data', missing, '/fresh'), /missing/i);
});

test('scoped CLI rejects ambiguous flags and cannot silently become full candidate acceptance', () => {
  assert.deepEqual(streams.parseWorkstreamArgs(['vision', '--list']), {lane: 'vision', list: true});
  assert.equal(streams.parseWorkstreamArgs(['client', '--output', '/fresh']).output, '/fresh');
  for (const args of [[], ['public'], ['data', '--commit', 'abc'], ['client', '--output'], ['vision', '--list', '--list']]) {
    assert.throws(() => streams.parseWorkstreamArgs(args));
  }
  assert.throws(() => auditReceipt({status: 'software_suite_passed', scope: 'development/workstream',
    component: 'client', deviceVerified: false, commit: 'a', sourceSHA256: 'b', steps: [{status: 'passed'}]},
  {scope: 'public', component: 'all', commit: 'a', sourceSHA256: 'b'}), /scope/);
});

test('missing, skipped or duplicate native results fail a scoped suite unchanged', async t => {
  const temp = await mkdtemp(path.join(tmpdir(), 'fox-scoped-'));
  t.after(() => rm(temp, {recursive: true, force: true}));
  const expected = ['FoxTrainingCoreTests/TrainingTests/testOne'];
  const good = "Test Case 'TrainingTests.testOne' passed (0.1 seconds).";
  let index = 0;
  for (const output of ['', good.replace('passed', 'skipped'), `${good}\n${good}`]) {
    const directory = path.join(temp, String(++index));
    await assert.rejects(runSuite({directory, steps: [{id: 'client', command: 'fixture', args: [], native: true, expectedNative: expected}],
      preflight: async () => [], fingerprint: async () => 'same',
      execute: async () => ({code: 0, output}), metadata: {scope: 'development/workstream'}}), /coverage|skipped|duplicate/i);
    assert.equal(JSON.parse(await readFile(path.join(directory, 'suite.json'))).status, 'failed');
  }
});

test('full native coverage is unchanged and shared simulators are allocated only for actual App tests', async () => {
  const catalogue = await checkedCatalogue();
  for (const scope of ['fast', 'public', 'private']) {
    const steps = suiteSteps('/fresh', {ipad: 'pending:ipad', iphone: 'pending:iphone'}, [], {scope, catalogue});
    auditNativeSelection(catalogue, steps, {scope, component: 'all'});
  }
  const calls = [], metadata = {environment: {simulatorIsolation: []}};
  const executor = verification.createNativeStepExecutor({info: {}, metadata,
    allocate: async () => { calls.push('allocate'); return {devices: {ipad: 'owned-pad', iphone: 'owned-phone'}, created: []}; },
    isolate: async (_lease, step) => { calls.push(`isolate:${step.env.FOX_IOS_SIMULATOR}`); },
    execute: async step => { calls.push(step.id); return {code: 0}; },
    release: async () => { calls.push('release'); }});
  for (const id of ['web', 'core', 'journal', 'native-build']) await executor.run({id, args: []}, {});
  assert.deepEqual(calls, ['web', 'core', 'journal', 'native-build']);
  await executor.run({id: 'app-host', args: ['scripts/ipad.mjs', 'test-ui'], env: {FOX_IOS_SIMULATOR: 'pending:ipad'}}, {});
  await executor.run({id: 'iphone-ui', args: ['scripts/ipad.mjs', 'test-ui'], env: {FOX_IOS_SIMULATOR: 'pending:iphone'}}, {});
  await executor.finalize();
  assert.equal(calls.filter(x => x === 'allocate').length, 1);
  assert.ok(calls.includes('isolate:owned-phone'));
  assert.equal(calls.at(-1), 'release');
});
