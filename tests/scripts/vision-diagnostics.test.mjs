import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { mkdtemp, writeFile, readFile, mkdir, readdir, rm, symlink, unlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { validateManifest, verifyPackage, importPackage, remotePackages } from '../../scripts/vision-diagnostics.mjs';

async function fixture(t) {
  const root = await mkdtemp(path.join(tmpdir(), 'fox-diagnostic-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const folder = path.join(root, 'source'), inbox = path.join(root, 'inbox'); await mkdir(folder);
  const id = randomUUID().toUpperCase();
  const context = { schema: 'fox.vision_diagnostic_context.v1', id, source: 'fixture', audio: false,
    exercise: 'curl', arm: 'left', camera: 'front', visionRevision: 1,
    configuration: { schema: 'fox.pose_counter_configuration.v1' }, runtimePolicy: { schema: 'fox.pose_runtime_policy.v1' } };
  const bytes = Buffer.from(JSON.stringify(context)); await writeFile(path.join(folder, 'context.json'), bytes);
  const manifest = { schema: 'fox.vision_diagnostic_manifest.v1', id, source: 'fixture', state: 'failed',
    startedAt: '2026-10-17T00:00:00Z', endedAt: '2026-10-17T00:00:10Z', stopReason: 'neverStarted',
    files: [{ path: 'context.json', bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') }] };
  const save = () => writeFile(path.join(folder, 'manifest.json'), JSON.stringify(manifest)); await save();
  return { root, folder, inbox, context, manifest, save };
}
test('metadata-only failed starts can be verified and imported without fabricating video', async t => {
  const f = await fixture(t), result = await importPackage(f.folder, f.inbox);
  assert.equal(result.status, 'received-and-verified'); assert.equal(result.videoAvailable, false);
  assert.equal(result.manifest.state, 'failed');
  assert.equal(JSON.parse(await readFile(path.join(result.directory, 'receipt.json'))).source, 'fixture');
});

test('lat pulldown diagnostics remain importable with post-review annotations', async t => {
  const f = await fixture(t);
  f.context.exercise = 'latPulldown';
  const context = Buffer.from(JSON.stringify(f.context));
  await writeFile(path.join(f.folder, 'context.json'), context);
  f.manifest.files[0] = { path: 'context.json', bytes: context.length, sha256: createHash('sha256').update(context).digest('hex') };
  const review = { schema: 'fox.diagnostic_review.v1', diagnosticID: f.manifest.id, reviewedAt: '2026-10-17T00:00:12Z',
    referenceCount: 5, review: { schema: 'fox.trial_review.v1', recordedAt: '2026-10-17T00:00:12Z', softwareIssue: '提示太密' } };
  const bytes = Buffer.from(JSON.stringify(review));
  await writeFile(path.join(f.folder, 'review.json'), bytes);
  f.manifest.files.push({ path: 'review.json', bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
  await f.save();
  const result = await importPackage(f.folder, f.inbox);
  assert.equal(result.status, 'received-and-verified');
  assert.deepEqual(JSON.parse(await readFile(path.join(result.directory, 'review.json'))), review);
  assert.equal((await importPackage(f.folder, f.inbox)).status, 'already-received');
});

test('a review with a mismatched diagnostic ID is rejected even with valid checksum', async t => {
  const f = await fixture(t);
  const bytes = Buffer.from(JSON.stringify({ schema: 'fox.diagnostic_review.v1', diagnosticID: randomUUID(),
    reviewedAt: '2026-10-17T00:00:12Z', referenceCount: 5 }));
  await writeFile(path.join(f.folder, 'review.json'), bytes);
  f.manifest.files.push({ path: 'review.json', bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
  await f.save();
  await assert.rejects(verifyPackage(f.folder), /Review/);
});
test('duplicate import is idempotent and does not replace its receipt', async t => {
  const f = await fixture(t), first = await importPackage(f.folder, f.inbox);
  const receipt = await readFile(path.join(first.directory, 'receipt.json'));
  assert.equal((await importPackage(f.folder, f.inbox)).status, 'already-received');
  assert.deepEqual(await readFile(path.join(first.directory, 'receipt.json')), receipt);
});
test('same ID changed content conflicts rather than overwriting', async t => {
  const f = await fixture(t), first = await importPackage(f.folder, f.inbox);
  f.manifest.stopReason = 'different'; await f.save();
  await assert.rejects(importPackage(f.folder, f.inbox), /different content/);
  assert.equal(JSON.parse(await readFile(path.join(first.directory, 'manifest.json'))).stopReason, 'neverStarted');
});
test('corrupted source file and missing assets are rejected', async t => {
  const f = await fixture(t); await writeFile(path.join(f.folder, 'context.json'), 'corrupted');
  await assert.rejects(verifyPackage(f.folder), /checksum\/size/);
  await unlink(path.join(f.folder, 'context.json'));
  await assert.rejects(importPackage(f.folder, f.inbox), /ENOENT/);
});
test('path traversal, duplicate assets and oversized packages are rejected before copy', async t => {
  const f = await fixture(t), m = structuredClone(f.manifest);
  m.files[0].path = '../context.json'; assert.throws(() => validateManifest(m), /Unsafe/);
  m.files = [f.manifest.files[0], f.manifest.files[0]]; assert.throws(() => validateManifest(m), /duplicate/);
  m.files = [{ ...f.manifest.files[0], bytes: 257 * 1024 * 1024 }]; assert.throws(() => validateManifest(m), /exceeds/);
});
test('symlinked files, package directories and manifests are rejected', async t => {
  const f = await fixture(t), outside = path.join(f.root, 'outside');
  await writeFile(outside, await readFile(path.join(f.folder, 'context.json')));
  await unlink(path.join(f.folder, 'context.json')); await symlink(outside, path.join(f.folder, 'context.json'));
  await assert.rejects(verifyPackage(f.folder), /symlink/);
  const link = path.join(f.root, 'linked'); await symlink(f.folder, link);
  await assert.rejects(verifyPackage(link), /regular directory/);
  await unlink(path.join(f.folder, 'manifest.json')); await symlink(outside, path.join(f.folder, 'manifest.json'));
  await assert.rejects(verifyPackage(f.folder), /Unsafe manifest/);
});
test('unfinished manifests and complete-without-video cannot be accepted', async t => {
  const f = await fixture(t); f.manifest.state = 'recording';
  assert.throws(() => validateManifest(f.manifest), /unsealed/);
  f.manifest.state = 'complete'; assert.throws(() => validateManifest(f.manifest), /requires/);
});
test('temporary packets cannot be imported before an explicit post-review retention', async t => {
  const f = await fixture(t); f.manifest.storagePolicy = 'temporary-until-review'; await f.save();
  await assert.rejects(importPackage(f.folder, f.inbox), /not been retained/);
  f.manifest.retainedAt = '2026-10-17T00:00:11Z'; await f.save();
  assert.equal((await importPackage(f.folder, f.inbox)).status, 'received-and-verified');
});
test('unsupported video timeline, audio and formats cannot claim accepted video', async t => {
  const f = await fixture(t), m = structuredClone(f.manifest);
  m.files.push({ path: 'video.mp4', bytes: 1, sha256: 'a'.repeat(64) });
  m.state = 'complete'; m.video = { path: 'video.mp4', codec: 'h264', audio: false,
    width: 720, height: 1280, firstCapturePTS: 100, lastCapturePTS: 102, encodedFrames: 20, droppedFrames: 0 };
  assert.equal(validateManifest(m).videoAvailable, true);
  m.video.audio = true; assert.throws(() => validateManifest(m), /format/);
  m.video.audio = false; m.video.lastCapturePTS = 99; assert.throws(() => validateManifest(m), /timeline/);
});
test('source mismatch between context and manifest is not relabeled as camera evidence', async t => {
  const f = await fixture(t); f.manifest.source = 'camera'; await f.save();
  await assert.rejects(verifyPackage(f.folder), /Context/);
});
test('a corrupted existing import is not silently called already received or overwritten', async t => {
  const f = await fixture(t), first = await importPackage(f.folder, f.inbox);
  await unlink(path.join(first.directory, 'context.json'));
  await assert.rejects(importPackage(f.folder, f.inbox), /ENOENT/);
  assert.deepEqual(await readdir(f.inbox), [f.manifest.id]);
});
test('remote listing ignores active, unrelated and unsafe paths', () => {
  const id = randomUUID().toUpperCase();
  const file = relativePath => ({ relativePath, resources: { isDirectory: false, isSymbolicLink: false }, metadata: { lastModDate: '2026-10-17T00:00:00Z' } });
  assert.deepEqual(remotePackages([file(`${id}/manifest.json`), file(`${id}/status`), file('../manifest.json'), file(`nested/${id}/manifest.json`),
    { ...file(`${id}/manifest.json`), resources: { isSymbolicLink: true } }]).map(f => f.relativePath), [`${id}/manifest.json`]);
});
