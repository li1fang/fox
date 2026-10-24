import { createHash, randomUUID } from 'node:crypto';
import { lstat, mkdir, readFile, readdir, rename, rm, writeFile, chmod } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { validateBatchJob, verifyBatchResult } from './vision-batch.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const appID = 0x464f5856;
const allowed = new Set(['job.json','status.json','result.json','settings.json']);
const json = bytes => JSON.parse(bytes.toString('utf8'));
async function regular(file, max = 64 * 1024 * 1024) {
  const info = await lstat(file);
  if (!info.isFile() || info.isSymbolicLink() || info.size <= 0 || info.size > max) throw Error(`Unsafe evidence file: ${file}`);
  return readFile(file);
}
async function exists(file) { try { await lstat(file); return true; } catch(e) { if(e.code === 'ENOENT') return false; throw e; } }
function integer(value) { return Number.isSafeInteger(value) && value >= 0; }
function derive(jobBytes, statusBytes, resultBytes, settingsBytes) {
  const job = json(jobBytes), status = json(statusBytes), result = resultBytes ? json(resultBytes) : null;
  if (job.schema !== 'fox.vision_batch_job.v1' || !/^[A-F0-9]{8}(-[A-F0-9]{4}){3}-[A-F0-9]{12}$/.test(job.id ?? '')
      || status.schema !== 'fox.vision_batch_status.v1' || status.jobID !== job.id || status.jobSHA256 !== digest(jobBytes)) throw Error('Job identity mismatch');
  if (!['completed','failed','cancelled'].includes(status.phase)) throw Error('Only terminal runs may be archived');
  if (!Array.isArray(job.cases) || !Array.isArray(job.files)) throw Error('Invalid job');
  const completed = status.phase === 'completed';
  if (completed && (status.error != null || !result || result.schema !== 'fox.vision_batch_result.v1' || result.jobID !== job.id
      || result.jobSHA256 !== digest(jobBytes) || result.settingsSHA256 !== digest(settingsBytes)
      || !isDeepStrictEqual(result.settings,json(settingsBytes)) || !isDeepStrictEqual(result.inputAssets,job.files)
      || (result.mode ?? 'controller') !== (job.mode ?? 'controller') || result.inferencePerformed !== (job.kind === 'video')
      || (result.observationFrameCount !== undefined && !integer(result.observationFrameCount))
      || !Array.isArray(result.cases) || result.cases.length !== job.cases.length)) throw Error('Result identity/settings mismatch');
  const cases = job.cases.map((spec, index) => {
    const c = result?.cases[index];
    if (completed && (!isDeepStrictEqual(c?.specification,spec) || !Array.isArray(c.repetitions) || c.repetitions.length > 10000)) throw Error('Case specification mismatch');
    let previous = -1;
    for (const rep of c?.repetitions ?? []) {
      if (!Number.isFinite(rep.completedAtSeconds) || rep.completedAtSeconds <= previous) throw Error('Invalid repetition timeline');
      previous = rep.completedAtSeconds;
    }
    const resets = Object.values(c?.resetCounts ?? {});
    if (!resets.every(integer)) throw Error('Invalid reset counts');
    const reference = c?.validatedReport?.referenceCount ?? null;
    if (reference !== null && !integer(reference)) throw Error('Invalid reference count');
    return {id:spec.id,exercise:spec.exercise,arm:spec.arm,startSeconds:spec.startSeconds,endSeconds:spec.endSeconds,
      automaticCount:c ? c.repetitions.length : null,referenceCount:reference,
      countError:c && reference !== null ? c.repetitions.length-reference : null,
      returnIntervals:c ? c.repetitions.filter(r => r.eccentric?.status === 'measured' || r.precedingReturn?.measurement?.status === 'measured').length : null,
      resets:c ? resets.reduce((a,b)=>a+b,0) : null};
  });
  const strategies = result?.motionStrategies ?? [];
  if (!Array.isArray(strategies) || strategies.some(s=>s.schema !== 'fox.motion_strategy.v1' || !integer(s.version) || s.version < 1
      || result.algorithms?.[s.exercise] !== s.algorithm)) throw Error('Invalid strategy association');
  return {schema:'fox.vision_run.v1',id:job.id,status:status.phase,acceptance:'not_assessed',
    evidenceKind:`${job.mode === 'observations' ? 'observations' : 'controller'}_${job.kind === 'video' ? 'video' : 'cache'}`,
    evidenceBoundary:result?.evidenceBoundary ?? 'processing-did-not-complete-not-acceptance',
    jobSHA256:digest(jobBytes),inputAssets:job.files,settingsSHA256:result?.settingsSHA256 ?? null,
    execution:{appVersion:result?.appVersion ?? null,appBuild:result?.appBuild ?? null,controllerVersion:result?.controllerVersion ?? null,
      device:result?.device ?? null,platform:result?.platform ?? null,sourceSHA256:null},
    motionStrategies:strategies,cases};
}

export async function archiveBatch({resultFolder,jobFolder,archiveRoot}) {
  const {job,jobSHA256} = await validateBatchJob(jobFolder);
  const jobBytes = await regular(path.join(jobFolder,'job.json'),128*1024);
  const statusBytes = await regular(path.join(resultFolder,'status.json'),128*1024), status = json(statusBytes);
  if (!['completed','failed','cancelled'].includes(status.phase)) throw Error('Only terminal runs may be archived');
  if (status.jobSHA256 !== jobSHA256 || status.jobID !== job.id) throw Error('Job identity mismatch');
  if (status.phase === 'completed') await verifyBatchResult(resultFolder,jobSHA256);
  const sources = [['job.json',path.join(jobFolder,'job.json')],['status.json',path.join(resultFolder,'status.json')]];
  if (status.phase === 'completed') sources.push(['result.json',path.join(resultFolder,'result.json')],['settings.json',path.join(resultFolder,'settings.json')]);
  const buffers = new Map();
  for (const [name,file] of sources) buffers.set(name,await regular(file));
  const base = derive(jobBytes,statusBytes,buffers.get('result.json'),buffers.get('settings.json'));
  const artifacts = [...buffers].map(([path,bytes])=>({path,bytes:bytes.length,sha256:digest(bytes)}));
  const directory = path.join(archiveRoot,job.id);
  if (await exists(directory)) {
    const {manifest} = await verifyRun(directory);
    const {archivedAt:_,artifacts:prior,...priorBase} = manifest;
    if (!isDeepStrictEqual(priorBase,base) || !isDeepStrictEqual(prior,artifacts)) throw Error('Existing run ID conflict; not overwritten');
    return {id:job.id,directory};
  }
  await mkdir(archiveRoot,{recursive:true,mode:0o700});
  const staging = path.join(archiveRoot,`.partial-${randomUUID()}`);
  await mkdir(staging,{mode:0o700});
  try {
    for (const [name,bytes] of buffers) await writeFile(path.join(staging,name),bytes,{flag:'wx',mode:0o600});
    await writeFile(path.join(staging,'run.json'),JSON.stringify({...base,archivedAt:new Date().toISOString(),artifacts},null,2)+'\n',{flag:'wx',mode:0o600});
    await verifyRun(staging);
    await rename(staging,directory);
  } catch(e) { await rm(staging,{recursive:true,force:true}); throw e; }
  return {id:job.id,directory};
}

export async function verifyRun(directory) {
  const dirInfo = await lstat(directory);
  if (!dirInfo.isDirectory() || dirInfo.isSymbolicLink()) throw Error('Unsafe run directory');
  const bytes = await regular(path.join(directory,'run.json'),2*1024*1024), manifest = json(bytes);
  if (manifest.schema !== 'fox.vision_run.v1' || !Number.isFinite(Date.parse(manifest.archivedAt)) || !Array.isArray(manifest.artifacts)
      || ![2,4].includes(manifest.artifacts.length) || new Set(manifest.artifacts.map(f=>f.path)).size !== manifest.artifacts.length) throw Error('Invalid run manifest');
  const buffers = new Map();
  for (const f of manifest.artifacts) {
    if (!allowed.has(f.path)) throw Error('Unsafe artifact name');
    const data = await regular(path.join(directory,f.path));
    if (data.length !== f.bytes || digest(data) !== f.sha256) throw Error(`Artifact checksum mismatch: ${f.path}`);
    buffers.set(f.path,data);
  }
  if (!buffers.has('job.json') || !buffers.has('status.json')) throw Error('Missing source receipt');
  const derived = derive(buffers.get('job.json'),buffers.get('status.json'),buffers.get('result.json'),buffers.get('settings.json'));
  const {archivedAt:_,artifacts:__,...base} = manifest;
  if (!isDeepStrictEqual(base,derived)) throw Error('Derived manifest differs from source result');
  const status = json(buffers.get('status.json'));
  if (status.phase === 'completed') {
    for (const name of ['result.json','settings.json']) {
      const asset = status.files?.find(f=>f.path === name), data = buffers.get(name);
      if (!asset || !data || asset.bytes !== data.length || asset.sha256 !== digest(data)) throw Error('Source receipt checksum mismatch');
    }
  } else if (buffers.size !== 2) throw Error('Failed run cannot publish completed result');
  return {manifest,manifestSHA256:digest(bytes)};
}

function own(db) {
  if (db.prepare('PRAGMA application_id').get().application_id !== appID || db.prepare('PRAGMA user_version').get().user_version !== 1) throw Error('Foreign or unsupported evidence database');
}
async function openIndex(file) {
  const present = await exists(file);
  if (present) {
    await regular(file,Number.MAX_SAFE_INTEGER);
    const check = new DatabaseSync(file,{readOnly:true});
    try { own(check); } finally { check.close(); }
  } else await mkdir(path.dirname(file),{recursive:true,mode:0o700});
  const db = new DatabaseSync(file);
  db.exec('PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;');
  if (!present) {
    db.exec(`BEGIN; PRAGMA application_id=${appID}; PRAGMA user_version=1;
      CREATE TABLE runs(id TEXT PRIMARY KEY,manifest_sha256 TEXT NOT NULL,status TEXT NOT NULL,acceptance TEXT NOT NULL,evidence_kind TEXT NOT NULL,app_build TEXT,device TEXT,settings_sha256 TEXT,archived_at TEXT NOT NULL);
      CREATE TABLE cases(run_id TEXT REFERENCES runs(id),id TEXT,exercise TEXT,arm TEXT,automatic_count INTEGER,reference_count INTEGER,count_error INTEGER,return_intervals INTEGER,resets INTEGER,PRIMARY KEY(run_id,id));
      CREATE TABLE metrics(run_id TEXT,case_id TEXT,name TEXT,value REAL,PRIMARY KEY(run_id,case_id,name),FOREIGN KEY(run_id,case_id) REFERENCES cases(run_id,id));
      CREATE TABLE artifacts(run_id TEXT REFERENCES runs(id),path TEXT,sha256 TEXT,bytes INTEGER,PRIMARY KEY(run_id,path));
      CREATE INDEX case_exercise ON cases(exercise); COMMIT;`);
    await chmod(file,0o600);
  }
  return db;
}
export async function indexRun(file,directory) {
  const {manifest:m,manifestSHA256:sha} = await verifyRun(directory), db = await openIndex(file);
  try {
    db.exec('BEGIN IMMEDIATE');
    const prior = db.prepare('SELECT manifest_sha256 FROM runs WHERE id=?').get(m.id);
    if (prior) { if (prior.manifest_sha256 !== sha) throw Error('Indexed run ID conflict'); db.exec('COMMIT'); return; }
    db.prepare('INSERT INTO runs VALUES(?,?,?,?,?,?,?,?,?)').run(m.id,sha,m.status,m.acceptance,m.evidenceKind,m.execution.appBuild,m.execution.device,m.settingsSHA256,m.archivedAt);
    for (const c of m.cases) {
      db.prepare('INSERT INTO cases VALUES(?,?,?,?,?,?,?,?,?)').run(m.id,c.id,c.exercise,c.arm,c.automaticCount,c.referenceCount,c.countError,c.returnIntervals,c.resets);
      for (const key of ['automaticCount','referenceCount','countError','returnIntervals','resets']) {
        if (c[key] !== null) db.prepare('INSERT INTO metrics VALUES(?,?,?,?)').run(m.id,c.id,key,c[key]);
      }
    }
    for (const f of m.artifacts) db.prepare('INSERT INTO artifacts VALUES(?,?,?,?)').run(m.id,f.path,f.sha256,f.bytes);
    db.exec('COMMIT');
  } catch(e) { db.exec('ROLLBACK'); throw e; } finally { db.close(); }
}
export async function queryRuns(file,{exercise,build,status,kind,limit=100}={}) {
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 1000) throw Error('Invalid query limit');
  await regular(file,Number.MAX_SAFE_INTEGER);
  const db = new DatabaseSync(file,{readOnly:true});
  try {
    own(db);
    const filters = [['c.exercise',exercise],['r.app_build',build],['r.status',status],['r.evidence_kind',kind]].filter(([,value])=>value !== undefined);
    return db.prepare(`SELECT r.id,r.status,r.acceptance,r.evidence_kind,r.app_build,r.device,r.settings_sha256,c.id AS case_id,c.exercise,c.arm,c.automatic_count,c.reference_count,c.count_error,c.return_intervals,c.resets
      FROM runs r LEFT JOIN cases c ON c.run_id=r.id ${filters.length ? 'WHERE '+filters.map(([column])=>column+'=?').join(' AND ') : ''}
      ORDER BY r.archived_at,r.id,c.id LIMIT ?`).all(...filters.map(([,value])=>value),limit);
  } finally { db.close(); }
}
export async function rebuildIndex(file,archiveRoot) {
  if (await exists(file)) { const db = await openIndex(file); db.close(); }
  const entries = (await readdir(archiveRoot)).filter(name=>!name.startsWith('.')).sort();
  for (const entry of entries) await verifyRun(path.join(archiveRoot,entry));
  const temp = `${file}.rebuild-${randomUUID()}`;
  try {
    const db = await openIndex(temp); db.close();
    for (const entry of entries) await indexRun(temp,path.join(archiveRoot,entry));
    await rename(temp,file);
  } finally { await rm(temp,{force:true}); }
  return {runs:entries.length};
}

async function cli() {
  const [command,...args] = process.argv.slice(2), option = key => args[args.indexOf(key)+1];
  const archiveRoot = args.includes('--runs') ? path.resolve(option('--runs')) : path.join(root,'.data/vision-evidence/runs');
  const db = args.includes('--db') ? path.resolve(option('--db')) : path.join(root,'.data/vision-evidence/index.sqlite');
  if (command === 'capture') {
    if (!args[0] || !args.includes('--job')) throw Error('capture <batch-result-folder> --job <job-folder> [--runs dir] [--db file]');
    const run = await archiveBatch({resultFolder:path.resolve(args[0]),jobFolder:path.resolve(option('--job')),archiveRoot});
    await indexRun(db,run.directory); return run;
  }
  if (command === 'verify') return verifyRun(path.resolve(args[0]));
  if (command === 'rebuild') return rebuildIndex(db,archiveRoot);
  if (command === 'list') return queryRuns(db,Object.fromEntries(['exercise','build','status','kind'].filter(key=>args.includes('--'+key)).map(key=>[key,option('--'+key)])));
  throw Error('Use capture, verify, rebuild or list');
}
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(JSON.stringify(await cli(),null,2)); }
  catch(e) { console.error(e.message); process.exitCode=1; }
}
