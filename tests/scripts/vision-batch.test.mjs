import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { prepareBatch, validateBatchJob, verifyBatchResult, importBatchResult } from '../../scripts/vision-batch.mjs';

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
