import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { prepareBatch } from '../../scripts/vision-batch.mjs';
import { archiveBatch, verifyRun, indexRun, queryRuns, rebuildIndex } from '../../scripts/vision-evidence.mjs';

const hash = data => createHash('sha256').update(data).digest('hex');
async function fixture(t, phase = 'completed') {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-evidence-'));
  t.after(() => rm(dir, {recursive:true,force:true}));
  const input = path.join(dir,'input.jsonl'); await writeFile(input,'private input');
  const spec = {id:'lat-left',exercise:'latPulldown',arm:'left',startSeconds:0,endSeconds:10,rebindAtSeconds:[]};
  const job = await prepareBatch({source:input,kind:'cache',cases:[spec],destination:path.join(dir,'jobs')});
  const jobBytes = await readFile(path.join(job.directory,'job.json')), parsed = JSON.parse(jobBytes);
  const folder = path.join(dir,'result'); await mkdir(folder);
  const settings = Buffer.from(JSON.stringify({configuration:{name:'test'},runtimePolicy:{}}));
  const result = Buffer.from(JSON.stringify({schema:'fox.vision_batch_result.v1',jobID:job.id,jobSHA256:hash(jobBytes),
    mode:'controller',inputAssets:parsed.files,inferencePerformed:false,observationFrameCount:100,
    settings:JSON.parse(settings),settingsSHA256:hash(settings),algorithms:{latPulldown:'lat_pulldown_2d_v1'},
    appVersion:'0.6.6',appBuild:'22',device:'synthetic-device',platform:'test',controllerVersion:'m1',
    evidenceBoundary:'offline-observations-through-real-controller-not-live-camera-or-new-human-acceptance',
    cases:[{specification:spec,originSeconds:1,repetitions:[{completedAtSeconds:3},{completedAtSeconds:7,
      precedingReturn:{repetitionIndex:0,measurement:{status:'measured',durationSeconds:1.2}}}],resetCounts:{dropout:1},trace:[]}]}));
  await writeFile(path.join(folder,'result.json'), result); await writeFile(path.join(folder,'settings.json'),settings);
  const files = [['result.json',result],['settings.json',settings]].map(([path,bytes])=>({path,bytes:bytes.length,sha256:hash(bytes)}));
  await writeFile(path.join(folder,'status.json'),JSON.stringify({schema:'fox.vision_batch_status.v1',jobID:job.id,
    jobSHA256:hash(jobBytes),phase,files:phase === 'completed' ? files : [],...(phase==='completed'?{}:{error:'cancelled or failed'})}));
  return {dir,folder,job,archiveRoot:path.join(dir,'runs'),db:path.join(dir,'index.sqlite')};
}
test('immutable run freezes inputs/settings/results without asserting missing labels or source identity', async t => {
  const f=await fixture(t), run=await archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot});
  const {manifest}=await verifyRun(run.directory);
  assert.equal(manifest.status,'completed'); assert.equal(manifest.evidenceKind,'controller_cache');
  assert.equal(manifest.execution.sourceSHA256,null); assert.deepEqual(manifest.motionStrategies,[]);
  assert.equal(manifest.cases[0].automaticCount,2); assert.equal(manifest.cases[0].returnIntervals,1);
  assert.equal(manifest.cases[0].referenceCount,null); assert.equal(manifest.cases[0].countError,null);
  assert.equal(manifest.acceptance,'not_assessed');
  assert.equal(await readFile(path.join(f.dir,'input.jsonl'),'utf8'),'private input');
  const original=await readFile(path.join(run.directory,'run.json'));
  assert.equal((await archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot})).directory,run.directory);
  assert.deepEqual(await readFile(path.join(run.directory,'run.json')),original);
});
test('index is idempotent, queryable and rebuildable only from verified archives', async t => {
  const f=await fixture(t), run=await archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot});
  await indexRun(f.db,run.directory); await indexRun(f.db,run.directory);
  const first=await queryRuns(f.db,{exercise:'latPulldown'}); assert.equal(first.length,1);
  assert.equal(first[0].automatic_count,2); assert.equal(first[0].reference_count,null);
  assert.deepEqual(await queryRuns(f.db,{exercise:'curl'}),[]);
  await rebuildIndex(f.db,f.archiveRoot);
  assert.deepEqual(await queryRuns(f.db,{exercise:'latPulldown'}),first);
  await writeFile(path.join(run.directory,'result.json'),'{}');
  await assert.rejects(rebuildIndex(f.db,f.archiveRoot),/checksum/i);
  assert.deepEqual(await queryRuns(f.db,{exercise:'latPulldown'}),first,'failed rebuild preserves old index');
});
test('changed receipt or conflicting ID never overwrites original archive', async t => {
  const f=await fixture(t), run=await archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot});
  const before=await readFile(path.join(run.directory,'run.json'));
  await writeFile(path.join(f.folder,'result.json'),'{}');
  await assert.rejects(archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot}),/checksum/i);
  assert.deepEqual(await readFile(path.join(run.directory,'run.json')),before);
  const status=JSON.parse(await readFile(path.join(f.folder,'status.json'))); status.phase='cancelled'; status.files=[];
  await writeFile(path.join(f.folder,'status.json'),JSON.stringify(status));
  await assert.rejects(archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot}),/conflict/i);
});
test('failed and cancelled runs remain searchable failures, unfinished runs are rejected', async t => {
  for(const phase of ['failed','cancelled','replaying']) {
    const f=await fixture(t,phase);
    if(phase==='replaying') { await assert.rejects(archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot}),/terminal/i); continue; }
    const run=await archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot});
    await indexRun(f.db,run.directory);
    const rows=await queryRuns(f.db,{}); assert.equal(rows[0].status,phase); assert.equal(rows[0].acceptance,'not_assessed');
    assert.equal(rows[0].automatic_count,null);
  }
});
test('tampered manifest metrics and symlink artifacts are refused', async t => {
  const f=await fixture(t), run=await archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot});
  const filename=path.join(run.directory,'run.json'), original=await readFile(filename), value=JSON.parse(original);
  value.cases[0].automaticCount=999;
  await writeFile(filename,JSON.stringify(value)); await assert.rejects(verifyRun(run.directory),/derived|manifest/i);
  await writeFile(filename,original);
  await rm(path.join(run.directory,'result.json')); await symlink(path.join(f.folder,'result.json'),path.join(run.directory,'result.json'));
  await assert.rejects(verifyRun(run.directory),/unsafe/i);
});
test('index never claims or overwrites a foreign database', async t => {
  const f=await fixture(t), run=await archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot});
  await writeFile(f.db,'not our database');
  await assert.rejects(indexRun(f.db,run.directory));
  await assert.rejects(rebuildIndex(f.db,f.archiveRoot));
  assert.equal(await readFile(f.db,'utf8'),'not our database');
});

test('original v1 controller receipts without mode or frame count remain importable without rewriting', async t => {
  const f=await fixture(t), file=path.join(f.folder,'result.json');
  const result=JSON.parse(await readFile(file)); delete result.mode; delete result.observationFrameCount;
  const bytes=Buffer.from(JSON.stringify(result)); await writeFile(file,bytes);
  const statusFile=path.join(f.folder,'status.json'), status=JSON.parse(await readFile(statusFile));
  status.files[0]={path:'result.json',bytes:bytes.length,sha256:hash(bytes)};
  await writeFile(statusFile,JSON.stringify(status));
  const run=await archiveBatch({resultFolder:f.folder,jobFolder:f.job.directory,archiveRoot:f.archiveRoot});
  assert.equal((await verifyRun(run.directory)).manifest.evidenceKind,'controller_cache');
  assert.deepEqual(await readFile(file),bytes);
});
