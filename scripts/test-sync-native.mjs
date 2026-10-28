import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

if (process.platform !== 'darwin') throw Error('Native sync tests require macOS and Xcode');
const cwd = fileURLToPath(new URL('..', import.meta.url));
const env = {...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR ?? '/Applications/Xcode.app/Contents/Developer'};
function run(args) {
  const result = spawnSync('xcrun', args, {cwd, env, stdio: 'inherit'});
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
run(['swift', 'test', '--package-path', 'apps/ipad/FoxSyncCore', '--scratch-path', '.tmp/sync-transport-build']);
const sdk = spawnSync('xcrun', ['--sdk', 'iphoneos', '--show-sdk-path'], {env, encoding: 'utf8'});
if (sdk.status !== 0 || !sdk.stdout.trim()) throw Error('iPhoneOS SDK missing');
run(['swift', 'build', '--package-path', 'apps/ipad/FoxSyncCore', '--scratch-path', '.tmp/sync-transport-ios-build',
  '--target', 'FoxSyncCore', '--triple', 'arm64-apple-ios16.0', '--sdk', sdk.stdout.trim()]);
console.log('sync_ios_compile_pass (SDK only, not device execution)');
