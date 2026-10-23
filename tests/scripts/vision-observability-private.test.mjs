import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { validateBatchJob, verifyBatchResult } from '../../scripts/vision-batch.mjs';
import { analyzeObservability } from '../../scripts/vision-observability.mjs';

const root=fileURLToPath(new URL('../..',import.meta.url));
const corpus=path.join(root,'.data/vision-observability/20261023');
for(const [name,id,count] of [
  ['pulldown','CFCCA7B7-7E58-494C-B041-38A6374870E8',615],
  ['crunch','B1B2CB13-6577-4F4A-9125-7625FBF4CE22',283],
  ['bench','40DB3F1B-E5B5-4AD6-969D-09B390387D8E',750]
]) {
  const jobFolder=path.join(root,'.data/vision-replay/jobs',id),folder=path.join(root,'.data/vision-replay/results',id);
  test(`private iPad ${name}: verified inference and reproducible observation analysis, not accuracy acceptance`,
    {skip:!existsSync(path.join(folder,'status.json')) ? 'Private iPad corpus unavailable' : false}, async()=>{
      const {jobSHA256}=await validateBatchJob(jobFolder);
      const {result}=await verifyBatchResult(folder,jobSHA256);
      assert.equal(result.device,'iPad16,5');
      assert.equal(result.appBuild,'21');
      assert.equal(result.mode,'observations');
      assert.equal(result.controllerVersion,'not-run');
      assert.equal(result.inferencePerformed,true);
      assert.equal(result.observationFrameCount,count);
      assert.deepEqual(result.cases,[]);
      const cache=await readFile(path.join(folder,'vision.jsonl')),rows=cache.toString().trim().split('\n').map(JSON.parse);
      const labelBytes=await readFile(path.join(corpus,`${name}-labels.json`)),labels=JSON.parse(labelBytes);
      const report=JSON.parse(await readFile(path.join(corpus,`${name}-report-v2.json`)));
      const computed=analyzeObservability(rows.shift(),rows,labels);
      const {cacheSHA256,labelsSHA256,...saved}=report;
      assert.equal(cacheSHA256,createHash('sha256').update(cache).digest('hex'));
      assert.equal(labelsSHA256,createHash('sha256').update(labelBytes).digest('hex'));
      assert.deepEqual(computed,saved);
      assert.equal(rows.length,count);
      assert.equal(labels.peaks.length,6);
      assert.ok(labels.peaks.slice(0,5).every(p=>p.returnEndpoint!==null));
      assert.equal(labels.peaks[5].returnEndpoint,null);
    });
}
