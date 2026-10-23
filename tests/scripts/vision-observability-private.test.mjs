import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { validateBatchJob, verifyBatchResult } from '../../scripts/vision-batch.mjs';
import { analyzeObservability } from '../../scripts/vision-observability.mjs';
import {privateInput, privateBatchFolders} from '../../scripts/private-inputs.mjs';

for(const [name,id,count] of [
  ['pulldown','CFCCA7B7-7E58-494C-B041-38A6374870E8',615],
  ['crunch','B1B2CB13-6577-4F4A-9125-7625FBF4CE22',283],
  ['bench','40DB3F1B-E5B5-4AD6-969D-09B390387D8E',750]
]) {
  test(`private iPad ${name}: verified inference and reproducible observation analysis, not accuracy acceptance`,
    async()=>{
      const {jobFolder, resultFolder: folder}=await privateBatchFolders(name);
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
      const labelBytes=await readFile(await privateInput(`${name}.labels`)),labels=JSON.parse(labelBytes);
      const report=JSON.parse(await readFile(await privateInput(`${name}.report`)));
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
