import path from 'node:path';
import {statfsSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {doctor, allocateSimulators, releaseSimulators, isolateSimulatorStep} from './development-environment.mjs';
import {runSuite, execute} from './trial-suite.mjs';
import {checkCandidate} from './verify.mjs';
import {checkedCatalogue} from './test-inventory.mjs';

export const duoRuntime = 'com.apple.CoreSimulator.SimRuntime.iOS-27-1';
export const duoModel = 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo';
export function duoSelection(catalogue) {
  const groups = ['FoxAppTests/AdaptiveLayoutTests/', 'FoxUITests/FoxAdaptiveUITests/', 'FoxUITests/FoxHomeUITests/'];
  const selected = groups.flatMap(group => {
    const rows = catalogue.filter(x => x.id.startsWith(group));
    if (!rows.length) throw Error(`Missing Duo coverage: ${group}`);
    if (rows.some(x => x.scope !== 'public')) throw Error('Duo requires public synthetic coverage');
    return rows.map(x => x.id);
  });
  return selected;
}

export async function runDuo({commit, output}) {
  checkCandidate(commit);
  if (!output) throw Error('Fresh output directory required');
  const steps = [], metadata = {scope: 'diagnostic', component: 'duo-layout', commit,
    evidenceBoundary: 'Synthetic app-host resizing and actual Duo UI flows. Physical camera, exercise accuracy and hinge hardware are not verified.', environment: {}};
  let lease;
  const capacity = () => {
    const s = statfsSync('/');
    if (s.bavail * s.bsize < 2 * 2 ** 30) throw Error('Internal capacity below 2 GiB');
  };
  return runSuite({directory: path.resolve(output), steps, metadata,
    preflight: async () => {
      checkCandidate(commit); capacity();
      if (process.env.FOX_PRIVATE_INPUT_MANIFEST) throw Error('Duo layout check must not receive private inputs');
      if (!steps.length) {
        const tests = duoSelection(await checkedCatalogue()), info = doctor({native: true});
        info.simulatorRuntime = duoRuntime;
        lease = await allocateSimulators(info, {families: ['iphone'], models: {iphone: duoModel}, overrides: {}});
        metadata.environment.simulatorLifecycle = {status: 'allocated', ...lease};
        steps.push({id: 'duo-layout', command: 'node', args: ['scripts/ipad.mjs', 'test-ui'], native: true,
          expectedNative: tests, timeoutMs: 40 * 60 * 1000,
          env: {FOX_IOS_SIMULATOR: lease.devices.iphone, FOX_IOS_UI_TEST: tests.join(','),
            TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST: '', TEST_RUNNER_FOX_REAL_SPEECH: '0'}});
      }
      return [];
    },
    execute: async (step, options) => {
      await isolateSimulatorStep(lease, step);
      const stop = new AbortController(); let failure;
      const monitor = setInterval(() => { try { capacity(); } catch (e) { failure = e; stop.abort(); } }, 5000);
      try {
        const result = await execute(step, {...options, signal: AbortSignal.any([options.signal, stop.signal])});
        if (failure) throw failure;
        return result;
      } finally { clearInterval(monitor); }
    },
    finalize: async () => {
      if (lease) { await releaseSimulators(lease); metadata.environment.simulatorLifecycle.status = 'released'; }
    }
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [commit, output, ...extra] = process.argv.slice(2);
  Promise.resolve().then(() => {
    if (extra.length) throw Error('Usage: npm run verify:duo -- <full-commit> <fresh-output>');
    return runDuo({commit, output});
  }).then(result => console.log(JSON.stringify({status: result.status, deviceVerified: false})))
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}
