import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { spawnSync } from 'node:child_process';

const root=fileURLToPath(new URL('..',import.meta.url));
export const registryFile=path.join(root,'apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore/Resources/vision-actions.json');
export async function workflowBinding(action) {
  const registry=JSON.parse(await readFile(registryFile,'utf8'));
  const value=registry.actions.find(a=>a.action===action);
  if(registry.schema!=='fox.vision_actions.v1'||registry.version!==1||!value) throw Error('Unknown workflow action/strategy');
  for(const file of value.implementation) {
    const bytes=await readFile(path.join(root,'apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore',file.path));
    if(createHash('sha256').update(bytes).digest('hex')!==file.sha256) throw Error(`Strategy implementation changed: ${file.path}`);
  }
  return {schema:'fox.vision_workflow_binding.v1',registryVersion:registry.version,...value,
    formalOffsetSeconds:registry.formalOffsetSeconds,acceptance:'not_assessed'};
}
export async function validateWorkflow(job,{requireClock=true}={}) {
  if(job.workflow==null) return;
  const binding=await workflowBinding(job.workflow.action);
  if(!isDeepStrictEqual(binding,job.workflow)||job.mode!==binding.consumerMode||job.kind!=='cache'||job.settings!=null)
    throw Error('Workflow strategy binding mismatch');
  if(requireClock&&(job.sourceClock?.timebase!=='original_cmtime_jsonl'||job.sourceClock.role!=='observer_input'||!job.files?.some(f=>f.path===job.sourceClock.path)))throw Error('Workflow observation input clock asset missing');
  for(const c of job.cases) {
    if(c.strategyID!==binding.strategyID||c.formalStartSeconds!==c.startSeconds+binding.formalOffsetSeconds
      ||c.endSeconds<=c.formalStartSeconds||c.rebindAtSeconds.length!==0
      ||c.bodyView!==binding.bodyView||c.personID!=null&&(typeof c.personID!=='string'||c.personID.length<1||c.personID.length>200)
      ||(binding.consumerMode==='controller'?c.exercise:c.countOnlyAction)!==binding.action)
      throw Error('Workflow case strategy binding mismatch');
  }
}

export function greedyPTS(values) {
  let previous;
  return values.filter(t=>{if(previous==null||t-previous>=1/12){previous=t;return true;}return false;});
}
export async function workflowFrames(folder,job) {
  const lines=(await readFile(path.join(folder,job.input),'utf8')).trim().split('\n');
  const header=JSON.parse(lines.shift());
  if(!['fox.count_only_pose_input.v1','fox.pose_workflow_input.v1'].includes(header.schema)
    ||header.visionRevision!=='1'||header.timebase!=='source_pts_seconds'
    ||header.coordinateConvention!=='vision-normalized-bottom-left-pixel-up-v1'
    ||!['unknown','known_mirrored','known_unmirrored'].includes(header.pixelMirror)
    ||!((header.inputClass==='public'&&header.source==='apple_vision_2d')||(header.inputClass==='public_synthetic'&&header.source==='synthetic_fixture'))
    ||!/^[a-f0-9]{64}$/.test(header.sourceSHA256??''))throw Error('Invalid public workflow cache provenance');
  const frames=lines.map(JSON.parse);
  if(frames.length<2||frames.length>20000||frames.some((f,i)=>!Number.isFinite(f.seconds)||f.seconds<0
    ||i>0&&f.seconds<=frames[i-1].seconds||!Array.isArray(f.people)))throw Error('Invalid workflow source clock');
  const clockRows=(await readFile(path.join(folder,job.sourceClock.path),'utf8')).trim().split('\n').map(JSON.parse);
  let epoch;
  const clock=clockRows.map((r,i)=>{
    if(!/^[0-9]+$/.test(r.value??'')||!Number.isSafeInteger(r.timescale)||r.timescale<=0||r.timescale>2147483647||!/^[-]?[0-9]+$/.test(r.epoch??''))throw Error('Invalid original CMTime clock');
    if(i===0)epoch=r.epoch;else if(epoch!==r.epoch)throw Error('Source clock epoch changed without a source boundary');
    const value=Number(r.value);if(!Number.isSafeInteger(value))throw Error('Original source tick exceeds exact JSON integer range');return value/r.timescale;
  });
  if(clock.length!==frames.length||clock.some((t,i)=>!Number.isFinite(t)||i>0&&t<=clock[i-1])
    ||frames.some((f,i)=>Math.abs(clock[i]-f.seconds)>1e-9))throw Error('Raw cache is detached from complete observation input clock');
  return {header,frames,clock};
}

// Normalize only facts actually emitted by a producer. The App count-only path
// needs a separately identified Core witness result; completion never becomes S/B/R.
export function normalizeWorkflowResult(job,result,{jobSHA256,frames,witness}={}) {
  if(!job.workflow||!isDeepStrictEqual(result.workflow,job.workflow)||result.jobID!==job.id||result.jobSHA256!==jobSHA256
    ||result.inferencePerformed!==false)throw Error('Workflow result binding/identity mismatch');
  const portable=result.schema==='fox.vision_workflow_result.v1';
  if(!portable&&result.schema!=='fox.vision_batch_result.v1')throw Error('Unsupported workflow result schema');
  if(portable&&(result.execution!=='portable_core_replay_not_actual_app'||result.acceptance!=='not_assessed'))throw Error('Invalid portable execution boundary');
  const rawCases=portable?result.cases:job.mode==='countOnly'?result.countOnlyCases:result.cases;
  if(!Array.isArray(rawCases)||rawCases.length!==job.cases.length)throw Error('Workflow case count mismatch');
  return {schema:'fox.vision_workflow_facts.v1',jobID:job.id,workflow:job.workflow,
    execution:portable?'portable_core_replay_not_actual_app':'actual_app_consumer',acceptance:'not_assessed',
    sourceSHA256:result.inputProvenance?.sourceSHA256,cases:job.cases.map((spec,i)=>{
      const raw=rawCases[i],specification=raw.specification;
      for(const key of ['id','arm','startSeconds','endSeconds','formalStartSeconds','strategyID','personID','bodyView']) {
        if(specification?.[key]!==spec[key])throw Error('Workflow case binding mismatch');
      }
      const selected=frames.filter(f=>f.seconds>=spec.startSeconds&&f.seconds<spec.endSeconds),times=selected.map(f=>f.seconds);
      if(times[0]!==spec.startSeconds)throw Error('Missing workflow input boundary');
      const admitted=greedyPTS(times);
      let events,trace,resetCounts;
      if(portable) {
        if(raw.replay.binding.algorithm!==job.workflow.algorithm||raw.replay.formalStartSeconds!==spec.formalStartSeconds
          ||raw.replay.sourceOriginSeconds!==spec.startSeconds||raw.replay.side!==spec.arm)throw Error('Detached portable case');
        ({events,trace,resetCounts}=raw.replay);
      } else if(job.mode==='countOnly') {
        if(!witness)throw Error('Count-only confirmation has no S/B witnesses; provide an identified Core witness result');
        const w=witness.cases[i];events=w.events;trace=w.trace;resetCounts=w.resetCounts;
        if(!isDeepStrictEqual(raw.events.map(e=>e.completedAtSourcePTSSeconds),events.map(e=>e.completedAtSourcePTSSeconds))
          ||!isDeepStrictEqual(raw.admittedFramePTSSeconds,admitted))throw Error('App/Core event or admission parity mismatch');
        for(const key of ['sourceOriginSeconds','formalStartSeconds'])if(raw[key]!==w[key])throw Error('App/Core source window mismatch');
        const compare=values=>values.map(t=>Object.fromEntries(['sourcePTSSeconds','admitted','formal','automaticCount','reason'].map(k=>[k,t[k]])));
        if(!Array.isArray(raw.trace)||!isDeepStrictEqual(compare(raw.trace),compare(trace)))throw Error('App/Core actual per-frame telemetry mismatch');
      } else {
        const origin=raw.originSeconds;
        events=raw.repetitions.map((r,j)=>({id:String(j+1),completedAtSourcePTSSeconds:origin+r.completedAtSeconds,
          startedAtSourcePTSSeconds:r.startedAtSeconds==null?null:origin+r.startedAtSeconds,
          peakGateAtSourcePTSSeconds:r.peakAtSeconds==null?null:origin+r.peakAtSeconds,
          returnGateAtSourcePTSSeconds:r.loweredAtSeconds==null?null:origin+r.loweredAtSeconds}));
        trace=raw.workflowTrace;resetCounts=raw.resetCounts;
      }
      if(!Array.isArray(events)||!Array.isArray(trace)||trace.length!==times.length
        ||trace.some((t,j)=>t.sourcePTSSeconds!==times[j]||t.admitted!==admitted.includes(times[j])
          ||t.formal!==(times[j]>=spec.formalStartSeconds)||typeof t.reason!=='string'||typeof t.reset!=='boolean'
          ||(!t.admitted&&t.reason!=='cadence_not_admitted')))throw Error('Incomplete or false workflow admission trace');
      if(events.some((e,j)=>e.id!==String(j+1)||!Number.isFinite(e.completedAtSourcePTSSeconds)||!admitted.some(t=>Math.abs(t-e.completedAtSourcePTSSeconds)<=1e-9)
        ||j>0&&e.completedAtSourcePTSSeconds<=events[j-1].completedAtSourcePTSSeconds))throw Error('Invalid workflow event PTS');
      if(trace.some(t=>!Number.isSafeInteger(t.automaticCount)||t.automaticCount!==events.filter(e=>e.completedAtSourcePTSSeconds<=t.sourcePTSSeconds+1e-9).length))
        throw Error('Workflow event/count telemetry mismatch');
      return {specification:spec,sourceOriginSeconds:spec.startSeconds,formalStartSeconds:spec.formalStartSeconds,
        events,trace,resetCounts:resetCounts??{},admittedFramePTSSeconds:admitted,
        witnessSource:!portable&&job.mode==='countOnly'?'separate_portable_core_gates_with_actual_app_completion_parity':'producer_observed_gates',
        phaseStatus:job.workflow.phaseStatus,eventTimeMeaning:job.workflow.eventTimeMeaning};
    })};
}

export async function replayWorkflow({jobFolder,job,jobSHA256,executable,destination}) {
  if(!job.workflow||!executable)throw Error('replay requires an action-bound job and --executable fox-workflow-replay');
  const producerSHA256=createHash('sha256').update(await readFile(executable)).digest('hex');
  await mkdir(destination,{recursive:false,mode:0o700});
  const output=path.join(destination,'workflow-result.json');
  const run=spawnSync(executable,[jobFolder,output],{encoding:'utf8',timeout:60000,maxBuffer:1024*1024});
  const status={schema:'fox.vision_workflow_status.v1',jobID:job.id,jobSHA256,phase:'failed',execution:'portable_core_replay_not_actual_app',
    producer:{path:executable,sha256:producerSHA256},stdout:run.stdout,stderr:run.stderr,exitCode:run.status};
  try {
    if(run.error||run.status!==0)throw Error(`Portable replay failed: ${run.error?.message??run.stderr}`);
    const bytes=await readFile(output),value=JSON.parse(bytes),{frames}=await workflowFrames(jobFolder,job);
    const facts=normalizeWorkflowResult(job,value,{jobSHA256,frames});
    status.phase='completed';status.result={path:'workflow-result.json',bytes:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};
    return {directory:destination,facts};
  } catch(error){status.error=error.message;throw error;}
  finally {await writeFile(path.join(destination,'workflow-status.json'),JSON.stringify(status,null,2)+'\n',{flag:'wx',mode:0o600});}
}

export function workflowReports(reference,facts,frames) {
  if(reference.schema!=='fox.coverage_period_reference.v1'||!Array.isArray(reference.clips))throw Error('Unsupported frozen reference');
  if(reference.clips.length!==facts.cases.length)throw Error('Reference denominator/case declaration mismatch');
  const clips=reference.clips.map(clip=>{
    const c=facts.cases.find(c=>c.specification.id===clip.id);
    if(!c||clip.person_id==null||clip.person_id!==c.specification.personID||clip.side!==c.specification.arm||clip.source_sha256!==facts.sourceSHA256
      ||clip.action!==facts.workflow.action||clip.body_view!==facts.workflow.bodyView)
      throw Error('Reference source/person/side/view binding mismatch');
    const [n,d]=clip.time_base??[],tick=n/d;
    if(!Number.isFinite(tick)||tick<=0||!Array.isArray(clip.frame_pts)||!Array.isArray(clip.cycles))throw Error('Invalid original source clock');
    const toTick=s=>{const p=Math.round(s/tick);if(!Number.isSafeInteger(p)||Math.abs(p*tick-s)>tick*.001)throw Error('PTS seconds are off original source ticks');return p;};
    const rawPTS=frames.filter(f=>f.seconds>=c.specification.startSeconds&&f.seconds<c.specification.endSeconds).map(f=>toTick(f.seconds));
    if(!isDeepStrictEqual(rawPTS,clip.observer_input_pts))throw Error('Raw cache does not match frozen observer input clock');
    if(clip.counter_admission_policy!=='camera_greedy_12hz_v1')throw Error('Reference must freeze the actual camera admission policy');
    if(clip.cycles.some(cy=>!Array.isArray(cy.S)||cy.S[0]*tick+1e-9<c.formalStartSeconds))throw Error('Reference contains a pre-formal cycle; freeze source-only formal denominator explicitly');
    const events=c.events.map(e=>{
      if(e.startedAtSourcePTSSeconds==null||e.peakGateAtSourcePTSSeconds==null)throw Error('Count confirmation does not provide source start/peak witnesses');
      return {startedAtSeconds:e.startedAtSourcePTSSeconds,lowEndpointCandidateSeconds:e.peakGateAtSourcePTSSeconds,
        completedAtSeconds:e.completedAtSourcePTSSeconds};
    });
    return {id:clip.id,person_id:clip.person_id,source_sha256:clip.source_sha256,side:clip.side,report:{count:events.length,events,
      admitted_frame_pts:c.admittedFramePTSSeconds.map(toTick),resetCounts:c.resetCounts,
      trace:c.trace.map(t=>({seconds:t.sourcePTSSeconds,admitted:t.admitted,reason:t.reason==='observed'?'valid':t.reason,
        reset:t.reset,resetReason:t.resetReason??null}))}};
  });
  return {schema:'fox.coverage_period_reports.v1',clips};
}

async function canonicalEvaluation(referenceFile,reports,output,python) {
  const reportsFile=output+'.reports.json',canonicalOutput=output+'.canonical.json';
  await writeFile(reportsFile,JSON.stringify(reports,null,2)+'\n',{flag:'wx',mode:0o600});
  const run=spawnSync(python,[path.join(root,'scripts/coverage_period_eval.py'),'--reference',referenceFile,'--reports',reportsFile,'--output',canonicalOutput],
    {encoding:'utf8',timeout:60000,maxBuffer:1024*1024});
  if(run.error||run.status!==0)throw Error(`Canonical evaluation failed; inputs retained: ${run.error?.message??run.stderr}`);
  return JSON.parse(await readFile(canonicalOutput));
}

// Cohort input is an index of existing job/result files, never a producer input.
// Missing results retain their full frozen reference denominator and null observed facts.
export async function evaluateWorkflowCohort({indexFile,referenceFile,output,python='python3',validateJob,verifyAppResult}) {
  if(!validateJob||!verifyAppResult)throw Error('Cohort requires the existing batch job/result verifiers');
  const indexBytes=await readFile(indexFile),index=JSON.parse(indexBytes),referenceBytes=await readFile(referenceFile),reference=JSON.parse(referenceBytes);
  if(index.schema!=='fox.vision_workflow_evaluation_inputs.v1'||!Array.isArray(index.runs)||index.runs.length<1||index.runs.length>64
    ||reference.schema!=='fox.coverage_period_reference.v1'||!Array.isArray(reference.clips))throw Error('Invalid workflow cohort/reference');
  const resolve=p=>{if(typeof p!=='string'||!p)throw Error('Invalid cohort input path');return path.resolve(path.dirname(indexFile),p);};
  let binding;
  const reports={schema:'fox.coverage_period_reports.v1',clips:[]},observed=new Map(),seen=new Set(),artifacts=[];
  for(const entry of index.runs) {
    const jobFolder=resolve(entry.jobFolder),resultFile=resolve(entry.resultFile),{job,jobSHA256}=await validateJob(jobFolder);
    if(!job.workflow)throw Error('Cohort requires action-bound workflow jobs');
    if(binding&&!isDeepStrictEqual(binding,job.workflow))throw Error('Cohort strategies differ');
    binding=job.workflow;
    for(const c of job.cases){if(seen.has(c.id))throw Error('Duplicate cohort case/job');seen.add(c.id);}
    const {frames,header}=await workflowFrames(jobFolder,job),selected=reference.clips.filter(c=>job.cases.some(s=>s.id===c.id));
    if(selected.length!==job.cases.length)throw Error('Unexpected cohort case outside frozen reference');
    const scoped={...reference,clips:selected};
    let bytes;
    try {bytes=await readFile(resultFile);}catch(error){if(error.code!=='ENOENT')throw error;}
    if(!bytes) {
      const missing={workflow:job.workflow,sourceSHA256:header.sourceSHA256,cases:job.cases.map(spec=>({specification:spec,
        formalStartSeconds:spec.formalStartSeconds,events:[],trace:[],resetCounts:{},admittedFramePTSSeconds:[]}))};
      workflowReports(scoped,missing,frames); // validate source/clock/person/view without inventing a report
      for(const c of job.cases)observed.set(c.id,{status:'result_missing',observed:null});
      artifacts.push({jobSHA256,status:'result_missing',observationClockAsset:job.files.find(f=>f.path===job.sourceClock.path)});continue;
    }
    const result=JSON.parse(bytes);let witness;
    if(result.schema==='fox.vision_batch_result.v1') {
      if(path.basename(resultFile)!=='result.json')throw Error('App cohort requires intact result directories');
      await verifyAppResult(path.dirname(resultFile),jobSHA256);
    }
    if(entry.witnessFile)witness=normalizeWorkflowResult(job,JSON.parse(await readFile(resolve(entry.witnessFile))),{jobSHA256,frames});
    const facts=normalizeWorkflowResult(job,result,{jobSHA256,frames,witness});
    if(facts.sourceSHA256!==header.sourceSHA256)throw Error('Cohort result provenance differs from input');
    reports.clips.push(...workflowReports(scoped,facts,frames).clips);
    for(const c of facts.cases)observed.set(c.specification.id,{status:'reported',observed:c.events.length,witnessSource:c.witnessSource});
    artifacts.push({jobSHA256,status:'reported',resultSHA256:createHash('sha256').update(bytes).digest('hex'),
      observationClockAsset:job.files.find(f=>f.path===job.sourceClock.path),
      ...(entry.witnessFile?{witnessSHA256:createHash('sha256').update(await readFile(resolve(entry.witnessFile))).digest('hex')}:{})});
  }
  if(reference.clips.some(c=>c.action!==binding.action||c.body_view!==binding.bodyView))throw Error('Cohort reference action/view binding mismatch');
  const evaluated=await canonicalEvaluation(referenceFile,reports,output,python);
  const value={schema:'fox.vision_workflow_evaluation.v1',status:'evaluated',workflow:binding,execution:'cohort_existing_producer_results',
    evidenceBoundary:'frozen-full-cohort-reference-denominator-not-new-camera-accuracy-or-verified-identity',evaluation:evaluated,
    cases:reference.clips.map(c=>{const facts=observed.get(c.id)??{status:'input_not_supplied',observed:null};return {id:c.id,...facts,
      formalReference:c.cycles.length,absoluteCountError:facts.observed==null?null:Math.abs(facts.observed-c.cycles.length)};}),
    artifacts:{indexSHA256:createHash('sha256').update(indexBytes).digest('hex'),referenceSHA256:createHash('sha256').update(referenceBytes).digest('hex'),
      workflowAdapterSHA256:createHash('sha256').update(await readFile(fileURLToPath(import.meta.url))).digest('hex'),
      registrySHA256:createHash('sha256').update(await readFile(registryFile)).digest('hex'),runs:artifacts}};
  await writeFile(output,JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});return value;
}

export async function evaluateWorkflow({jobFolder,job,jobSHA256,resultFile,referenceFile,output,witnessFile,python='python3'}) {
  const {frames,header}=await workflowFrames(jobFolder,job),resultBytes=await readFile(resultFile),result=JSON.parse(resultBytes);
  let witness;
  if(witnessFile)witness=normalizeWorkflowResult(job,JSON.parse(await readFile(witnessFile)),{jobSHA256,frames});
  const facts=normalizeWorkflowResult(job,result,{jobSHA256,frames,witness});
  if(facts.sourceSHA256!==header.sourceSHA256)throw Error('Result provenance differs from frozen cache');
  const referenceBytes=await readFile(referenceFile),reference=JSON.parse(referenceBytes);
  const implementationArtifacts={workflowAdapterSHA256:createHash('sha256').update(await readFile(fileURLToPath(import.meta.url))).digest('hex'),
    registrySHA256:createHash('sha256').update(await readFile(registryFile)).digest('hex'),
    observationClockAsset:job.files.find(f=>f.path===job.sourceClock.path)};
  if(reference.schema==='fox.coverage_reference.v2') {
    if(job.workflow.action!=='curl'||facts.cases.length!==1||reference.source_sha256!==header.sourceSHA256
      ||reference.side!==facts.cases[0].specification.arm)throw Error('Legacy reference source/action/side mismatch');
    if(!Array.isArray(reference.events))throw Error('Invalid legacy reference events');
    const c=facts.cases[0],cycles=reference.events.filter(e=>e.role==='complete_interior'
      &&Array.isArray(e.start_bracket)&&e.start_bracket[0]>=c.formalStartSeconds);
    const crosses=reference.events.some((e,i)=>e.return_bracket?.[1]>reference.events[i+1]?.start_bracket?.[0]);
    const value={schema:'fox.vision_workflow_evaluation.v1',status:'reference_not_assessable',jobID:job.id,workflow:job.workflow,execution:facts.execution,
      evidenceBoundary:'legacy-reference-insufficient-for-canonical-evaluation-not-new-accuracy',
      evaluation:{status:'reference_not_assessable',firstReason:crosses?'legacy_return_bracket_crosses_declared_ownership':'legacy_rounded_ms_reference_not_original_tick_brackets',
        reasons:['legacy_rounded_ms_reference_not_original_tick_brackets',...(crosses?['return_bracket_crosses_next_lower_start_ownership']:[])],
        count:{TP:null,FN:null,FP:null,unknown:c.events.length,reference_cycles:cycles.length,predicted_events:c.events.length,
          strict_precision:null,recall:null,acceptance:'reference_not_assessable'},period:{acceptance:'reference_not_assessable'},exact_endpoint_accuracy_claim:false},
      cases:[{id:c.specification.id,observed:c.events.length,formalReference:cycles.length,
        absoluteCountError:Math.abs(c.events.length-cycles.length),metricMeaning:'descriptive_totals_not_cycle_matches'}],
      artifacts:{jobSHA256,resultSHA256:createHash('sha256').update(resultBytes).digest('hex'),referenceSHA256:createHash('sha256').update(referenceBytes).digest('hex'),...implementationArtifacts}};
    await writeFile(output,JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});return value;
  }
  const reports=workflowReports(reference,facts,frames);
  const evaluated=await canonicalEvaluation(referenceFile,reports,output,python);
  const value={schema:'fox.vision_workflow_evaluation.v1',status:'evaluated',jobID:job.id,workflow:job.workflow,execution:facts.execution,
    evidenceBoundary:'same-cache-wiring-and-frozen-reference-evaluation-not-new-camera-accuracy-or-human-trial-readiness',
    personIdentity:'reference declaration; central selection does not independently verify identity',
    phaseStatus:job.workflow.phaseStatus,eventTimeMeaning:job.workflow.eventTimeMeaning,evaluation:evaluated,
    cases:facts.cases.map(c=>({id:c.specification.id,observed:c.events.length,
      formalReference:reference.clips.find(x=>x.id===c.specification.id).cycles.length,
      absoluteCountError:Math.abs(c.events.length-reference.clips.find(x=>x.id===c.specification.id).cycles.length),witnessSource:c.witnessSource})),
    artifacts:{jobSHA256,resultSHA256:createHash('sha256').update(resultBytes).digest('hex'),referenceSHA256:createHash('sha256').update(referenceBytes).digest('hex'),...implementationArtifacts,
      ...(witnessFile?{witnessSHA256:createHash('sha256').update(await readFile(witnessFile)).digest('hex')}:{})}};
  await writeFile(output,JSON.stringify(value,null,2)+'\n',{flag:'wx',mode:0o600});
  return value;
}
