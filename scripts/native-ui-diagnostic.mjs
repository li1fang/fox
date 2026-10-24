import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {doctor, allocateSimulators, releaseSimulators, root} from './development-environment.mjs';
import {checkedCatalogue} from './test-inventory.mjs';
import {runSuite, execute} from './trial-suite.mjs';

export const phoneDiagnosticCase = 'FoxUITests/FoxPhoneLayoutUITests/testFeedbackKeyboardAndThreeCategoriesRemainReachableAfterRotation';
export const phoneDiagnosticCases = [phoneDiagnosticCase,
  'FoxUITests/FoxPhoneLayoutUITests/testFramingValidationRequiresEveryCorner',
  'FoxUITests/FoxPhoneLayoutUITests/testVisionOptionsLockCorrectionAndSavedReportRemainUsable'];
export function checkDiagnosticContext(env, catalogue) {
  if (env.FOX_PRIVATE_INPUT_MANIFEST || env.TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST) throw Error('Diagnostic must not receive private inputs');
  for (const id of phoneDiagnosticCases) {
    const row = catalogue.find(x => x.id === id);
    if (row?.scope !== 'public' || row.surface !== 'iphone') throw Error('Diagnostic case classification changed');
  }
}
export function phoneDiagnosticStep(device) {
  return {id: 'phone-readiness', command: 'node', args: ['scripts/ipad.mjs', 'test-ui'],
    timeoutMs: 15 * 60 * 1000, native: true, expectedNative: phoneDiagnosticCases,
    env: {FOX_IOS_UI_TEST: phoneDiagnosticCases.join(','), FOX_IOS_SIMULATOR: device,
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
  const contains = (window, frame) => rect(window) && rect(frame) && window[2] > 0 && window[3] > 0
    && frame[2] > 0 && frame[3] > 0 && frame[0] >= window[0] - 0.5 && frame[1] >= window[1] - 0.5
    && frame[0] + frame[2] <= window[0] + window[2] + 0.5
    && frame[1] + frame[3] <= window[1] + window[3] + 0.5;
  const measured = x => {
    if (!x || typeof x !== 'object') return false;
    if (typeof x.exists !== 'boolean' || !duration(x.elapsedSeconds) || !duration(x.existsQuerySeconds)) return false;
    if (!x.exists) return x.hittable === undefined && x.hittableQuerySeconds === undefined
      && x.frame === undefined && x.window === undefined && x.contained === undefined;
    if (typeof x.hittable !== 'boolean' || !duration(x.hittableQuerySeconds)) return false;
    if (!x.hittable) return x.frame === undefined && x.window === undefined && x.contained === undefined;
    return typeof x.contained === 'boolean' && rect(x.window) && rect(x.frame)
      && x.contained === contains(x.window, x.frame);
  };
  if (rows.length !== 4 || rows.some(row => row.schema !== 'fox.ui_visibility_probe.v2' || row.viewportSource !== 'main-window'
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

export function auditFramingObservations(output) {
  const rows = [...output.matchAll(/FOX_UI_FRAMING (\{[^\n]*\})/g)].map(x => JSON.parse(x[1]));
  const expected = [[0, 255, 0], [255, 0, 0], [255, 255, 0], [0, 0, 255]], orientations = [3, 4, 1];
  const measured = colors => Array.isArray(colors) && colors.length === 4 && colors.every(c => Array.isArray(c)
    && c.length === 3 && c.every(x => Number.isInteger(x) && x >= 0 && x <= 255));
  const matches = colors => measured(colors) && colors.every((c, i) => c.every((x, j) => Math.abs(x - expected[i][j]) < 20));
  const stableTrace = observations => {
    if (!Array.isArray(observations) || !observations.length) return false;
    const rectangle = x => Array.isArray(x) && x.length === 4 && x.every(Number.isFinite) && x[2] > 0 && x[3] > 0;
    let previous, since;
    return observations.every(x => {
      let stable = 0;
      if (!Array.isArray(x.cornerRGB)) return false;
      if (x.cornerRGB.length === 0) {
        if (x.window !== undefined || x.preview !== undefined) return false;
        previous = undefined; since = undefined;
      } else {
        if (!measured(x.cornerRGB) || !rectangle(x.window) || !rectangle(x.preview)) return false;
        if (matches(x.cornerRGB)) {
          const key = JSON.stringify([x.cornerRGB, x.window, x.preview]);
          if (key !== previous) { previous = key; since = x.elapsedSeconds; }
          stable = x.elapsedSeconds - since;
        } else { previous = undefined; since = undefined; }
      }
      return Math.abs(stable - x.stableSeconds) < 0.000001;
    });
  };
  if (rows.length !== 3 || rows.some((row, index) => row.schema !== 'fox.ui_framing_probe.v1'
    || row.orientation !== orientations[index] || row.completed !== true || row.deadlineSeconds !== 4
    || !Number.isFinite(row.elapsedSeconds) || row.elapsedSeconds < 0 || row.elapsedSeconds > 4 || !matches(row.cornerRGB)
    || !Number.isFinite(row.stableSeconds) || row.stableSeconds < 0.25 || row.stableSeconds > row.elapsedSeconds
    || !stableTrace(row.observations)
    || row.observations.some((x, i) => !Number.isFinite(x.elapsedSeconds) || x.elapsedSeconds < 0
      || x.elapsedSeconds > row.elapsedSeconds || i > 0 && x.elapsedSeconds < row.observations[i - 1].elapsedSeconds
      || !Number.isFinite(x.stableSeconds) || x.stableSeconds < 0 || x.stableSeconds > x.elapsedSeconds
      || !Array.isArray(x.cornerRGB) || x.cornerRGB.length !== 0 && !measured(x.cornerRGB))
    || row.observations.at(-1)?.stableSeconds !== row.stableSeconds
    || JSON.stringify(row.observations.at(-1)?.cornerRGB) !== JSON.stringify(row.cornerRGB))) {
    throw Error('Phone framing observations missing or incomplete');
  }
  return rows;
}

export async function runPhoneDiagnostic(output) {
  if (!output) throw Error('Diagnostic requires a fresh output directory');
  const directory = path.resolve(output), steps = [];
  const git = args => execFileSync('git', args, {cwd: root, encoding: 'utf8'}).trim();
  const metadata = {scope: 'diagnostic', component: 'phone-readiness', commit: git(['rev-parse', 'HEAD']),
    dirty: !!git(['status', '--porcelain']), environment: {},
    evidenceBoundary: 'Fixed synthetic input/framing diagnostics, not full public/private acceptance or physical-device evidence.'};
  let lease;
  return runSuite({directory, steps, metadata,
    execute: async (step, options) => {
      const result = await execute(step, options);
      if (result.code === 0) {
        auditPhoneObservations(result.output);
        auditPhoneInputObservations(result.output);
        auditFramingObservations(result.output);
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
