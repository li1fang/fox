import test from 'node:test';
import assert from 'node:assert/strict';
import {summarizeRuns} from '../../scripts/verification-timing.mjs';

const run=(id,start,end,status='software_suite_passed')=>({id,receipt:{schema:'fox.trial_suite.v1',status,
  startedAt:new Date(start*1000).toISOString(),...(end===null?{}:{finishedAt:new Date(end*1000).toISOString()}),steps:[]},logs:[]});
test('timing separates accumulated, occupied and enclosing wall time including failed runs',()=>{
  const report=summarizeRuns([run('a',0,10),run('b',5,15,'failed'),run('c',20,23,'cancelled')]);
  assert.equal(report.accumulatedSeconds,23); assert.equal(report.occupiedSeconds,18); assert.equal(report.windowSeconds,23);
  assert.deepEqual(report.statusCounts,{software_suite_passed:1,failed:1,cancelled:1});
  assert.equal(report.acceptanceClaim,false);
});
test('unfinished receipts are not counted as zero duration or success',()=>{
  const report=summarizeRuns([run('running',0,null,'running')]);
  assert.equal(report.incompleteRuns,1); assert.equal(report.accumulatedSeconds,null); assert.equal(report.runs[0].durationSeconds,null);
});
test('invalid and reversed timestamps or duplicate receipt identity are rejected',()=>{
  assert.throws(()=>summarizeRuns([run('a',10,0)]),/time/i);
  assert.throws(()=>summarizeRuns([run('a',0,1),run('a',0,1)]),/duplicate/i);
  const bad=run('bad',0,1);bad.receipt.startedAt='unknown';assert.throws(()=>summarizeRuns([bad]),/time/i);
});
test('slow passed methods and animation warnings are diagnostic observations not root causes',()=>{
  const sample=run('a',0,1000);
  sample.logs=[{step:'ipad-ui',integrity:'verified',text:"Test Case '-[FoxUITests.Example testOne]' passed (980.061 seconds).\nApp animations complete notification not received"}];
  const result=summarizeRuns([sample]);
  assert.equal(result.methods[0].seconds,980.061); assert.equal(result.animationWarnings,1);
  assert.equal(result.methods[0].integrity,'verified');
});
