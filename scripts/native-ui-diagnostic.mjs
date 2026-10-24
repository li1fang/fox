import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {doctor, allocateSimulators, releaseSimulators, root} from './development-environment.mjs';
import {checkedCatalogue} from './test-inventory.mjs';
import {runSuite, execute} from './trial-suite.mjs';

export const phoneDiagnosticCase = 'FoxUITests/FoxPhoneLayoutUITests/testFeedbackKeyboardAndThreeCategoriesRemainReachableAfterRotation';
export function checkDiagnosticContext(env, catalogue) {
  if (env.FOX_PRIVATE_INPUT_MANIFEST || env.TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST) throw Error('Diagnostic must not receive private inputs');
  const row = catalogue.find(x => x.id === phoneDiagnosticCase);
  if (row?.scope !== 'public' || row.surface !== 'iphone') throw Error('Diagnostic case classification changed');
}
export function phoneDiagnosticStep(device) {
  return {id: 'phone-feedback', command: 'node', args: ['scripts/ipad.mjs', 'test-ui'],
    timeoutMs: 15 * 60 * 1000, native: true, expectedNative: [phoneDiagnosticCase],
    env: {FOX_IOS_UI_TEST: phoneDiagnosticCase, FOX_IOS_SIMULATOR: device,
      TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST: '', TEST_RUNNER_FOX_REAL_SPEECH: '0'}};
}

export function diagnosticRuntime(info, runtime) {
  if (!runtime) return info;
  const devices = info.simulators[runtime];
  const phone = devices?.find(x => x.deviceTypeIdentifier === 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro');
  if (!phone) throw Error('Requested diagnostic runtime/model unavailable; no fallback');
  return {...info, simulators: {[runtime]: devices.filter(x => x === phone || x.deviceTypeIdentifier?.includes('.iPad-'))}};
}

export function auditPhoneObservations(output) {
  const rows = [...output.matchAll(/FOX_UI_VISIBILITY (\{[^\n]*\})/g)].map(x => JSON.parse(x[1]));
  const duration = x => Number.isFinite(x) && x >= 0;
  const rect = x => Array.isArray(x) && x.length === 4 && x.every(Number.isFinite);
  const measured = x => {
    if (!x || typeof x !== 'object') return false;
    if (typeof x.exists !== 'boolean' || !duration(x.elapsedSeconds) || !duration(x.existsQuerySeconds)) return false;
    if (!x.exists) return x.hittable === undefined && x.hittableQuerySeconds === undefined
      && x.frame === undefined && x.window === undefined && x.contained === undefined;
    if (typeof x.hittable !== 'boolean' || !duration(x.hittableQuerySeconds)) return false;
    if (!x.hittable) return x.frame === undefined && x.window === undefined && x.contained === undefined;
    return typeof x.contained === 'boolean' && rect(x.window) && rect(x.frame);
  };
  if (rows.length !== 4 || rows.some(row => row.schema !== 'fox.ui_visibility_probe.v1'
    || row.id !== 'feedback-dismiss-keyboard' || row.completed !== true || row.deadlineSeconds !== 4
    || !Array.isArray(row.observations) || !row.observations.length
    || row.observations.some(x => !measured(x))
    || !row.observations.some(x => x.exists && x.hittable && x.contained))) {
    throw Error('Phone diagnostic observations missing or incomplete');
  }
  return rows;
}

export function auditPhoneInputObservations(output) {
  const rows = [...output.matchAll(/FOX_UI_INPUT (\{[^\n]*\})/g)].map(x => JSON.parse(x[1]));
  const ids = ['trial-information', 'trial-software-issue', 'trial-training-feeling'];
  if (rows.length !== ids.length || rows.some((row, index) => row.schema !== 'fox.ui_input_probe.v1'
    || row.id !== ids[index] || row.expected !== `test ${index}` || row.immediateValue !== row.expected
    || row.immediateMatched !== true || row.deadlineSeconds !== 4
    || !Array.isArray(row.observations) || row.observations.length !== 0)) {
    throw Error('Phone input observations missing or original assertion failed');
  }
  return rows;
}

export async function runPhoneDiagnostic(output) {
  if (!output) throw Error('Diagnostic requires a fresh output directory');
  const directory = path.resolve(output), steps = [];
  const git = args => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const metadata = {scope: 'diagnostic', component: 'phone-feedback', commit: git(['rev-parse', 'HEAD']),
    dirty: !!git(['status', '--porcelain']), environment: {},
    evidenceBoundary: 'One synthetic UI diagnostic, not full public/private acceptance or physical-device evidence.'};
  let lease;
  return runSuite({directory, steps, metadata,
    execute: async (step, options) => {
      const result = await execute(step, options);
      if (result.code === 0) {
        auditPhoneObservations(result.output);
        auditPhoneInputObservations(result.output);
      }
      return result;
    },
    preflight: async () => {
      checkDiagnosticContext(process.env, await checkedCatalogue());
      if (!steps.length) {
        const info = doctor({native: true});
        Object.assign(metadata.environment, info);
        lease = await allocateSimulators(diagnosticRuntime(info, process.env.FOX_DIAGNOSTIC_RUNTIME));
        metadata.environment.simulatorLifecycle = {status: 'allocated', ...lease};
        steps.push(phoneDiagnosticStep(lease.devices.iphone));
      }
      return [];
    },
    finalize: async () => {
      if (!lease) return;
      try { await releaseSimulators(lease); metadata.environment.simulatorLifecycle.status = 'released'; }
      catch (error) { metadata.environment.simulatorLifecycle.status = 'cleanup_failed'; throw error; }
    }
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  runPhoneDiagnostic(process.argv[2]).then(r => console.log(JSON.stringify({status: r.status, scope: r.scope, deviceVerified: false})))
    .catch(error => { console.error(error.message); process.exitCode = 1; });
}
