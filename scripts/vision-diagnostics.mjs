import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { chmod, copyFile, lstat, mkdir, readFile, rename, rm, statfs, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { selectPairedDevice } from './ios-device-selection.mjs';

const repository = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const allowed = new Set(['context.json', 'frames.jsonl', 'poses.jsonl', 'events.jsonl', 'video.mp4', 'video.partial.mp4', 'review.json']);
const json = async p => JSON.parse(await readFile(p, 'utf8'));
const finite = value => Number.isFinite(value);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');

export function validateManifest(m) {
  if (m.schema !== 'fox.vision_diagnostic_manifest.v1' || !uuid.test(m.id ?? '')
      || !['camera', 'fixture'].includes(m.source) || !['complete', 'interrupted', 'failed'].includes(m.state)
      || !Number.isFinite(Date.parse(m.startedAt)) || !Number.isFinite(Date.parse(m.endedAt))
      || Date.parse(m.endedAt) < Date.parse(m.startedAt) || typeof m.stopReason !== 'string' || !m.stopReason.length
      || !Array.isArray(m.files) || !m.files.length || m.files.length > allowed.size) throw Error('Invalid or unsealed diagnostic manifest');
  if (m.storagePolicy != null && (m.storagePolicy !== 'temporary-until-review'
      || !Number.isFinite(Date.parse(m.retainedAt)) || Date.parse(m.retainedAt) < Date.parse(m.endedAt))) {
    throw Error('Temporary diagnostic has not been retained after review');
  }
  const paths = new Set(); let bytes = 0;
  for (const file of m.files) {
    if (!allowed.has(file.path) || paths.has(file.path) || !Number.isSafeInteger(file.bytes) || file.bytes < 0
        || !/^[a-f0-9]{64}$/.test(file.sha256 ?? '')) throw Error('Unsafe, duplicate or invalid diagnostic asset');
    paths.add(file.path); bytes += file.bytes;
  }
  if (!paths.has('context.json') || bytes > 256 * 1024 * 1024) throw Error('Missing context or diagnostic package exceeds 256 MiB');
  if (m.video != null) {
    const v = m.video;
    if (v.path !== 'video.mp4' || !paths.has(v.path) || v.audio !== false || v.codec !== 'h264'
        || ![v.firstCapturePTS, v.lastCapturePTS].every(finite) || v.lastCapturePTS < v.firstCapturePTS
        || v.lastCapturePTS - v.firstCapturePTS > 300.1
        || ![v.width, v.height, v.encodedFrames].every(n => Number.isSafeInteger(n) && n > 0)
        || v.width > 4096 || v.height > 4096 || !Number.isSafeInteger(v.droppedFrames) || v.droppedFrames < 0) throw Error('Invalid video timeline or format');
  } else if (m.state === 'complete') throw Error('A complete package requires a finalized video');
  return { bytes, files: m.files.length, videoAvailable: m.video != null };
}

export async function digestFile(name) {
  const info = await lstat(name);
  if (!info.isFile() || info.isSymbolicLink()) throw Error('Diagnostic asset must be a regular file, not a symlink');
  const digest = createHash('sha256');
  for await (const data of createReadStream(name)) digest.update(data);
  return { bytes: info.size, sha256: digest.digest('hex') };
}

export async function verifyPackage(folder) {
  const info = await lstat(folder);
  if (!info.isDirectory() || info.isSymbolicLink()) throw Error('Diagnostic package must be a regular directory');
  const manifestInfo = await lstat(path.join(folder, 'manifest.json'));
  if (!manifestInfo.isFile() || manifestInfo.isSymbolicLink() || manifestInfo.size > 128 * 1024) throw Error('Unsafe manifest file');
  const manifestBytes = await readFile(path.join(folder, 'manifest.json'));
  const manifest = JSON.parse(manifestBytes), summary = validateManifest(manifest);
  for (const file of manifest.files) {
    const info = await lstat(path.join(folder, file.path));
    if (!info.isFile() || info.isSymbolicLink()) throw Error('Diagnostic asset must be a regular file, not a symlink');
    if (info.size !== file.bytes) throw Error(`Asset checksum/size mismatch: ${file.path}`);
    const actual = await digestFile(path.join(folder, file.path));
    if (actual.bytes !== file.bytes || actual.sha256 !== file.sha256) throw Error(`Asset checksum/size mismatch: ${file.path}`);
  }
  const context = await json(path.join(folder, 'context.json'));
  if (context.schema !== 'fox.vision_diagnostic_context.v1' || context.id !== manifest.id || context.source !== manifest.source
      || context.audio !== false || !['curl', 'lateralRaise', 'latPulldown'].includes(context.exercise)
      || !['left', 'right'].includes(context.arm) || !['front', 'back'].includes(context.camera)
      || context.visionRevision !== 1 || context.configuration?.schema !== 'fox.pose_counter_configuration.v1'
      || context.runtimePolicy?.schema !== 'fox.pose_runtime_policy.v1') throw Error('Context does not match package');
  if (manifest.files.some(f => f.path === 'review.json')) {
    const review = await json(path.join(folder, 'review.json'));
    if (review.schema !== 'fox.diagnostic_review.v1' || review.diagnosticID !== manifest.id
        || !finite(Date.parse(review.reviewedAt)) || Date.parse(review.reviewedAt) < Date.parse(manifest.endedAt)
        || (review.referenceCount != null && (!Number.isSafeInteger(review.referenceCount) || review.referenceCount < 0 || review.referenceCount > 10000))) {
      throw Error('Review does not match diagnostic package');
    }
    if (review.review != null) {
      const r = review.review, values = [r.information, r.softwareIssue, r.trainingFeeling].filter(v => v != null);
      if (r.schema !== 'fox.trial_review.v1' || !finite(Date.parse(r.recordedAt)) || !values.length
          || values.some(v => typeof v !== 'string' || !v.length || [...v].length > 4000 || v !== v.trim())) throw Error('Review categories are invalid');
    }
  }
  return { manifest, manifestSHA256: hash(manifestBytes), ...summary };
}

export async function importPackage(folder, destination, { transport = 'manual-file', inspectVideo = false } = {}) {
  const verified = await verifyPackage(folder), id = verified.manifest.id.toUpperCase();
  await mkdir(destination, { recursive: true, mode: 0o700 });
  const final = path.join(destination, id);
  let present = false;
  try { await lstat(final); present = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (present) {
    const existing = await verifyPackage(final);
    if (existing.manifestSHA256 !== verified.manifestSHA256) throw Error('Existing diagnostic ID has different content; not overwritten');
    return { status: 'already-received', directory: final, ...existing };
  }
  if (inspectVideo && verified.videoAvailable) {
    const result = spawnSync('ffprobe', ['-v', 'error', '-show_streams', '-show_format', '-of', 'json', path.join(folder, 'video.mp4')], { encoding: 'utf8', timeout: 30000, maxBuffer: 1024 * 1024 });
    if (result.error || result.status !== 0) throw Error('Video inspection failed; install ffprobe or inspect the incomplete package manually');
    const media = JSON.parse(result.stdout), streams = media.streams ?? [], videos = streams.filter(s => s.codec_type === 'video');
    const v = verified.manifest.video;
    if (videos.length !== 1 || streams.some(s => s.codec_type === 'audio') || videos[0].codec_name !== 'h264'
        || videos[0].width !== v.width || videos[0].height !== v.height) throw Error('Actual video streams disagree with manifest');
    const start = Number(videos[0].start_time ?? media.format?.start_time), duration = Number(media.format?.duration);
    if (!finite(start) || Math.abs(start) > 0.1 || !finite(duration) || duration <= 0 || duration > 301
        || Math.abs(duration - (v.lastCapturePTS - v.firstCapturePTS)) > 0.5) throw Error('Actual video timebase disagrees with capture PTS');
  }
  const staging = path.join(destination, `${id}.partial-${randomUUID()}`);
  await mkdir(staging, { mode: 0o700 });
  try {
    for (const name of ['manifest.json', ...verified.manifest.files.map(f => f.path)]) {
      await copyFile(path.join(folder, name), path.join(staging, name)); await chmod(path.join(staging, name), 0o600);
    }
    const copied = await verifyPackage(staging);
    if (copied.manifestSHA256 !== verified.manifestSHA256) throw Error('Manifest changed during transfer');
    await writeFile(path.join(staging, 'receipt.json'), JSON.stringify({ schema: 'fox.vision_diagnostic_receipt.v1',
      receivedAt: new Date().toISOString(), transport, id, manifestSHA256: copied.manifestSHA256,
      source: copied.manifest.source, videoAvailable: copied.videoAvailable,
      retention: copied.manifest.retainedAt ? 'kept-after-review' : 'legacy-package',
      evidenceBoundary: 'Captured diagnostic package, not human labels or fitness acceptance' }, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    await rename(staging, final);
    return { status: 'received-and-verified', directory: final, ...copied };
  } catch (error) { await rm(staging, { recursive: true, force: true }); throw error; }
}

export function remotePackages(files) {
  return files.filter(f => typeof f.relativePath === 'string' && f.relativePath.endsWith('/manifest.json')
    && f.relativePath.split('/').length === 2 && uuid.test(f.relativePath.split('/')[0])
    && f.resources?.isSymbolicLink !== true && f.resources?.isDirectory === false)
    .sort((a, b) => Date.parse(b.metadata?.lastModDate ?? '') - Date.parse(a.metadata?.lastModDate ?? ''));
}

async function runCLI() {
  const [command, ...args] = process.argv.slice(2);
  const option = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
  const inbox = path.resolve(option('--destination') ?? path.join(repository, '.data/vision-diagnostics/inbox'));
  if (command === 'import') {
    if (!args[0] || args[0].startsWith('--')) throw Error('Usage: vision:import -- <exported-folder> [--destination <private-directory>]');
    return importPackage(path.resolve(args[0]), inbox, { inspectVideo: true });
  }
  if (command !== 'pull') throw Error('Expected pull or import');
  const work = path.join(repository, '.tmp', 'vision-diagnostic-pull', randomUUID());
  await mkdir(work, { recursive: true, mode: 0o700 });
  const tool = async (tail, output) => {
    const p = path.join(work, output);
    const result = spawnSync('xcrun', ['devicectl', ...tail, '--quiet', '--timeout', '120', '--json-output', p], {
      env: { ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer' },
      encoding: 'utf8', timeout: 130000, maxBuffer: 1024 * 1024 });
    if (result.error || result.status !== 0) throw Error(`Device transfer failed; check pairing, connection and unlock state. ${result.stderr ?? result.error?.message ?? ''}`);
    const data = await json(p);
    if (data.info?.outcome !== 'success') throw Error('Device tool did not confirm success');
    return data.result;
  };
  const listed = await tool(['list', 'devices'], 'devices.json');
  const selected = selectPairedDevice(listed.devices ?? [], { selector: process.env.FOX_IOS_DEVICE, family: 'iPad' });
  if (selected.hardwareProperties?.deviceType !== 'iPad') throw Error('Diagnostic pull targets an iPad; check FOX_IOS_DEVICE');
  const device = selected.identifier;
  const domain = ['--device', device, '--domain-type', 'appDataContainer', '--domain-identifier', 'com.whipa.fox'];
  const remoteRoot = args.includes('--fixtures') ? 'Documents/FoxDiagnosticsFixtures' : 'Documents/FoxDiagnostics';
  const documents = await tool(['device', 'info', 'files', ...domain, '--subdirectory', 'Documents', '--no-recurse'], 'documents.json');
  if (!(documents.files ?? []).some(f => f.name === remoteRoot.split('/')[1] && f.resources?.isDirectory === true && f.resources?.isSymbolicLink !== true)) {
    throw Error('No retained diagnostics yet. After reviewing in Fox, choose Keep Diagnostic; temporary clips are not transferred.');
  }
  const listing = await tool(['device', 'info', 'files', ...domain, '--subdirectory', remoteRoot, '--recurse'], 'files.json');
  const packages = remotePackages(listing.files ?? []), id = option('--id');
  if (id && !uuid.test(id)) throw Error('Invalid diagnostic ID');
  const entry = id ? packages.find(p => p.relativePath.split('/')[0].toUpperCase() === id.toUpperCase()) : packages[0];
  if (!entry) throw Error('No sealed diagnostic package found; finish recording first. No files were deleted.');
  const source = `${remoteRoot}/${entry.relativePath.split('/')[0]}`;
  const staging = path.join(work, 'package'); await mkdir(staging, { mode: 0o700 });
  await tool(['device', 'copy', 'from', ...domain, '--source', `${source}/manifest.json`, '--destination', path.join(staging, 'manifest.json')], 'manifest-copy.json');
  const m = await json(path.join(staging, 'manifest.json')), summary = validateManifest(m);
  if (m.source !== (args.includes('--fixtures') ? 'fixture' : 'camera')) throw Error('Unexpected diagnostic source for this container');
  if (m.id.toUpperCase() !== entry.relativePath.split('/')[0].toUpperCase()) throw Error('Remote ID mismatch');
  await mkdir(inbox, { recursive: true, mode: 0o700 });
  const fs = await statfs(inbox);
  if (fs.bavail * fs.bsize < summary.bytes * 2 + 64 * 1024 * 1024) throw Error('Insufficient Mac space for verified staging and import');
  for (const file of m.files) {
    await tool(['device', 'copy', 'from', ...domain, '--source', `${source}/${file.path}`, '--destination', path.join(staging, file.path)], `${file.path}-copy.json`);
  }
  const result = await importPackage(staging, inbox, { transport: 'paired-coredevice', inspectVideo: true });
  await rm(staging, { recursive: true, force: true });
  return result;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const result = await runCLI();
    console.log(JSON.stringify({ status: result.status, directory: result.directory, id: result.manifest.id,
      state: result.manifest.state, source: result.manifest.source, videoAvailable: result.videoAvailable, bytes: result.bytes }, null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
