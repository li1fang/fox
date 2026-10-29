import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {guardNativeEntry, nativeScratchPath, swiftJobs} from './native-resource.mjs';

if (process.platform !== 'darwin') throw Error('Native sync tests require macOS and Xcode');
const options = process.argv.slice(2);
if (options.length && (options.length !== 1 || options[0] !== '--host-only')) throw Error('Usage: test-sync-native.mjs [--host-only]');
if (await guardNativeEntry('sync-native')) process.exit(0);
const cwd = fileURLToPath(new URL('..', import.meta.url));
const env = {...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer'};
function run(args) {
  const result = spawnSync('xcrun', args, {cwd, env, stdio: 'inherit'});
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
run(['swift', 'test', '--package-path', 'apps/ipad/FoxSyncCore', '--scratch-path', nativeScratchPath('sync-transport-build'), '--jobs', String(swiftJobs())]);
if (options.includes('--host-only')) process.exit(0);
const sdk = spawnSync('xcrun', ['--sdk', 'iphoneos', '--show-sdk-path'], {env, encoding: 'utf8'});
if (sdk.status !== 0 || !sdk.stdout.trim()) throw Error('iPhoneOS SDK missing');
run(['swift', 'build', '--package-path', 'apps/ipad/FoxSyncCore', '--scratch-path', nativeScratchPath('sync-transport-ios-build'), '--jobs', String(swiftJobs()),
  '--target', 'FoxSyncCore', '--triple', 'arm64-apple-ios16.0', '--sdk', sdk.stdout.trim()]);
console.log('sync_ios_compile_pass (SDK only, not device execution)');
