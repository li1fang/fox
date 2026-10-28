import { test } from 'node:test';
import assert from 'node:assert/strict';
import { observe, validateCoverage } from '../../scripts/design-review.mjs';
import * as design from '../../scripts/design-review.mjs';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {mkdirSync, writeFileSync} from 'node:fs';
const observation = frame => ({ schema: 'fox.design_observation.v1', source: 'isolated-design-fixture', scenario: 'sample',
  viewport: { x: 0, y: 0, width: 400, height: 800 }, elements: [{ id: 'primary', frame }] });
test('design geometry records containment without claiming usability', () => {
  const [r] = observe(observation({ x: 20, y: 60, width: 200, height: 44 }));
  assert.equal(r.visibleFractionWithinWindow, 1);
  assert.equal(r.conclusion, 'geometry-only-not-usability-acceptance');
});
test('offscreen and partial content are observations, not an automatic scroll failure', () => {
  assert.equal(observe(observation({ x: 0, y: 790, width: 200, height: 20 }))[0].observation, 'partly-outside-window');
  assert.equal(observe(observation({ x: 0, y: 900, width: 200, height: 20 }))[0].observation, 'outside-window');
});
test('invalid geometry stays unknown rather than passing a layout check', () => {
  assert.equal(observe(observation({ x: 0, y: 0, width: 0, height: 20 }))[0].conclusion, 'unknown');
  assert.throws(() => observe({ ...observation({}), viewport: { x: 0 } }));
});
test('real data and unrelated report formats cannot masquerade as design fixtures', () => {
  assert.throws(() => observe({ ...observation({}), source: 'camera' }));
  assert.throws(() => observe({ ...observation({}), schema: 'other' }));
});
test('combined groups cannot hide a missing test method behind other screenshots', () => {
  const report = { observations: [{ test: 'FoxDesignReviewUITests/testHomeScenarios()' }] };
  assert.doesNotThrow(() => validateCoverage(report, ['testHomeScenarios']));
  assert.throws(() => validateCoverage(report, ['testHomeScenarios', 'testTrainingScenarios']), /testTrainingScenarios/);
});

test('design arguments are strict and overlapping groups select methods once', () => {
  const options = design.parseDesignArguments(['run', '--group', 'home,home-smoke,training,training-feedback', '--device', 'iphone']);
  const methods = design.designMethods(options.groups);
  assert.equal(methods.length, new Set(methods).size);
  assert(methods.includes('testHomeScenarios') && methods.includes('testHomeSmokeScenarios'));
  assert(methods.includes('testTrainingRotatedFeedbackInput'));
  for (const args of [['run','--typo'], ['run','--device'], ['run','--device','ipad','--device','iphone'],
    ['run','--group','home,'], ['run','--group','unknown'], ['collect'], ['run','--result','old'], ['run','--device','duo']]) {
    assert.throws(() => design.parseDesignArguments(args));
  }
});

async function designHarness(t, changes = {}) {
  const output = await mkdtemp(path.join(tmpdir(), 'fox-design-entry-'));
  t.after(() => rm(output, {recursive:true, force:true}));
  const calls = [], methods = design.designMethods(['training-feedback']);
  const deps = {
    env: {}, fingerprint: async () => 'frozen', identity: () => ({commit:'a'.repeat(40),dirty:true}),
    catalogue: async () => methods.map(name => ({id:`FoxUITests/FoxDesignReviewUITests/${name}`,scope:'public',surface:'ipad'})),
    doctor: () => { calls.push('doctor'); return {simulatorRuntime:'pinned'}; },
    allocate: async (_, options) => { calls.push(['allocate', options]); return {devices:{ipad:'owned'},created:['owned']}; },
    isolate: async () => { calls.push('isolate'); },
    release: async () => { calls.push('release'); },
    execute: async step => { calls.push(step); return {code:0,output:step.native
      ? methods.map(name => `Test Case '-[FoxUITests.FoxDesignReviewUITests ${name}]' passed (1.0 seconds).`).join('\n') : 'collected'}; },
    ...changes
  };
  return {output,calls,deps,options:{command:'run',groups:['training-feedback'],device:'ipad',output}};
}

test('design entry uses shared lifecycle and real suite coverage rather than direct xcodebuild', async t => {
  const h = await designHarness(t);
  const receipt = await design.runDesignReview(h.options, h.deps);
  assert.equal(receipt.scope,'diagnostic'); assert.equal(receipt.deviceVerified,false);
  assert.equal(receipt.environment.simulatorLifecycle.status,'released');
  const step = h.calls.find(x => x?.native);
  assert.deepEqual(step.args,['scripts/ipad.mjs','test-ui']);
  assert.equal(step.env.FOX_IOS_UI_RESULT,path.join(h.output,'result.xcresult'));
  assert.deepEqual(h.calls.find(x => Array.isArray(x))[1],{families:['ipad'],overrides:{}});
  assert(h.calls.indexOf('release') > h.calls.indexOf(step));
});

test('private inputs and wrong classification fail before environment or simulator allocation', async t => {
  for (const changes of [{env:{FOX_PRIVATE_INPUT_MANIFEST:'/not-read'}},
    {env:{TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST:'/not-read'}}, {catalogue:async()=>[]}]) {
    const h = await designHarness(t,changes);
    await assert.rejects(design.runDesignReview(h.options,h.deps));
    assert.deepEqual(h.calls,[]);
    const r=JSON.parse(await readFile(path.join(h.output,'suite.json')));
    assert.equal(r.status,'failed'); assert.equal(r.steps.length,0);
  }
});

test('environment and busy lease errors do not execute or release foreign devices', async t => {
  for(const changes of [{doctor:()=>{throw Error('wrong runtime');}}, {allocate:async()=>{throw Error('session busy');}}]) {
    const h=await designHarness(t,changes);
    await assert.rejects(design.runDesignReview(h.options,h.deps),/runtime|busy/);
    assert(!h.calls.includes('release')); assert(!h.calls.some(x=>x?.command));
  }
});

test('missing native methods, cancellation and failed cleanup cannot pass design capture', async t => {
  for(const [changes,status] of [
    [{execute:async()=>({code:0,output:'TEST SUCCEEDED'})},'failed'],
    [{execute:async()=>{process.emit('SIGTERM');return {code:0,output:'cancelled'};}},'cancelled'],
    [{release:async()=>{throw Error('cleanup failed');}},'failed']]) {
    const h=await designHarness(t,changes);
    await assert.rejects(design.runDesignReview(h.options,h.deps));
    assert.equal(JSON.parse(await readFile(path.join(h.output,'suite.json'))).status,status);
  }
});

test('design evidence requires successful result and screenshots for requested scenes', () => {
  const report={testResult:'Passed',observations:[{test:'FoxDesignReviewUITests/testHomeSmokeScenarios()',scenario:'home-mixed',screenshot:'x.png'}]};
  assert.throws(()=>design.validateDesignEvidence(report,['testHomeSmokeScenarios']),/scene/i);
  assert.throws(()=>design.validateDesignEvidence({...report,testResult:'Failed'},['testHomeSmokeScenarios']),/result/i);
});

test('scene ownership retains every catalogue scene exactly once and every prior interaction capture', async () => {
  const source = await readFile(new URL('../../apps/ipad/FoxNative/DesignScenarioCatalog.swift', import.meta.url), 'utf8');
  const declared = [...source.matchAll(/\b\w+ = "((?:home|record|projection|training)-[^"]+)"/g)].map(x => x[1]);
  const scenes = Object.values(design.designScenes).flat();
  assert.equal(new Set(scenes).size, scenes.length);
  for (const id of declared) assert.equal(scenes.filter(scene => scene === id).length, 1, id);
  const testSource = await readFile(new URL('../../apps/ipad/FoxUITests/FoxDesignReviewUITests.swift', import.meta.url), 'utf8');
  assert.match(testSource, /captureScenes\(DesignScenario\.homeRemainingCases\)/);
  assert.match(testSource, /captureScenes\(DesignScenario\.homeSmokeCases\)/);
  assert.match(testSource, /captureTrainingScenes\(DesignScenario\.trainingRemainingCases\)/);
  for (const id of ['training-feedback-keyboard','training-feedback-rotated-left-input','training-feedback-rotated-keyboard']) assert(scenes.includes(id));
});

async function collectFixture(t, trees) {
  const output = await mkdtemp(path.join(tmpdir(), 'fox-design-text-'));
  t.after(() => rm(output, {recursive:true, force:true}));
  const testIdentifier = 'FoxDesignReviewUITests/testHomeScenarios()';
  const geometry = {...observation({x:0,y:0,width:44,height:44}), scenario:'home-empty',
    elementOrder:'requested-target-order', elements:[{id:'home-try-training', axQueryIndex:2,
      frame:{x:0,y:0,width:44,height:44}, label:'试练一组', enabled:true, hittable:true}]};
  const execute = (command, args) => {
    assert.equal(command, 'xcrun');
    if (args[1] === 'get') return {status:0,stdout:JSON.stringify({result:'Passed',devicesAndConfigurations:[]})};
    assert.deepEqual(args.slice(0,3), ['xcresulttool','export','attachments']);
    const directory = args.at(-1);
    mkdirSync(directory, {recursive:true});
    writeFileSync(path.join(directory,'geometry.json'), JSON.stringify(geometry));
    const attachments = [{suggestedHumanReadableName:'design-home-empty-geometry_1.json',exportedFileName:'geometry.json'}];
    const manifest = [{testIdentifier,attachments}];
    for (const [index, tree] of trees.entries()) {
      const name = `tree-${index}.txt`;
      writeFileSync(path.join(directory,name), 'Synthetic accessibility tree');
      const item = {suggestedHumanReadableName:tree.name,exportedFileName:name};
      if (tree.test === undefined) attachments.push(item);
      else manifest.push({testIdentifier:tree.test,attachments:[item]});
    }
    writeFileSync(path.join(directory,'manifest.json'),JSON.stringify(manifest));
    return {status:0,stdout:''};
  };
  return {output, collect:()=>design.collect('/synthetic/result.xcresult',output,null,execute)};
}

test('collected design report links the matching accessibility text and retains query-order evidence', async t => {
  const fixture = await collectFixture(t, [
    {name:'design-home-empty-accessibility_other.txt',test:'OtherTests/testHomeScenarios()'},
    {name:'design-home-empty-detail-accessibility_wrong.txt'},
    {name:'design-home-empty-accessibility_match.txt'}
  ]);
  const result = fixture.collect();
  assert.equal(result.observations[0].accessibilityTree,'attachments/tree-2.txt');
  assert.equal(result.observations[0].elementOrder,'requested-target-order');
  assert.equal(result.observations[0].elements[0].axQueryIndex,2);
  assert.equal(result.observations[0].elements[0].conclusion,'geometry-only-not-usability-acceptance');
  const html = await readFile(path.join(fixture.output,'index.html'),'utf8');
  assert.match(html,/href="attachments\/tree-2.txt"/);
  const stored = JSON.parse(await readFile(path.join(fixture.output,'report.json'),'utf8'));
  assert.equal(stored.observations[0].accessibilityTree,'attachments/tree-2.txt');
});

test('missing accessibility text remains explicit and does not borrow another scene or method', async t => {
  const fixture = await collectFixture(t, [
    {name:'design-home-empty-accessibility_wrong.txt',test:'OtherTests/testHomeScenarios()'},
    {name:'design-home-empty-detail-accessibility_wrong.txt'}
  ]);
  assert.equal(fixture.collect().observations[0].accessibilityTree,null);
  assert.match(await readFile(path.join(fixture.output,'index.html'),'utf8'),/Missing accessibility text/);
});

test('ambiguous accessibility attachments cannot silently become one observation', async t => {
  const fixture = await collectFixture(t,[{name:'design-home-empty-accessibility_a.txt'},{name:'design-home-empty-accessibility_b.txt'}]);
  assert.throws(()=>fixture.collect(),/Duplicate accessibility text/);
});

test('unmeasurable geometry preserves non-geometric accessibility evidence', () => {
  const element = {id:'home-training-retry', label:'重试', enabled:true, hittable:false, axQueryIndex:7,
    frame:{x:0,y:0,width:0,height:0}};
  const report = {...observation(element.frame), elements:[element]};
  assert.deepEqual(observe(report), [{...element, observation:'unmeasurable', conclusion:'unknown'}]);
});
