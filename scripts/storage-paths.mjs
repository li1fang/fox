import {createHash, randomUUID} from 'node:crypto';
import {existsSync, lstatSync, mkdirSync, readFileSync, statSync, writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const defaultConfig = () => process.env.FOX_STORAGE_CONFIG ?? path.join(homedir(), '.config/fox/storage.json');
const mounted = volume => existsSync(volume) && statSync(volume).isDirectory() && statSync(volume).dev !== statSync(path.dirname(volume)).dev;
const assert = (ok, message) => { if (!ok) throw Error(`storage_failure: ${message}`); };
function noLinks(target) {
  for (let p = target; ; p = path.dirname(p)) {
    assert(!existsSync(p) || !lstatSync(p).isSymbolicLink(), `symlink path: ${p}`);
    // lstat also detects dangling links, unlike existsSync.
    try { assert(!lstatSync(p).isSymbolicLink(), `symlink path: ${p}`); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (p === path.dirname(p)) break;
  }
}
function component(value) {
  assert(typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(value), 'invalid path component');
}

export function initializeStorage(volume, name = 'FoxWorkspace', {configPath = defaultConfig(), isMounted = mounted} = {}) {
  component(name);
  assert(path.isAbsolute(volume) && path.resolve(volume) !== '/', 'expected absolute volume');
  volume = path.resolve(volume);
  noLinks(volume);
  assert(isMounted(volume), 'volume is not mounted; nothing created');
  noLinks(configPath);
  assert(!existsSync(configPath), 'config already exists; inspect before changing');
  const root = path.join(volume, name);
  noLinks(root);
  assert(!existsSync(root), 'storage directory already exists; inspect before adopting');
  mkdirSync(root, {mode:0o700});
  const marker = randomUUID();
  writeFileSync(path.join(root, '.fox-storage-id'), marker, {flag:'wx', mode:0o600});
  const profile = {schema:'fox.storage_paths.v1', volume, root, marker};
  mkdirSync(path.dirname(configPath), {recursive:true, mode:0o700});
  writeFileSync(configPath, JSON.stringify(profile, null, 2)+'\n', {flag:'wx', mode:0o600});
  return profile;
}

export function storagePath(kind, name, worktree, {configPath = defaultConfig(), isMounted = mounted} = {}) {
  assert(['cache', 'evidence', 'incoming', 'downloads'].includes(kind), 'unknown storage class');
  component(name);
  // No profile means legacy behavior, including OS-provided aliases in HOME.
  // A dangling profile itself is not the same as an unconfigured machine.
  try { assert(!lstatSync(configPath).isSymbolicLink(), 'symlink config'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  if (!existsSync(configPath)) return path.join(worktree, kind === 'incoming' ? '.data' : '.tmp', name);
  noLinks(configPath);
  const profile = JSON.parse(readFileSync(configPath, 'utf8'));
  assert(profile.schema === 'fox.storage_paths.v1' && Object.keys(profile).sort().join(',') === 'marker,root,schema,volume', 'invalid storage profile');
  assert(typeof profile.volume === 'string' && path.isAbsolute(profile.volume) && profile.volume !== '/', 'invalid volume');
  assert(typeof profile.root === 'string' && path.dirname(profile.root) === profile.volume, 'invalid storage root');
  noLinks(profile.volume);
  assert(isMounted(profile.volume), 'configured volume is not mounted; no internal fallback');
  noLinks(profile.root);
  const marker = path.join(profile.root, '.fox-storage-id');
  noLinks(marker);
  assert(typeof profile.marker === 'string' && readFileSync(marker, 'utf8') === profile.marker, 'volume/root identity mismatch');
  const target = path.join(profile.root, kind, createHash('sha256').update(path.resolve(worktree)).digest('hex').slice(0,16), name);
  noLinks(target);
  return target;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [action, volume, name] = process.argv.slice(2);
    if (action === 'init') console.log(JSON.stringify(initializeStorage(volume, name), null, 2));
    else if (action === 'show' || action === undefined) {
      const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
      console.log(JSON.stringify(Object.fromEntries(['cache','evidence','incoming','downloads'].map(k=>[k,storagePath(k,'training-sensors',root)])), null, 2));
    } else throw Error('Usage: storage-paths.mjs init <mounted-volume> [directory-name] | show');
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
