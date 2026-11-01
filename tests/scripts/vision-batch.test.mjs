import test from 'node:test';
import {archiveBatch,verifyRun,indexRun,queryRuns} from '../../scripts/vision-evidence.mjs';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, mkdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { prepareBatch, validateBatchJob, verifyBatchResult, importBatchResult, batchLaunchEnvironment, batchCounts } from '../../scripts/vision-batch.mjs';

const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const example = { id:'curl-left', exercise:'curl', arm:'left', startSeconds:0, endSeconds:10, rebindAtSeconds:[] };
async function root(t) {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-batch-'));
  t.after(() => rm(dir, { recursive:true, force:true }));
  return dir;
}
test('stage snapshots input, cases and settings without modifying source', async t => {
  const dir = await root(t), source = path.join(dir,'source.jsonl');
  await writeFile(source, 'original-cache\n');
  const result = await prepareBatch({ source, kind:'cache', cases:[example], destination:path.join(dir,'jobs') });
  const job = JSON.parse(await readFile(path.join(result.directory,'job.json')));
  assert.equal(job.files[0].sha256, hash('original-cache\n'));
  assert.deepEqual(job.cases, [example]);
  assert.equal(await readFile(source,'utf8'), 'original-cache\n');
  await validateBatchJob(result.directory);
  await writeFile(path.join(result.directory,job.input),'damaged');
  await assert.rejects(validateBatchJob(result.directory), /checksum/);
});
test('pulldown controller job is supported but unadapted exercises are rejected', async t => {
  const dir = await root(t), source = path.join(dir,'source.jsonl');
  await writeFile(source, 'private-pose-placeholder');
  const result = await prepareBatch({source,kind:'cache',cases:[{...example,exercise:'latPulldown'}],destination:path.join(dir,'jobs')});
  assert.equal((await validateBatchJob(result.directory)).job.cases[0].exercise, 'latPulldown');
  for (const exercise of ['crunch','benchPress']) {
    await assert.rejects(prepareBatch({source,kind:'cache',cases:[{...example,exercise}],destination:path.join(dir,'jobs')}));
  }
});
test('observations mode is explicit, empty of exercise cases, and rejects invalid combinations', async t => {
  const dir = await root(t), source = path.join(dir, 'source.jsonl');
  await writeFile(source, 'cache');
  const result = await prepareBatch({source, kind:'cache', mode:'observations', cases:[], destination:path.join(dir,'jobs')});
  assert.equal((await validateBatchJob(result.directory)).job.mode, 'observations');
  for (const input of [
    {mode:'observations',kind:'cache',cases:[example]},
    {mode:'observations',kind:'diagnostic',cases:[]},
    {mode:'controller',kind:'cache',cases:[]},
    {mode:'future',kind:'cache',cases:[example]}
  ]) await assert.rejects(prepareBatch({source, ...input, destination:path.join(dir,'jobs')}));
});
test('unsafe segment/path/version and duplicate cases cannot be staged', async t => {
  const dir = await root(t), source = path.join(dir,'input'); await writeFile(source,'cache');
  for (const cases of [[{...example,id:'../escape'}], [example,example], [{...example,endSeconds:0}], [{...example,rebindAtSeconds:[8,2]}]]) {
    await assert.rejects(prepareBatch({source,kind:'cache',cases,destination:path.join(dir,'jobs')}));
  }
  const result = await prepareBatch({source,kind:'cache',cases:[example],destination:path.join(dir,'jobs')});
  const file = path.join(result.directory,'job.json'), job = JSON.parse(await readFile(file));
  for (const bad of [{...job,input:'../input'}, {...job,schema:'future'}]) {
    await writeFile(file,JSON.stringify(bad)); await assert.rejects(validateBatchJob(result.directory));
  }
});
async function completed(t) {
  const dir = await root(t), id = randomUUID().toUpperCase(), digest = hash('job');
  const settings = Buffer.from('{"schema":"fox.pose_session_settings.v1"}');
  const result = Buffer.from(JSON.stringify({schema:'fox.vision_batch_result.v1',jobID:id,jobSHA256:digest,
    settings:JSON.parse(settings), settingsSHA256:hash(settings), cases:[], inferencePerformed:false,
    evidenceBoundary:'offline-observations-through-real-controller-not-live-camera-or-new-human-acceptance'}));
  const status = {schema:'fox.vision_batch_status.v1',jobID:id,jobSHA256:digest,phase:'completed',
    files:[['result.json',result],['settings.json',settings]].map(([name,bytes])=>({path:name,bytes:bytes.length,sha256:hash(bytes)}))};
  await writeFile(path.join(dir,'result.json'),result); await writeFile(path.join(dir,'settings.json'),settings);
  await writeFile(path.join(dir,'status.json'),JSON.stringify(status));
  return {dir,digest,status};
}
test('completed receipt requires expected job and all content digests', async t => {
  const {dir,digest} = await completed(t);
  assert.equal((await verifyBatchResult(dir,digest)).status.phase,'completed');
  await assert.rejects(verifyBatchResult(dir,hash('wrong-job')), /job/i);
  await writeFile(path.join(dir,'result.json'),'{}');
  await assert.rejects(verifyBatchResult(dir,digest), /checksum/);
});
test('partial cancelled failed unsafe and missing-result outputs are not success', async t => {
  const {dir,digest,status} = await completed(t);
  for (const phase of ['replaying','extracting','cancelled','failed']) {
    await writeFile(path.join(dir,'status.json'),JSON.stringify({...status,phase}));
    await assert.rejects(verifyBatchResult(dir,digest), /completed/);
  }
  for (const files of [[],[{path:'../result.json',bytes:1,sha256:hash('x')}], [status.files[0],status.files[0]]]) {
    await writeFile(path.join(dir,'status.json'),JSON.stringify({...status,files}));
    await assert.rejects(verifyBatchResult(dir,digest));
  }
});
test('verified import is idempotent and refuses to overwrite changed prior results', async t => {
  const {dir,digest} = await completed(t), parent = await root(t), destination = path.join(parent,'received');
  await importBatchResult(dir,destination,digest);
  await importBatchResult(dir,destination,digest);
  const original = await readFile(path.join(destination,'result.json'));
  await writeFile(path.join(dir,'result.json'),'corrupt');
  await assert.rejects(importBatchResult(dir,destination,digest));
  assert.deepEqual(await readFile(path.join(destination,'result.json')),original);
});

const squat = {id:'squat',countOnlyAction:'squat',arm:'right',startSeconds:0,endSeconds:4,rebindAtSeconds:[]};
test('count-only staging keeps extra original clock hashes and does not admit other modes or caller thresholds', async t => {
  const dir=await root(t),source=path.join(dir,'raw.jsonl'),clock=path.join(dir,'times.jsonl');
  await writeFile(source,'public synthetic input');await writeFile(clock,'original integer ticks');
  const staged=await prepareBatch({source,kind:'cache',mode:'countOnly',cases:[squat],assets:[clock],destination:path.join(dir,'jobs')});
  const {job}=await validateBatchJob(staged.directory);
  assert.equal(job.mode,'countOnly');assert.deepEqual(job.cases,[squat]);
  assert.equal(job.files.length,2);assert.equal(job.files[1].sha256,hash('original integer ticks'));
  assert.equal(await readFile(path.join(staged.directory,'times.jsonl'),'utf8'),'original integer ticks');
  for(const bad of [{kind:'diagnostic'},{kind:'video'},{settings:{}},{cases:[{...squat,exercise:'curl'}]},
    {cases:[{...squat,countOnlyAction:'future'}]},{cases:[{...squat,rebindAtSeconds:[2.5]}]}])
    await assert.rejects(prepareBatch({source,kind:'cache',mode:'countOnly',cases:[squat],destination:path.join(dir,'bad'),...bad}));
});
test('only count-only device launch explicitly grants the diagnostic route', () => {
  const id=randomUUID().toUpperCase();
  assert.deepEqual(batchLaunchEnvironment({id,mode:'countOnly'}),{FOX_POSE_BATCH_JOB:id,FOX_COUNT_ONLY_DIAGNOSTIC:'1'});
  assert.deepEqual(batchLaunchEnvironment({id,mode:'controller'}),{FOX_POSE_BATCH_JOB:id});
  assert.deepEqual(batchLaunchEnvironment({id,mode:'observations'}),{FOX_POSE_BATCH_JOB:id});
  assert.deepEqual(batchCounts({mode:'countOnly',cases:[],countOnlyCases:[{specification:squat,automaticCount:1}]}),[{id:'squat',count:1}]);
});
async function countOnlyCompleted(t) {
  const dir=await root(t),id=randomUUID().toUpperCase(),runID=randomUUID().toUpperCase(),recordID=randomUUID().toUpperCase();
  const jobFolder=path.join(dir,'job');await mkdir(jobFolder);
  const input=Buffer.from('public synthetic input');await writeFile(path.join(jobFolder,'raw.jsonl'),input);
  const job={schema:'fox.vision_batch_job.v1',id,kind:'cache',mode:'countOnly',input:'raw.jsonl',
    files:[{path:'raw.jsonl',bytes:input.length,sha256:hash(input)}],cases:[squat]};
  const jobBytes=Buffer.from(JSON.stringify(job));await writeFile(path.join(jobFolder,'job.json'),jobBytes);
  const jobSHA256=hash(jobBytes), settings=Buffer.from('{}');
  const record={id:recordID,countingMethod:'unconfirmed',assistedEvidence:{schema:'fox.workout_count_only.v1',action:'squat',side:'right',source:'fixture',
    runs:[{id:runID,coordinateConvention:'vision-normalized-bottom-left-pixel-up-v1',pixelMirror:'unknown',appleRevision:1,
      evidence:{schema:'fox.count_only_evidence.v1',algorithm:'squat-selected-count-only-v1',action:'squat',side:'right',source:'cachedPose',phaseStatus:'not_provided',
        inputOriginSeconds:0,formalStartSeconds:2,lastInputSeconds:3,events:[{completedAtSeconds:2.9,segmentID:0}],segments:[{id:0,startedAtSeconds:2}]}}]}};
  const original=Buffer.from('{"schemaVersion":2,"sessions":[]}');
  const archive=Buffer.from(JSON.stringify({schemaVersion:3,sessions:[{records:[record]}]}));
  const assets=[['squat.training.json',archive],[`squat.training.json.pre-assisted-v2-${hash(original)}-original`,original]];
  const descriptor=([path,bytes])=>({path,bytes:bytes.length,sha256:hash(bytes)});
  const result={schema:'fox.vision_batch_result.v1',jobID:id,jobSHA256,mode:'countOnly',inputAssets:job.files,inferencePerformed:false,
    settings:{},settingsSHA256:hash(settings),settingsScope:'legacy_settings_not_used_by_count_only',controllerVersion:'workout-coordinator-count-only-v1',
    cases:[],algorithms:{squat:'squat-selected-count-only-v1'},countOnlyCases:[{specification:squat,sourceOriginSeconds:0,formalStartSeconds:2,admittedFramePTSSeconds:[0,1,2,2.9,3],
      automaticCount:1,events:[{completedAtSourcePTSSeconds:2.9,observationRunID:runID,segmentID:0}],record,archiveAssets:assets.map(descriptor),
      manualConfirmation:'unknown',phaseStatus:'not_provided',sourceTimebase:'original_source_pts_seconds_double_not_complete_cmtime',
      eventTimeMeaning:'count_confirmation_not_anatomical_return_endpoint'}]};
  const resultBytes=Buffer.from(JSON.stringify(result));
  const files=[['result.json',resultBytes],['settings.json',settings],...assets];
  for(const [file,bytes] of files)await writeFile(path.join(dir,file),bytes);
  const status={schema:'fox.vision_batch_status.v1',jobID:id,jobSHA256,phase:'completed',files:files.map(descriptor)};
  await writeFile(path.join(dir,'status.json'),JSON.stringify(status));
  return {dir,jobFolder,digest:jobSHA256,status,result,record,assets};
}
test('count-only verify/import retains and reads actual archive and byte-preservation backup', async t => {
  const f=await countOnlyCompleted(t), parent=await root(t),destination=path.join(parent,'received');
  assert.equal((await verifyBatchResult(f.dir,f.digest)).result.countOnlyCases[0].automaticCount,1);
  await importBatchResult(f.dir,destination,f.digest);await importBatchResult(f.dir,destination,f.digest);
  for(const [file,bytes]of f.assets)assert.deepEqual(await readFile(path.join(destination,file)),bytes);
  await writeFile(path.join(f.dir,f.assets[1][0]),'changed-backup');
  await assert.rejects(verifyBatchResult(f.dir,f.digest),/checksum/i);
});
test('count-only assets cannot be omitted, detached from actual archive or promoted into manual/phase truth', async t => {
  for(const kind of ['missing','detached','manual','phase']) {
    const f=await countOnlyCompleted(t);
    if(kind==='missing')f.result.countOnlyCases[0].archiveAssets=[];
    if(kind==='detached')f.result.countOnlyCases[0].record.id=randomUUID().toUpperCase();
    if(kind==='manual')f.result.countOnlyCases[0].record.reps=1;
    if(kind==='phase')f.result.countOnlyCases[0].phaseStatus='measured';
    const bytes=Buffer.from(JSON.stringify(f.result));await writeFile(path.join(f.dir,'result.json'),bytes);
    f.status.files[0]={path:'result.json',bytes:bytes.length,sha256:hash(bytes)};
    await writeFile(path.join(f.dir,'status.json'),JSON.stringify(f.status));
    await assert.rejects(verifyBatchResult(f.dir,f.digest));
  }
});

test('count-only actual archives survive the existing immutable evidence index without invented return intervals', async t => {
  const f=await countOnlyCompleted(t),archiveRoot=path.join(f.dir,'runs'),db=path.join(f.dir,'index.sqlite');
  const run=await archiveBatch({resultFolder:f.dir,jobFolder:f.jobFolder,archiveRoot});
  const {manifest}=await verifyRun(run.directory);
  assert.equal(manifest.evidenceKind,'countOnly_cache');assert.equal(manifest.acceptance,'not_assessed');
  assert.equal(manifest.cases[0].automaticCount,1);assert.equal(manifest.cases[0].returnIntervals,null);
  assert.equal(manifest.cases[0].referenceCount,null);assert.equal(manifest.cases[0].countError,null);
  for(const [file,bytes]of f.assets)assert.deepEqual(await readFile(path.join(run.directory,file)),bytes);
  await indexRun(db,run.directory);const rows=await queryRuns(db,{exercise:'squat'});
  assert.equal(rows.length,1);assert.equal(rows[0].automatic_count,1);assert.equal(rows[0].return_intervals,null);
  await writeFile(path.join(run.directory,f.assets[1][0]),'tampered-original-backup');
  await assert.rejects(verifyRun(run.directory),/checksum/i);
});

for(const kind of ['backupOnly','offAdmittedClock']) test(`count-only rejects ${kind} even when record/result/status hashes are updated`, async t => {
    const f=await countOnlyCompleted(t);
    if(kind==='backupOnly') {
      f.result.countOnlyCases[0].archiveAssets=f.result.countOnlyCases[0].archiveAssets.filter(a=>!a.path.includes('.pre-assisted-'));
      f.status.files=f.status.files.filter(a=>!a.path.includes('.pre-assisted-'));
    } else {f.result.countOnlyCases[0].admittedFramePTSSeconds=[0,1,2,3];}
    const bytes=Buffer.from(JSON.stringify(f.result));await writeFile(path.join(f.dir,'result.json'),bytes);
    f.status.files[0]={path:'result.json',bytes:bytes.length,sha256:hash(bytes)};
    await writeFile(path.join(f.dir,'status.json'),JSON.stringify(f.status));
    await assert.rejects(verifyBatchResult(f.dir,f.digest),kind);
});
