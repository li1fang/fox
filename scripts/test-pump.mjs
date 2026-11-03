import {spawnSync} from 'node:child_process';
import {guardNativeEntry, nativeScratchPath, swiftJobs} from './native-resource.mjs';
import {environment, root} from './development-environment.mjs';

if (await guardNativeEntry('pump-core')) process.exit(0);
const result = spawnSync('xcrun', ['swift', 'test', '--package-path', 'apps/ipad/FoxPumpKit',
  '--scratch-path', nativeScratchPath('pump-core'), '--jobs', String(swiftJobs())],
  {cwd: root, env: environment, stdio: 'inherit', timeout: 180000});
if (result.error) throw result.error;
process.exit(result.status ?? 1);
