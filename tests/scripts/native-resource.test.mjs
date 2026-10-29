import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import * as admission from '../../scripts/native-resource.mjs';
import {acquireSimulatorSession, releaseSimulatorSession, root, developerDir} from '../../scripts/development-environment.mjs';

async function fixture(t) {
  const home = await mkdtemp(path.join(tmpdir(), 'fox-resource-'));
  t.after(() => rm(home, {recursive: true, force: true}));
  return {home, directory: path.join(home, '.cache/fox/simulator-session')};
}

test('public replay commands enter the same native resource wrapper', async () => {
  const pkg = JSON.parse(await readFile(new URL('../../package.json', import.meta.url)));
  for (const name of ['vision:replay', 'vision:video']) {
    assert.match(pkg.scripts[name], /^node scripts\/native-resource\.mjs run -- xcrun swift run /);
    assert.match(pkg.scripts[name], /--jobs 2 /);
  }
});

test('legacy simulator holder blocks native admission without changing its bytes', async t => {
  const {directory} = await fixture(t);
  const legacy = acquireSimulatorSession(directory);
  const before = await readFile(path.join(directory, 'owner.json'));
  await assert.rejects(admission.acquireNativeResource({directory, purpose: 'host tests', waitMs: 0}), /busy/);
  assert.deepEqual(await readFile(path.join(directory, 'owner.json')), before);
  releaseSimulatorSession(legacy);
});

test('bounded waiter acquires only after legacy release and records waiting', async t => {
  const {directory} = await fixture(t), legacy = acquireSimulatorSession(directory);
  const waiting = admission.acquireNativeResource({directory, purpose: 'host tests', waitMs: 1000});
  setTimeout(() => releaseSimulatorSession(legacy), 60);
  const claim = await waiting;
  assert.equal(claim.owned, true);
  assert.ok(claim.waitMs >= 50);
  assert.equal(JSON.parse(await readFile(path.join(directory, 'owner.json'))).purpose, 'host tests');
  admission.releaseNativeResource(claim);
});

test('wait cancellation and timeout never steal a holder or spawn work', async t => {
  const {directory} = await fixture(t), legacy = acquireSimulatorSession(directory);
  const controller = new AbortController();
  const waiting = admission.acquireNativeResource({directory, waitMs: 1000, signal: controller.signal});
  controller.abort();
  await assert.rejects(waiting, /abort|cancel/i);
  await assert.rejects(admission.acquireNativeResource({directory, waitMs: 20}), /busy/);
  assert.equal(JSON.parse(await readFile(path.join(directory, 'owner.json'))).token, legacy.token);
  releaseSimulatorSession(legacy);
});

test('inheritance checks token root and toolchain and never releases the parent claim', async t => {
  const {directory} = await fixture(t), legacy = acquireSimulatorSession(directory);
  for (const override of [{token: 'wrong'}, {expectedRoot: '/different-tree'}, {expectedDeveloperDir: '/different-xcode'}]) {
    await assert.rejects(admission.acquireNativeResource({directory, token: legacy.token, ...override}), /mismatch/);
  }
  const inherited = await admission.acquireNativeResource({directory, token: legacy.token, expectedRoot: root, expectedDeveloperDir: developerDir});
  assert.equal(inherited.owned, false);
  admission.releaseNativeResource(inherited);
  assert.equal(JSON.parse(await readFile(path.join(directory, 'owner.json'))).token, legacy.token);
  releaseSimulatorSession(legacy);
});

test('admitted execution rejects nesting under a parent instead of detaching grandchildren', async t => {
  const {home, directory} = await fixture(t), parent = acquireSimulatorSession(directory);
  try {
    await assert.rejects(admission.executeAdmitted({command: process.execPath, args: ['-e', 'console.log("SHOULD_NOT_RUN")'],
      env: {FOX_SIMULATOR_SESSION_TOKEN: parent.token}}, {logPath: path.join(home, 'nested.log')}, {directory}), /nested|nesting/i);
    await assert.rejects(readFile(path.join(home, 'nested.log')), /ENOENT/);
    assert.equal(JSON.parse(await readFile(path.join(directory, 'owner.json'))).token, parent.token);
  } finally { releaseSimulatorSession(parent); }
});

test('malformed or dead owner is diagnostic only and never automatically reclaimed', async t => {
  const {directory} = await fixture(t), legacy = acquireSimulatorSession(directory);
  const file = path.join(directory, 'owner.json');
  const owner = JSON.parse(await readFile(file));
  owner.pid = 2147483647;
  await writeFile(file, JSON.stringify(owner));
  assert.equal(admission.nativeResourceStatus(directory).ownerAlive, false);
  await assert.rejects(admission.acquireNativeResource({directory, waitMs: 0}), /busy/);
  await assert.rejects(admission.acquireNativeResource({directory, token: legacy.token}), /alive/);
  await writeFile(file, '{');
  assert.equal(admission.nativeResourceStatus(directory).state, 'unknown');
  await assert.rejects(admission.acquireNativeResource({directory, waitMs: 0}), /busy/);
});

test('admission validates budget before touching the lock', async t => {
  const {directory} = await fixture(t);
  for (const waitMs of [-1, NaN, Infinity, 1.5, 3600001, '10']) {
    await assert.rejects(admission.acquireNativeResource({directory, waitMs}), /wait/i);
  }
  assert.equal(admission.nativeResourceStatus(directory).state, 'free');
});

test('bounded Swift jobs and per-worktree external cache never silently use arbitrary names', () => {
  assert.equal(admission.swiftJobs('2'), 2);
  for (const value of ['0', '20', 'auto', '-1']) assert.throws(() => admission.swiftJobs(value));
  assert.throws(() => admission.nativeScratchPath('../outside'));
  const old = process.env.FOX_BUILD_CACHE_ROOT;
  try {
    process.env.FOX_BUILD_CACHE_ROOT = '/external/cache';
    assert.match(admission.nativeScratchPath('journal-core-build'), /^\/external\/cache\/[0-9a-f]{16}\/journal-core-build$/);
  } finally {
    if (old === undefined) delete process.env.FOX_BUILD_CACHE_ROOT;
    else process.env.FOX_BUILD_CACHE_ROOT = old;
  }
});

test('independent process cannot enter a native resource held by another worktree', async t => {
  const {home, directory} = await fixture(t), legacy = acquireSimulatorSession(directory);
  const result = spawnSync(process.execPath, ['scripts/native-resource.mjs', 'run', '--', process.execPath, '-e', 'console.log("MUST_NOT_RUN")'], {
    cwd: root, env: {...process.env, HOME: home, FOX_SIMULATOR_SESSION_TOKEN: '', FOX_NATIVE_WAIT_MS: '0'}, encoding: 'utf8', timeout: 5000});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /busy/);
  assert.doesNotMatch(result.stdout, /MUST_NOT_RUN/);
  assert.equal(JSON.parse(await readFile(path.join(directory, 'owner.json'))).token, legacy.token);
  releaseSimulatorSession(legacy);
});

test('admitted command failure keeps evidence and releases its own claim', async t => {
  const {home, directory} = await fixture(t);
  const log = path.join(home, 'failure.log');
  const result = await admission.executeAdmitted({id: 'fixture', command: process.execPath,
    args: ['-e', 'console.log("partial"); process.exit(3)']}, {logPath: log}, {directory});
  assert.equal(result.code, 3);
  assert.match(await readFile(log, 'utf8'), /partial/);
  assert.equal(admission.nativeResourceStatus(directory).state, 'free');
  assert.equal(result.resourceAdmission.owned, true);
  assert.equal(result.resourceAdmission.status, 'released');
});

for (const detached of [false, true]) test(`cancelled admitted command kills resistant descendants (detached=${detached}) before freeing the claim`, {timeout: 12000}, async t => {
  const {home, directory} = await fixture(t), pidfile = path.join(home, 'descendant');
  const controller = new AbortController();
  const descendant = `process.on('SIGTERM',()=>{}); require('fs').writeFileSync(${JSON.stringify(pidfile)},String(process.pid));setInterval(()=>{},1000)`;
  const code = `require('child_process').spawn(process.execPath,['-e',${JSON.stringify(descendant)}],{stdio:'ignore',detached:${detached}});setInterval(()=>{},1000)`;
  const running = admission.executeAdmitted({command: process.execPath, args: ['-e', code]},
    {logPath: path.join(home, 'cancel.log'), signal: controller.signal}, {directory});
  let pid;
  const deadline = Date.now() + 3000;
  while (!pid && Date.now() < deadline) {
    try { pid = Number(await readFile(pidfile, 'utf8')); } catch { await new Promise(r => setTimeout(r, 20)); }
  }
  t.after(() => { if (pid) { try { process.kill(pid, 'SIGKILL'); } catch {} } });
  assert.ok(pid, 'fixture descendant started');
  await new Promise(r => setTimeout(r, 500));
  controller.abort();
  await assert.rejects(running, /cancel/i);
  const status = spawnSync('ps', ['-o', 'stat=', '-p', String(pid)], {encoding: 'utf8'}).stdout.trim();
  assert.ok(!status || status.startsWith('Z'), status);
  assert.equal(admission.nativeResourceStatus(directory).state, 'free');
});
