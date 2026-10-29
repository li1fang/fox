import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync, mkdirSync, writeFileSync, realpathSync, rmSync, symlinkSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {initializeStorage, storagePath} from '../../scripts/storage-paths.mjs';

function fixture(t) {
  const base = realpathSync(mkdtempSync(path.join(os.tmpdir(), 'fox-storage-')));
  t.after(() => rmSync(base, {recursive:true, force:true}));
  const volume = path.join(base, 'volume'); mkdirSync(volume);
  const options = {configPath:path.join(base, 'config.json'), isMounted: p => p === volume};
  return {base, volume, options};
}

test('no profile preserves compatibility and per-worktree profiles separate caches', t => {
  const {base, volume, options} = fixture(t);
  assert.equal(storagePath('cache', 'core', '/repo/a', options), '/repo/a/.tmp/core');
  initializeStorage(volume, 'FoxWorkspace', options);
  const a = storagePath('cache', 'core', '/repo/a', options), b = storagePath('cache', 'core', '/repo/b', options);
  assert.notEqual(a, b);
  assert.ok(a.startsWith(path.join(volume, 'FoxWorkspace', 'cache')));
  assert.ok(storagePath('evidence', 'run', '/repo/a', options).startsWith(volume));
  assert.ok(storagePath('downloads', 'frame.bin', '/repo/a', options).startsWith(volume));
  assert.throws(() => initializeStorage(volume, 'Another', options), /exist/);
});

test('unmounted volume or changed marker cannot silently fall back to internal disk', t => {
  const {volume, options} = fixture(t);
  initializeStorage(volume, 'FoxWorkspace', options);
  assert.throws(() => storagePath('cache', 'core', '/repo', {...options,isMounted:()=>false}), /mount/);
  writeFileSync(path.join(volume, 'FoxWorkspace', '.fox-storage-id'), 'wrong');
  assert.throws(() => storagePath('cache', 'core', '/repo', options), /identity/);
});

test('path escape symlinks malformed profiles and non-mounted initialization fail', t => {
  const {base, volume, options} = fixture(t);
  assert.throws(() => initializeStorage(volume, '../outside', options));
  assert.throws(() => initializeStorage(volume, 'FoxWorkspace', {...options,isMounted:()=>false}));
  initializeStorage(volume, 'FoxWorkspace', options);
  assert.throws(() => storagePath('cache', '../outside', '/repo', options));
  symlinkSync(base, path.join(volume, 'FoxWorkspace', 'cache'));
  assert.throws(() => storagePath('cache', 'core', '/repo', options), /symlink/);
  writeFileSync(options.configPath, JSON.stringify({schema:'unknown'}));
  assert.throws(() => storagePath('cache', 'core', '/repo', options));
});

test('absent config under a system home alias keeps compatibility, dangling config does not', t => {
  const {base, options} = fixture(t);
  const alias = path.join(base, 'home-alias'); symlinkSync(base, alias);
  assert.equal(storagePath('cache', 'core', '/repo', {...options, configPath:path.join(alias, 'absent.json')}), '/repo/.tmp/core');
  symlinkSync(path.join(base, 'missing-target'), options.configPath);
  assert.throws(() => storagePath('cache', 'core', '/repo', options), /symlink/);
});

test('trailing volume separator is normalized before profile publication', t => {
  const {volume, options} = fixture(t);
  initializeStorage(volume+'/', 'FoxWorkspace', {...options,isMounted:p=>p.replace(/\/$/,'')===volume});
  assert.ok(storagePath('cache', 'core', '/repo', options).startsWith(volume));
});
