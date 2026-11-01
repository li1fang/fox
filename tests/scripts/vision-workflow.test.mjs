import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { prepareBatch, validateBatchJob } from '../../scripts/vision-batch.mjs';
import { normalizeWorkflowResult,evaluateWorkflow,workflowFrames } from '../../scripts/vision-workflow.mjs';
import { archiveBatch,verifyRun,indexRun,queryRuns } from '../../scripts/vision-evidence.mjs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

async function fixture(t) {
  const dir=await mkdtemp(path.join(tmpdir(),'fox-workflow-'));
  t.after(()=>rm(dir,{recursive:true,force:true}));
  const source=path.join(dir,'raw.jsonl');await writeFile(source,'public raw placeholder\n');
  const clock=path.join(dir,'times.jsonl');await writeFile(clock,'original clock placeholder\n');
  return {source,clock,destination:dir,kind:'cache',cases:[{id:'one',personID:'public-person',arm:'right',startSeconds:1,endSeconds:12,rebindAtSeconds:[]}]};
}
test('workflow binds action to the real frozen strategy and preserves a fixed formal boundary',async t=>{
  for(const [action,mode,algorithm] of [['squat','countOnly','squat-selected-count-only-v1'],['curl','controller','curl_2d_v4']]) {
    const input=await fixture(t),prepared=await prepareBatch({...input,action});
    const {job}=await validateBatchJob(prepared.directory);
    assert.equal(job.mode,mode);
    assert.equal(job.workflow.schema,'fox.vision_workflow_binding.v1');
    assert.equal(job.workflow.action,action);
    assert.equal(job.workflow.algorithm,algorithm);
    assert.equal(job.workflow.formalOffsetSeconds,2);
    assert.equal(job.cases[0].formalStartSeconds,3);
    assert.equal(job.cases[0].strategyID,job.workflow.strategyID);
    assert.equal(job.cases[0][action==='squat'?'countOnlyAction':'exercise'],action);
    assert.equal(job.workflow.acceptance,'not_assessed');
    assert.equal(job.sourceClock.path,'times.jsonl');
    assert.equal(job.sourceClock.role,'observer_input');
    assert.ok(job.files.some(f=>f.path===job.sourceClock.path));
  }
});

test('observation CMTime asset is complete input clock, not an arbitrary superset hiding missing rows',async t=>{
  const input=await fixture(t),header={schema:'fox.pose_workflow_input.v1',inputClass:'public_synthetic',source:'synthetic_fixture',
    sourceSHA256:'a'.repeat(64),visionRevision:'1',timebase:'source_pts_seconds',coordinateConvention:'vision-normalized-bottom-left-pixel-up-v1',pixelMirror:'unknown'};
  await writeFile(input.source,[header,...[1,1.1].map(seconds=>({seconds,width:640,height:360,people:[]}))].map(JSON.stringify).join('\n')+'\n');
  await writeFile(input.clock,[1000,1050,1100].map(value=>JSON.stringify({value:String(value),timescale:1000,epoch:'0'})).join('\n')+'\n');
  const p=await prepareBatch({...input,action:'squat'}),{job}=await validateBatchJob(p.directory);
  await assert.rejects(workflowFrames(p.directory,job),/clock/i);
});

test('existing evidence capture indexes a real portable receipt separately from App acceptance and rejects tampering',async t=>{
  const input=await fixture(t);
  const header={schema:'fox.pose_workflow_input.v1',inputClass:'public_synthetic',source:'synthetic_fixture',
    sourceSHA256:'a'.repeat(64),visionRevision:'1',timebase:'source_pts_seconds',
    coordinateConvention:'vision-normalized-bottom-left-pixel-up-v1',pixelMirror:'unknown'};
  const frames=Array.from({length:40},(_,i)=>({seconds:i/10,width:640,height:360,people:[]}));
  await writeFile(input.source,[header,...frames].map(JSON.stringify).join('\n')+'\n');
  await writeFile(input.clock,frames.map((_,i)=>JSON.stringify({value:String(i),timescale:10,epoch:'0'})).join('\n')+'\n');
  input.cases[0].startSeconds=0;input.cases[0].endSeconds=4;
  const prepared=await prepareBatch({...input,action:'squat'}),{job,jobSHA256}=await validateBatchJob(prepared.directory);
  const result={schema:'fox.vision_workflow_result.v1',jobID:job.id,jobSHA256,workflow:job.workflow,inputProvenance:header,
    inferencePerformed:false,execution:'portable_core_replay_not_actual_app',acceptance:'not_assessed',cases:[{specification:job.cases[0],replay:{
      binding:job.workflow,side:'right',sourceOriginSeconds:0,formalStartSeconds:2,events:[],resetCounts:{},
      trace:frames.map(f=>({sourcePTSSeconds:f.seconds,admitted:true,formal:f.seconds>=2,reason:'no_central_leg_chain',automaticCount:0,reset:false}))}}]};
  const hash=b=>createHash('sha256').update(b).digest('hex'),bytes=Buffer.from(JSON.stringify(result));
  const resultFolder=path.join(input.destination,'cpu');await import('node:fs/promises').then(fs=>fs.mkdir(resultFolder));
  await writeFile(path.join(resultFolder,'workflow-result.json'),bytes);
  await writeFile(path.join(resultFolder,'workflow-status.json'),JSON.stringify({schema:'fox.vision_workflow_status.v1',jobID:job.id,jobSHA256,
    phase:'completed',execution:'portable_core_replay_not_actual_app',producer:{path:'/frozen/test-producer',sha256:'b'.repeat(64)},
    result:{path:'workflow-result.json',sha256:hash(bytes),bytes:bytes.length}}));
  const archived=await archiveBatch({resultFolder,jobFolder:prepared.directory,archiveRoot:path.join(input.destination,'evidence')});
  const {manifest}=await verifyRun(archived.directory);
  assert.equal(manifest.evidenceKind,'portable_core_cache');assert.equal(manifest.acceptance,'not_assessed');
  assert.equal(manifest.cases[0].automaticCount,0);assert.equal(manifest.cases[0].referenceCount,null);
  const db=path.join(input.destination,'index.sqlite');await indexRun(db,archived.directory);
  assert.equal((await queryRuns(db,{exercise:'squat'}))[0].evidence_kind,'portable_core_cache');
  const clock=frames.map(f=>Math.round(f.seconds*1000));
  const reference={schema:'fox.coverage_period_reference.v1',role:'development',independent_untuned_person_ids:[],clips:[{
    id:job.cases[0].id,person_id:job.cases[0].personID,source_sha256:header.sourceSHA256,side:'right',body_view:'side',action:'squat',
    time_base:[1,1000],frame_pts:clock,observer_input_pts:clock,input_sampling_policy:'all_source_frames',counter_admission_policy:'camera_greedy_12hz_v1',
    cycles:[{id:'formal-cycle',S:[2000,2100],B:[2500,2600],R:[3300,3400],ownership:[2000,3900]}],intervals:[]}]};
  const referenceFile=path.join(input.destination,'reference.json');await writeFile(referenceFile,JSON.stringify(reference));
  const output=path.join(input.destination,'evaluation.json'),resultFile=path.join(resultFolder,'workflow-result.json');
  const evaluated=await evaluateWorkflow({jobFolder:prepared.directory,job,jobSHA256,resultFile,referenceFile,output});
  assert.equal(evaluated.evaluation.count.reference_cycles,1);assert.equal(evaluated.evaluation.count.FN,1);
  assert.equal(evaluated.evaluation.count.acceptance,'development_only');
  for(const field of ['action','body_view']) {
    const missing=structuredClone(reference);delete missing.clips[0][field];
    const refFile=path.join(input.destination,'missing-'+field+'.json');await writeFile(refFile,JSON.stringify(missing));
    await assert.rejects(evaluateWorkflow({jobFolder:prepared.directory,job,jobSHA256,resultFile,referenceFile:refFile,
      output:path.join(input.destination,'missing-'+field+'-eval.json')}),/binding/i);
  }
  const before=await readFile(output);await assert.rejects(evaluateWorkflow({jobFolder:prepared.directory,job,jobSHA256,resultFile,referenceFile,output}));
  assert.deepEqual(await readFile(output),before);
  const secondHeader={...header,sourceSHA256:'c'.repeat(64)};
  const secondSource=path.join(input.destination,'second-source.jsonl');
  await writeFile(secondSource,[secondHeader,...frames].map(JSON.stringify).join('\n')+'\n');
  const second=await prepareBatch({...input,source:secondSource,action:'squat',cases:[{...input.cases[0],id:'second',personID:'second-person'}]});
  const cohortRef=structuredClone(reference),other=structuredClone(reference.clips[0]);
  other.id='second';other.person_id='second-person';other.source_sha256=secondHeader.sourceSHA256;cohortRef.clips.push(other);
  const cohortReference=path.join(input.destination,'cohort-reference.json');await writeFile(cohortReference,JSON.stringify(cohortRef));
  const cohortIndex=path.join(input.destination,'cohort-inputs.json'),cohortOutput=path.join(input.destination,'cohort-evaluation.json');
  await writeFile(cohortIndex,JSON.stringify({schema:'fox.vision_workflow_evaluation_inputs.v1',runs:[
    {jobFolder:prepared.directory,resultFile},{jobFolder:second.directory,resultFile:path.join(input.destination,'missing-result.json')}
  ]}));
  const child=spawnSync(process.execPath,[fileURLToPath(new URL('../../scripts/vision-batch.mjs',import.meta.url)),'evaluate',cohortIndex,
    '--cohort','--reference',cohortReference,'--output',cohortOutput],{encoding:'utf8',timeout:10000});
  assert.equal(child.status,0,child.stderr);
  const cohort=JSON.parse(await readFile(cohortOutput));
  assert.equal(cohort.evaluation.count.reference_cycles,2);assert.equal(cohort.evaluation.count.FN,2);
  assert.equal(cohort.cases.find(c=>c.id==='second').status,'result_missing');
  assert.equal(cohort.cases.find(c=>c.id==='second').observed,null);
  for(const [tag,events,expected] of [
    ['outside',[{id:'1',startedAtSourcePTSSeconds:1,peakGateAtSourcePTSSeconds:1.3,completedAtSourcePTSSeconds:1.7}],{FP:1,unknown:0}],
    ['duplicates',[{id:'1',startedAtSourcePTSSeconds:2.1,peakGateAtSourcePTSSeconds:2.5,completedAtSourcePTSSeconds:3.4},
      {id:'2',startedAtSourcePTSSeconds:2.1,peakGateAtSourcePTSSeconds:2.5,completedAtSourcePTSSeconds:3.5}],{FP:0,unknown:2}]
  ]) {
    const altered=structuredClone(result);altered.cases[0].replay.events=events;
    altered.cases[0].replay.trace.forEach(t=>{t.reason='observed';t.automaticCount=events.filter(e=>e.completedAtSourcePTSSeconds<=t.sourcePTSSeconds+1e-9).length;});
    const file=path.join(input.destination,tag+'.json');await writeFile(file,JSON.stringify(altered));
    const e=await evaluateWorkflow({jobFolder:prepared.directory,job,jobSHA256,resultFile:file,referenceFile,output:path.join(input.destination,tag+'-eval.json')});
    for(const [key,value] of Object.entries(expected))assert.equal(e.evaluation.count[key],value);
    assert.equal(e.evaluation.count.FN,1);assert.equal(e.evaluation.count.reference_cycles,1);
  }
  await writeFile(path.join(archived.directory,'workflow-result.json'),'{}');
  await assert.rejects(verifyRun(archived.directory),/checksum/i);
});

test('portable facts require complete actual cadence telemetry and keep reset even on an observed frame',async t=>{
  const input=await fixture(t),prepared=await prepareBatch({...input,action:'squat'});
  const {job,jobSHA256}=await validateBatchJob(prepared.directory);
  const frames=[1,1.04,1.1,3,4].map(seconds=>({seconds}));
  const trace=frames.map((f,i)=>({sourcePTSSeconds:f.seconds,admitted:i!==1,formal:f.seconds>=3,
    reason:i===1?'cadence_not_admitted':'observed',automaticCount:0,reset:i===3,resetReason:i===3?'geometry_changed':null}));
  const value={schema:'fox.vision_workflow_result.v1',jobID:job.id,jobSHA256,workflow:job.workflow,
    inferencePerformed:false,execution:'portable_core_replay_not_actual_app',acceptance:'not_assessed',inputProvenance:{sourceSHA256:'a'.repeat(64)},
    cases:[{specification:job.cases[0],replay:{binding:job.workflow,sourceOriginSeconds:1,formalStartSeconds:3,
      side:'right',events:[],trace,resetCounts:{}}}]};
  const facts=normalizeWorkflowResult(job,value,{jobSHA256,frames});
  assert.equal(facts.cases[0].trace[3].resetReason,'geometry_changed');
  for(const change of [()=>value.cases[0].replay.trace.splice(1,1),()=>value.cases[0].replay.trace[1].admitted=true]) {
    const saved=structuredClone(value);change();assert.throws(()=>normalizeWorkflowResult(job,value,{jobSHA256,frames}),/trace/i);
    Object.assign(value,saved);
  }
});
test('workflow rejects wrong bindings and failed front-curl substitution rather than silently ignoring them',async t=>{
  const input=await fixture(t);
  await assert.rejects(prepareBatch({...input,cases:input.cases.map(c=>({...c,exercise:'curl'})),action:'frontalCurl'}),/action|strategy/i);
  await assert.rejects(prepareBatch({...input,action:'curl',mode:'countOnly'}),/binding|mode/i);
  const prepared=await prepareBatch({...input,action:'squat'}),file=path.join(prepared.directory,'job.json');
  const original=JSON.parse(await readFile(file));
  for(const patch of [{algorithm:'central-continuous-curl-v1'},{formalOffsetSeconds:0},{strategyID:'curl-side'}]) {
    await writeFile(file,JSON.stringify({...original,workflow:{...original.workflow,...patch}}));
    await assert.rejects(validateBatchJob(prepared.directory),/binding|strategy/i);
  }
});
