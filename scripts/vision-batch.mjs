import { randomUUID, createHash } from 'node:crypto';
import { copyFile, lstat, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { digestFile } from './vision-diagnostics.mjs';
import { selectPairedDevice } from './ios-device-selection.mjs';

const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const uuid = /^[A-F0-9]{8}(-[A-F0-9]{4}){3}-[A-F0-9]{12}$/;
const name = value => typeof value === 'string' && /^[a-zA-Z0-9_.-]{1,100}$/.test(value) && !['.','..'].includes(value);
const digest = data => createHash('sha256').update(data).digest('hex');
const json = async file => JSON.parse(await readFile(file,'utf8'));

function archiveEvidence(resultFolder, jobFolder) {
  // Separate CLI avoids an import cycle: the archive verifier reuses this module's receipt checks.
  const result = spawnSync(process.execPath,[path.join(root,'scripts/vision-evidence.mjs'),'capture',resultFolder,'--job',jobFolder],
    {encoding:'utf8',maxBuffer:1024*1024});
  if (result.error || result.status !== 0) throw Error(`Batch receipt retained at ${resultFolder}; evidence indexing failed: ${result.error?.message ?? result.stderr}`);
  return JSON.parse(result.stdout);
}

function validate(job) {
  const mode = job.mode ?? 'controller';
  if (job.schema !== 'fox.vision_batch_job.v1' || !uuid.test(job.id ?? '') || !['cache','diagnostic','video'].includes(job.kind)
      || !['controller','observations','countOnly'].includes(mode)
      || !name(job.input) || !Array.isArray(job.files) || job.files.length < 1 || job.files.length > 4
      || !Array.isArray(job.cases) || (mode !== 'observations' ? job.cases.length < 1 || job.cases.length > 16
        : job.cases.length !== 0 || job.kind === 'diagnostic')
      || new Set(job.files.map(f=>f.path)).size !== job.files.length || !job.files.some(f=>f.path === job.input)
      || new Set(job.cases.map(c=>c.id)).size !== job.cases.length) throw Error('Invalid batch job');
  if (mode === 'countOnly' && (job.kind !== 'cache' || job.settings != null)) throw Error('Count-only requires frozen cache runtime');
  for (const f of job.files) {
    if (!name(f.path) || !Number.isSafeInteger(f.bytes) || f.bytes <= 0 || f.bytes > 512*1024*1024
        || !/^[a-f0-9]{64}$/.test(f.sha256 ?? '')) throw Error('Invalid batch asset');
  }
  for (const c of job.cases) {
    const actionOK = mode === 'countOnly' ? ['curl','squat'].includes(c.countOnlyAction) && c.exercise == null
      && c.rebindAtSeconds?.length === 0 : ['curl','lateralRaise','latPulldown'].includes(c.exercise) && c.countOnlyAction == null;
    if (!name(c.id) || !actionOK || !['left','right'].includes(c.arm)
        || !Number.isFinite(c.startSeconds) || !Number.isFinite(c.endSeconds) || c.startSeconds < 0
        || c.endSeconds <= c.startSeconds || c.endSeconds-c.startSeconds > 600 || !Array.isArray(c.rebindAtSeconds)
        || c.rebindAtSeconds.length > 50 || c.rebindAtSeconds.some((v,i,a)=>!Number.isFinite(v)
          || v < c.startSeconds || v >= c.endSeconds || (i > 0 && v <= a[i-1]))) throw Error('Invalid batch segment');
  }
}
export async function validateBatchJob(folder) {
  const url = path.join(folder,'job.json'), info = await lstat(url);
  if (!info.isFile() || info.isSymbolicLink() || info.size > 128*1024) throw Error('Unsafe batch job file');
  const bytes = await readFile(url), job = JSON.parse(bytes); validate(job);
  for (const file of job.files) {
    const actual = await digestFile(path.join(folder,file.path));
    if (actual.bytes !== file.bytes || actual.sha256 !== file.sha256) throw Error(`Batch input checksum mismatch: ${file.path}`);
  }
  return { job, jobSHA256:digest(bytes) };
}

export async function prepareBatch({source,kind,cases,settings,destination,mode = 'controller',assets = []}) {
  const id = randomUUID().toUpperCase(), directory = path.join(destination,id);
  const files = [], input = kind === 'video' ? 'manifest.json' : 'input.jsonl';
  const sourceAssets = [{source:path.resolve(source),path:input}];
  if (!Array.isArray(assets) || assets.length > 3) throw Error('Too many additional batch assets');
  for (const asset of assets) sourceAssets.push({source:path.resolve(asset),path:path.basename(asset)});
  if (kind === 'video') {
    const manifest = await json(source);
    if (!name(manifest.asset) || !Number.isFinite(manifest.duration_seconds) || manifest.duration_seconds <= 0
        || manifest.duration_seconds > 600) throw Error('Invalid video manifest');
    const video = path.resolve(path.dirname(source),manifest.asset), actual = await digestFile(video);
    if (actual.sha256 !== manifest.sha256) throw Error('Video checksum mismatch');
    sourceAssets.push({source:video,path:manifest.asset});
  }
  for (const file of sourceAssets) files.push({path:file.path,...await digestFile(file.source)});
  const job = {schema:'fox.vision_batch_job.v1',id,kind,mode,input,files,cases, ...(settings ? {settings} : {})};
  validate(job);
  await mkdir(directory,{recursive:true,mode:0o700});
  for (const asset of sourceAssets) await copyFile(asset.source,path.join(directory,asset.path));
  await writeFile(path.join(directory,'job.json'),JSON.stringify(job,null,2)+'\n',{flag:'wx',mode:0o600});
  await validateBatchJob(directory);
  return {id,directory};
}

export function isCountOnlyArchiveName(value) {
  return typeof value === 'string' && value.length <= 240
    && /^[a-zA-Z0-9_.-]{1,100}\.training\.json(?:\.pre-assisted-v[12]-[a-f0-9]{64}-original)?$/.test(value);
}
function validateStatus(status, expectedJobSHA256) {
  if (status.schema !== 'fox.vision_batch_status.v1' || status.phase !== 'completed' || status.error != null) throw Error('Batch is not completed');
  if (!uuid.test(status.jobID ?? '') || status.jobSHA256 !== expectedJobSHA256) throw Error('Unexpected batch job digest');
  if (!Array.isArray(status.files) || !status.files.some(f=>f.path==='result.json') || !status.files.some(f=>f.path==='settings.json')
      || status.files.length > 66 || new Set(status.files.map(f=>f.path)).size !== status.files.length) throw Error('Missing or duplicate batch result');
  for (const f of status.files) {
    if ((!['result.json','settings.json','vision.jsonl'].includes(f.path) && !isCountOnlyArchiveName(f.path)) || !Number.isSafeInteger(f.bytes)
        || f.bytes <= 0 || f.bytes > 64*1024*1024 || !/^[a-f0-9]{64}$/.test(f.sha256 ?? '')) throw Error('Unsafe batch result asset');
  }
}
async function verifyCountOnly(folder, result, status) {
  const algorithms = {curl:'central-continuous-curl-v1',squat:'squat-selected-count-only-v1'};
  if (result.controllerVersion !== 'workout-coordinator-count-only-v1' || result.inferencePerformed !== false
      || result.settingsScope !== 'legacy_settings_not_used_by_count_only' || result.cases?.length !== 0
      || !Array.isArray(result.countOnlyCases) || result.countOnlyCases.length < 1 || result.countOnlyCases.length > 16
      || new Set(result.countOnlyCases.map(c=>c.specification?.id)).size !== result.countOnlyCases.length) throw Error('Invalid count-only result');
  const claimed = new Set(['result.json','settings.json']);
  for (const c of result.countOnlyCases) {
    const spec = c.specification, record = c.record, evidence = record?.assistedEvidence;
    if (!name(spec?.id) || !algorithms[spec.countOnlyAction] || !['left','right'].includes(spec.arm)
        || result.algorithms?.[spec.countOnlyAction] !== algorithms[spec.countOnlyAction]
        || c.manualConfirmation !== 'unknown' || c.phaseStatus !== 'not_provided'
        || c.sourceTimebase !== 'original_source_pts_seconds_double_not_complete_cmtime'
        || c.eventTimeMeaning !== 'count_confirmation_not_anatomical_return_endpoint'
        || !Number.isFinite(c.sourceOriginSeconds) || c.sourceOriginSeconds !== spec.startSeconds
        || !Number.isFinite(c.formalStartSeconds) || Math.abs(c.formalStartSeconds-c.sourceOriginSeconds-2) > 1e-9
        || !Number.isSafeInteger(c.automaticCount) || c.automaticCount < 0
        || !Array.isArray(c.events) || c.events.length !== c.automaticCount
        || record.countingMethod !== 'unconfirmed' || record.reps != null || record.sideRepetitions != null
        || record.visualEvidence != null || record.rhythmAssessment != null || record.formAssessment != null
        || evidence?.schema !== 'fox.workout_count_only.v1' || evidence.action !== spec.countOnlyAction || evidence.side !== spec.arm
        || !Array.isArray(evidence.runs)) throw Error('Invalid count-only facts/unknown confirmation');
    const expected = evidence.runs.flatMap(run => {
      const value = run.evidence;
      if (value == null) return [];
      if (value.phaseStatus !== 'not_provided' || value.action !== spec.countOnlyAction || value.side !== spec.arm
          || value.algorithm !== algorithms[spec.countOnlyAction] || !Array.isArray(value.events)) throw Error('Invalid count-only observation run');
      return value.events.map(e=>({completedAtSourcePTSSeconds:value.inputOriginSeconds+e.completedAtSeconds,
        observationRunID:run.id,segmentID:e.segmentID}));
    });
    if (!isDeepStrictEqual(expected,c.events) || c.events.some((e,i,a)=>!Number.isFinite(e.completedAtSourcePTSSeconds)
        || e.completedAtSourcePTSSeconds < c.formalStartSeconds || e.completedAtSourcePTSSeconds >= spec.endSeconds
        || i > 0 && e.completedAtSourcePTSSeconds <= a[i-1].completedAtSourcePTSSeconds)) throw Error('Detached count-only events');
    if (!Array.isArray(c.admittedFramePTSSeconds) || c.admittedFramePTSSeconds.some((v,i,a)=>!Number.isFinite(v)
        || v < spec.startSeconds || v >= spec.endSeconds || i > 0 && v <= a[i-1])) throw Error('Invalid source PTS seconds');
    if (c.events.some(e=>!c.admittedFramePTSSeconds.some(t=>Math.abs(t-e.completedAtSourcePTSSeconds)<=1e-9))) throw Error('Confirmation absent from admitted source PTS seconds');
    const main = `${spec.id}.training.json`;
    if (!Array.isArray(c.archiveAssets) || c.archiveAssets.length !== 2
        || !c.archiveAssets.some(f=>f.path === main)
        || !c.archiveAssets.some(f=>f.path.startsWith(main+'.pre-assisted-v2-'))) throw Error('Missing count-only archive or original v2 backup');
    for (const asset of c.archiveAssets) {
      if (!isCountOnlyArchiveName(asset.path) || !(asset.path === main || asset.path.startsWith(main+'.'))
          || asset.path !== main && !asset.path.endsWith(`-${asset.sha256}-original`)
          || claimed.has(asset.path) || !isDeepStrictEqual(status.files.find(f=>f.path === asset.path),asset)) throw Error('Detached count-only archive asset');
      claimed.add(asset.path);
      if (asset.path !== main && (await json(path.join(folder,asset.path))).schemaVersion !== 2) throw Error('Count-only original backup is not v2');
    }
    const archive = await json(path.join(folder,main));
    const saved = archive.sessions?.flatMap(s=>s.records ?? []).filter(r=>r.id === record.id);
    if (archive.schemaVersion !== 3 || saved?.length !== 1 || !isDeepStrictEqual(saved[0],record)) throw Error('Actual count-only archive does not match record');
  }
  if (status.files.some(f=>!claimed.has(f.path))) throw Error('Unclaimed count-only result asset');
}
export async function verifyBatchResult(folder, expectedJobSHA256) {
  const info = await lstat(path.join(folder,'status.json'));
  if (!info.isFile() || info.isSymbolicLink() || info.size > 128*1024) throw Error('Unsafe batch status');
  const status = await json(path.join(folder,'status.json')); validateStatus(status,expectedJobSHA256);
  for (const file of status.files) {
    const actual = await digestFile(path.join(folder,file.path));
    if (actual.bytes !== file.bytes || actual.sha256 !== file.sha256) throw Error(`Batch result checksum mismatch: ${file.path}`);
  }
  const result = await json(path.join(folder,'result.json')), settings = await readFile(path.join(folder,'settings.json'));
  if (result.schema !== 'fox.vision_batch_result.v1' || result.jobID !== status.jobID || result.jobSHA256 !== status.jobSHA256
      || result.settingsSHA256 !== digest(settings) || JSON.stringify(result.settings) !== JSON.stringify(JSON.parse(settings))) {
    throw Error('Batch result identity/settings mismatch');
  }
  if (result.mode === 'observations' && (result.controllerVersion !== 'not-run' || result.cases?.length !== 0
      || !Number.isSafeInteger(result.observationFrameCount) || result.observationFrameCount < 2
      || Object.keys(result.algorithms ?? {}).length !== 0)) throw Error('Invalid observations-only result');
  if (result.mode === 'countOnly') await verifyCountOnly(folder,result,status);
  else if (status.files.length > 3 || status.files.some(f=>isCountOnlyArchiveName(f.path))) throw Error('Unexpected count-only archive in legacy result');
  return {status,result};
}

export async function importBatchResult(source, destination, expectedJobSHA256) {
  const verified = await verifyBatchResult(source,expectedJobSHA256);
  let present = false;
  try { await lstat(destination); present = true; }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (present) {
    await verifyBatchResult(destination,expectedJobSHA256);
    if (!(await readFile(path.join(source,'status.json'))).equals(await readFile(path.join(destination,'status.json')))) {
      throw Error('Existing batch result differs; not overwritten');
    }
    return verified;
  }
  await mkdir(path.dirname(destination),{recursive:true,mode:0o700});
  const staging = `${destination}.partial-${randomUUID()}`;
  await mkdir(staging,{mode:0o700});
  try {
    for (const file of ['status.json',...verified.status.files.map(f=>f.path)]) await copyFile(path.join(source,file),path.join(staging,file));
    await verifyBatchResult(staging,expectedJobSHA256);
    await rename(staging,destination);
  } catch (error) { await rm(staging,{recursive:true,force:true}); throw error; }
  return verified;
}

export function batchLaunchEnvironment(job) { return {FOX_POSE_BATCH_JOB:job.id,...(job.mode === 'countOnly' ? {FOX_COUNT_ONLY_DIAGNOSTIC:'1'} : {})}; }
export function batchCounts(result) { return result.mode === 'countOnly' ? result.countOnlyCases.map(c=>({id:c.specification.id,count:c.automaticCount}))
  : result.cases.map(c=>({id:c.specification.id,count:c.repetitions.length})); }

async function cli() {
  const [command,...args] = process.argv.slice(2);
  const option = key => { const i = args.indexOf(key); return i < 0 ? undefined : args[i+1]; };
  if (command === 'prepare') {
    const mode = option('--mode') ?? 'controller';
    if (!args[0] || (mode !== 'observations' && !option('--cases'))) throw Error('prepare <source> --kind cache|diagnostic|video [--mode controller|observations|countOnly] [--cases <json>] [--asset <frozen-clock-or-index>] [--settings <json>]');
    return prepareBatch({source:path.resolve(args[0]), kind:option('--kind') ?? 'cache', mode,
      cases:option('--cases') ? await json(option('--cases')) : [],
      settings:option('--settings') ? await json(option('--settings')) : undefined,
      assets:args.flatMap((v,i)=>v === '--asset' ? [args[i+1]] : []),
      destination:path.resolve(option('--destination') ?? path.join(root,'.data/vision-replay/jobs'))});
  }
  if (!['run','pull','verify'].includes(command) || !args[0]) throw Error('Expected prepare, run <job-folder>, pull <job-folder>, or verify <result-folder> --job <job-folder>');
  const jobFolder = path.resolve(command === 'verify' ? option('--job') ?? '' : args[0]);
  const {job,jobSHA256} = await validateBatchJob(jobFolder);
  if (command === 'verify') {
    const value = await verifyBatchResult(path.resolve(args[0]),jobSHA256);
    return {status:'verified',jobID:job.id,mode:value.result.mode ?? 'controller',observationFrameCount:value.result.observationFrameCount,
      counts:batchCounts(value.result)};
  }
  const work = path.join(root,'.tmp/vision-batch',randomUUID()); await mkdir(work,{recursive:true,mode:0o700});
  let sequence = 0;
  const tool = async tail => {
    const file = path.join(work,`device-${sequence++}.json`);
    const result = spawnSync('xcrun',['devicectl',...tail,'--quiet','--timeout','120','--json-output',file], {
      env:{...process.env,DEVELOPER_DIR:process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer'},
      encoding:'utf8',timeout:130000,maxBuffer:1024*1024});
    if (result.error || result.status !== 0) {
      let description = result.error?.message ?? result.stderr;
      try { description = (await json(file)).error?.userInfo?.NSLocalizedDescription?.string ?? description; } catch {}
      throw Error(`Device command failed; check connection/unlock. ${description ?? ''}`);
    }
    const value = await json(file);
    if (value.info?.outcome !== 'success') throw Error('Device did not confirm success');
    return value.result;
  };
  const device = selectPairedDevice((await tool(['list','devices'])).devices ?? [],{selector:process.env.FOX_IOS_DEVICE,family:'iPad'}).identifier;
  const domain = ['--device',device,'--domain-type','appDataContainer','--domain-identifier','com.whipa.fox'];
  const remote = `Documents/FoxReplayRuns/${job.id}`;
  if (command === 'run') {
    const docs = await tool(['device','info','files',...domain,'--subdirectory','Documents','--no-recurse']);
    for (const directory of ['FoxReplay','FoxReplayRuns']) {
      if (!(docs.files ?? []).some(f=>f.name === directory)) continue;
      const entries = await tool(['device','info','files',...domain,'--subdirectory',`Documents/${directory}`,'--recurse']);
      if ((entries.files ?? []).some(f=>(f.relativePath ?? '').split('/').includes(job.id))) throw Error('Device job ID exists; use pull or prepare a new job, never overwrite');
    }
    await tool(['device','copy','to',...domain,'--source',jobFolder,'--destination',`Documents/FoxReplay/Jobs/${job.id}`]);
    await tool(['device','process','launch','--device',device,...(args.includes('--replace-running') ? ['--terminate-existing'] : []),
      '--environment-variables',JSON.stringify(batchLaunchEnvironment(job)),'com.whipa.fox']);
  }
  const staging = path.join(work,'result'); await mkdir(staging,{mode:0o700});
  const statusFile = path.join(staging,'status.json');
  const startedAt = Date.now(), deadline = startedAt + (command === 'run' ? 600000 : 0);
  let status, lastPhase;
  do {
    try {
      await tool(['device','copy','from',...domain,'--source',`${remote}/status.json`,'--destination',statusFile]);
      status = await json(statusFile);
    } catch (error) { if (command === 'pull' || Date.now() >= deadline) throw error; }
    if (status?.phase !== lastPhase) { lastPhase = status?.phase; if (lastPhase) console.error(`Fox batch: ${lastPhase}`); }
    if (!status && Date.now() - startedAt > 30000) {
      const launch = path.join(work,'launch.json');
      let detail = 'No batch page receipt; the debug route may not have opened.';
      try {
        await tool(['device','copy','from',...domain,'--source',`Documents/FoxReplayLaunches/${job.id}.json`,'--destination',launch]);
        const state = await json(launch);
        detail = `Last page event: ${state.event}; UIKit applicationState=${state.applicationState} (0=active).`;
      } catch {}
      throw Error(`Batch has no processing receipt after 30 seconds. ${detail} Keep Fox foreground and the iPad unlocked.`);
    }
    if (['completed','failed','cancelled'].includes(status?.phase)) break;
    if (command === 'pull') break;
    await new Promise(resolve=>setTimeout(resolve,3000));
  } while (Date.now() < deadline);
  if (status?.phase !== 'completed') {
    const evidence = ['failed','cancelled'].includes(status?.phase) && status.jobSHA256 === jobSHA256 ? archiveEvidence(staging,jobFolder) : null;
    throw Error(`Batch incomplete: ${status?.phase ?? 'no receipt'}. ${status?.error ?? 'Ensure Fox was launched into the batch route and remains foreground.'}${evidence ? ` Archived: ${evidence.directory}` : ''}`);
  }
  validateStatus(status,jobSHA256);
  for (const file of status.files) await tool(['device','copy','from',...domain,'--source',`${remote}/${file.path}`,'--destination',path.join(staging,file.path)]);
  const verified = await verifyBatchResult(staging,jobSHA256);
  const destination = path.resolve(option('--destination') ?? path.join(root,'.data/vision-replay/results',job.id));
  await importBatchResult(staging,destination,jobSHA256);
  const evidence = archiveEvidence(destination,jobFolder);
  return {status:'device-completed-and-verified',jobID:job.id,directory:destination,
    evidenceDirectory:evidence.directory,
    mode:verified.result.mode ?? 'controller',observationFrameCount:verified.result.observationFrameCount,
    inferencePerformed:verified.result.inferencePerformed,counts:batchCounts(verified.result)};
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await cli(),null,2)); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
