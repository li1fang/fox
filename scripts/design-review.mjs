import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {doctor, allocateSimulators, releaseSimulators, isolateSimulatorStep, environment} from './development-environment.mjs';
import {checkedCatalogue} from './test-inventory.mjs';
import {runSuite, execute, fingerprint} from './trial-suite.mjs';

const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const env = environment;
const groups = { home: ['testHomeScenarios', 'testHomeSmokeScenarios', 'testColumnAffinitySurvivesComposerGrowth'],
  'home-smoke': ['testHomeSmokeScenarios', 'testColumnAffinitySurvivesComposerGrowth'],
  records: ['testRecordScenarios', 'testFullPhotoCanZoomAndReturnToUnchangedRecord'],
  projections: ['testTrainingProjectionScenarios', 'testReadOnlyTrainingCardCanOpenAndClose'], training: ['testTrainingJourneyScenarios', 'testTrainingScenarios', 'testTrainingRotatedFeedbackInput'],
  'training-feedback': ['testTrainingRotatedFeedbackInput'], 'training-journey': ['testTrainingJourneyScenarios'] };
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

export function sourceFingerprint(directory = root) {
  const files = [];
  function walk(p) {
    for (const item of readdirSync(p, { withFileTypes: true })) {
      const name = path.join(p, item.name);
      if (item.isDirectory() && !item.name.startsWith('.') && !['build', 'FoxPad.xcodeproj'].includes(item.name)) walk(name);
      else if (item.isFile() && /\.(swift|yml|plist)$/.test(item.name)) files.push(name);
    }
  }
  walk(path.join(directory, 'apps/ipad'));
  const hash = createHash('sha256');
  for (const f of files.sort()) hash.update(path.relative(directory, f)).update('\0').update(readFileSync(f));
  return { schema: 'fox.design_source.v1', sha256: hash.digest('hex'), fileCount: files.length, capturedAt: new Date().toISOString() };
}

export function observe(report) {
  if (report.schema !== 'fox.design_observation.v1' || report.source !== 'isolated-design-fixture'
      || !Array.isArray(report.elements) || typeof report.scenario !== 'string') throw Error('Invalid design observation');
  const valid = r => r && ['x', 'y', 'width', 'height'].every(k => Number.isFinite(r[k])) && r.width > 0 && r.height > 0;
  if (!valid(report.viewport)) throw Error('Invalid viewport');
  const v = report.viewport;
  return report.elements.map(e => {
    if (!valid(e.frame)) return { id: e.id, observation: 'unmeasurable', conclusion: 'unknown' };
    const r = e.frame;
    const overlap = Math.max(0, Math.min(v.x + v.width, r.x + r.width) - Math.max(v.x, r.x))
      * Math.max(0, Math.min(v.y + v.height, r.y + r.height) - Math.max(v.y, r.y));
    return { ...e, visibleFractionWithinWindow: overlap / (r.width * r.height),
      observation: overlap === 0 ? 'outside-window' : (overlap < r.width * r.height - 1 ? 'partly-outside-window' : 'bounds-within-window'),
      conclusion: 'geometry-only-not-usability-acceptance' };
  });
}

export function collect(resultPath, output, source = null) {
  mkdirSync(output, { recursive: true });
  const run = args => {
    const p = spawnSync('xcrun', ['xcresulttool', ...args], { env, encoding: 'utf8', timeout: 120000, maxBuffer: 12 * 1024 * 1024 });
    if (p.error || p.status !== 0) throw Error(p.stderr || p.error?.message || 'xcresult export failed');
    return p.stdout;
  };
  const summary = JSON.parse(run(['get', 'test-results', 'summary', '--path', resultPath, '--compact']));
  const attachments = path.join(output, 'attachments');
  run(['export', 'attachments', '--path', resultPath, '--output-path', attachments]);
  const manifest = JSON.parse(readFileSync(path.join(attachments, 'manifest.json'), 'utf8'));
  const exported = manifest.flatMap(t => (t.attachments ?? []).map(a => ({ ...a, test: t.testIdentifier })));
  const observations = [];
  for (const item of exported.filter(a => a.suggestedHumanReadableName.startsWith('design-') && a.suggestedHumanReadableName.includes('-geometry'))) {
    const raw = JSON.parse(readFileSync(path.join(attachments, item.exportedFileName), 'utf8'));
    const image = exported.find(a => a.test === item.test && a.suggestedHumanReadableName.startsWith(`design-${raw.scenario}_`) && a.exportedFileName.endsWith('.png'));
    if (image) {
      const bytes = readFileSync(path.join(attachments, image.exportedFileName));
      if (!bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) throw Error(`Invalid screenshot: ${raw.scenario}`);
    }
    observations.push({ ...raw, test: item.test, elements: observe(raw), screenshot: image ? `attachments/${image.exportedFileName}` : null });
  }
  if (!observations.length) throw Error('No design observations exported; the result is not a design review');
  const report = { schema: 'fox.design_review.v1', generatedAt: new Date().toISOString(), source,
    resultPath, devices: summary.devicesAndConfigurations, testResult: summary.result,
    note: 'Render and geometry evidence only. No AI score, human usability or business correctness claim.', observations };
  writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  const panels = observations.map(s => `<section><h2>${escape(s.scenario)}</h2>${s.screenshot ? `<a href="${escape(s.screenshot)}"><img src="${escape(s.screenshot)}" alt="${escape(s.scenario)}"></a>` : '<p>Missing screenshot</p>'}<details><summary>Geometry observations</summary><pre>${escape(JSON.stringify(s.elements, null, 2))}</pre></details></section>`).join('\n');
  writeFileSync(path.join(output, 'index.html'), `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Fox design evidence</title><style>body{font:16px system-ui;max-width:1200px;margin:auto;padding:24px;color:#19241e;background:#f5f7f6}section{border-top:1px solid #bbc8c0;padding:24px 0}img{max-width:100%;max-height:850px;object-fit:contain}pre{white-space:pre-wrap;overflow-wrap:anywhere}h1,h2{letter-spacing:0}</style><h1>Fox design evidence</h1><p>Isolated design samples. Layout observations are not functional or usability acceptance.</p><p>Source: ${escape(source?.sha256 ?? 'unverified / collect only')}</p>${panels}</html>`);
  return report;
}

export const designScenes = {
  testTrainingJourneyScenarios: ['training-ready', 'training-waiting', 'training-active', 'training-paused', 'training-rest',
    'training-summary', 'training-active-rotated', 'training-large-type'],
  testHomeScenarios: ['home-empty', 'home-long-text', 'home-portrait-photo', 'home-landscape-photo', 'home-missing-photo',
    'home-keyboard', 'home-loading', 'home-save-failure', 'home-pagination', 'home-rotated'],
  testHomeSmokeScenarios: ['home-mixed', 'home-long-photo', 'home-large-type', 'home-dark'],
  testColumnAffinitySurvivesComposerGrowth: ['home-column-affinity-before', 'home-column-affinity'],
  testRecordScenarios: ['record-long-photo', 'record-multiple-photos', 'record-long-text', 'record-missing-photo', 'record-editor-conflict', 'record-backup'],
  testFullPhotoCanZoomAndReturnToUnchangedRecord: ['record-full-photo-zoom'],
  testTrainingProjectionScenarios: ['projection-plan', 'projection-current', 'projection-confirmed', 'projection-missing', 'projection-corrupt'],
  testReadOnlyTrainingCardCanOpenAndClose: ['projection-read-only-detail'],
  testTrainingScenarios: ['training-feedback', 'training-diagnostic-review', 'training-feedback-keyboard'],
  testTrainingRotatedFeedbackInput: ['training-feedback-rotated', 'training-feedback-rotated-left-input', 'training-feedback-rotated-keyboard']
};

export function designMethods(selected) {
  if (!selected.length || selected.some(group => !Object.hasOwn(groups, group))) throw Error('Unknown design group');
  return [...new Set(selected.flatMap(group => groups[group]))];
}

export function parseDesignArguments(args) {
  const [command = 'run', ...rest] = args, options = {};
  if (!['run', 'collect', 'fingerprint'].includes(command)) throw Error('Expected run, collect or fingerprint');
  for (let i = 0; i < rest.length; i += 2) {
    const key = rest[i], value = rest[i + 1];
    if (!['--output', '--group', '--device', '--result'].includes(key) || !value?.trim() || value.startsWith('--') || key in options) {
      throw Error('Invalid or duplicate design arguments');
    }
    options[key] = value;
  }
  if (command === 'collect' ? !options['--result'] : options['--result']) throw Error('Only collect requires --result');
  if (command !== 'run' && options['--device'] || command === 'fingerprint' && options['--group']) throw Error('Unexpected design option');
  const selected = (options['--group'] ?? 'home').split(',');
  designMethods(selected);
  const device = options['--device'] ?? 'ipad';
  if (!['ipad', 'iphone'].includes(device)) throw Error('Expected --device ipad or iphone');
  return {command, groups: selected, device, result: options['--result'],
    output: path.resolve(options['--output'] ?? path.join(root, '.tmp/design-review', new Date().toISOString().replace(/[:.]/g, '-')))};
}

export function validateDesignEvidence(report, methods) {
  if (report.testResult !== 'Passed') throw Error(`Design result not passed: ${report.testResult}`);
  validateCoverage(report, methods);
  for (const method of methods) {
    if (!Object.hasOwn(designScenes, method)) throw Error(`Unknown design method: ${method}`);
    for (const scene of designScenes[method]) {
      const matches = report.observations.filter(o => o.test?.includes(`${method}()`) && o.scenario === scene);
      if (matches.length !== 1 || !matches[0].screenshot) throw Error(`Missing, duplicate or unpictured scene: ${method}/${scene}`);
    }
  }
}

export async function runDesignReview(options, overrides = {}) {
  const deps = {env: process.env, doctor, allocate: allocateSimulators, release: releaseSimulators, isolate: isolateSimulatorStep,
    catalogue: checkedCatalogue, execute, fingerprint,
    identity: () => ({commit: execFileSync('git', ['rev-parse', 'HEAD'], {cwd: root, encoding: 'utf8'}).trim(),
      dirty: !!execFileSync('git', ['status', '--porcelain'], {cwd: root, encoding: 'utf8'}).trim()}), ...overrides};
  const methods = designMethods(options.groups), ids = methods.map(name => `FoxUITests/FoxDesignReviewUITests/${name}`);
  const directory = path.resolve(options.output), steps = [], result = path.join(directory, 'result.xcresult');
  const metadata = {scope: 'diagnostic', component: 'design-review', ...deps.identity(), environment: {simulatorIsolation: []},
    evidenceBoundary: 'Synthetic render/interaction diagnostic, not full candidate or physical-device acceptance.'};
  let lease;
  return runSuite({directory, steps, metadata, fingerprint: deps.fingerprint,
    preflight: async () => {
      if (deps.env.FOX_PRIVATE_INPUT_MANIFEST || deps.env.TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST) throw Error('Design capture must not receive private inputs');
      const catalogue = await deps.catalogue();
      for (const id of ids) {
        const row = catalogue.find(row => row.id === id);
        if (row?.scope !== 'public' || row.surface !== 'ipad') throw Error(`Design classification changed: ${id}`);
      }
      if (!steps.length) {
        if (!['ipad', 'iphone'].includes(options.device)) throw Error('Unsupported design device');
        const info = deps.doctor({native: true});
        Object.assign(metadata.environment, info);
        lease = await deps.allocate(info, {families: [options.device],
          overrides: deps.env.FOX_IOS_SIMULATOR ? {[options.device]: deps.env.FOX_IOS_SIMULATOR} : {}});
        metadata.environment.simulatorLifecycle = {status: 'allocated', ...lease};
        writeFileSync(path.join(directory, 'source.json'), JSON.stringify(sourceFingerprint(), null, 2) + '\n', {flag: 'wx'});
        steps.push({id: 'design-ui', command: 'node', args: ['scripts/ipad.mjs', 'test-ui'], native: true, expectedNative: ids,
          timeoutMs: 45 * 60 * 1000, env: {FOX_IOS_SIMULATOR: lease.devices[options.device], FOX_IOS_UI_TEST: ids.join(','),
            FOX_IOS_UI_RESULT: result, TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST: '', TEST_RUNNER_FOX_REAL_SPEECH: '0'}},
        {id: 'design-collect', command: 'node', args: ['scripts/design-review.mjs', 'collect', '--result', result,
          '--output', directory, '--group', options.groups.join(',')], timeoutMs: 5 * 60 * 1000});
      }
      return [];
    },
    execute: async (step, execution) => {
      if (step.native) {
        const isolation = await deps.isolate(lease, step);
        if (isolation) metadata.environment.simulatorIsolation.push(isolation);
      }
      return deps.execute(step, execution);
    },
    finalize: async () => {
      if (!lease) return;
      try { await deps.release(lease); metadata.environment.simulatorLifecycle.status = 'released'; }
      catch (error) { metadata.environment.simulatorLifecycle.status = 'cleanup_failed'; throw error; }
    }
  });
}

async function main() {
  const options = parseDesignArguments(process.argv.slice(2));
  if (options.command === 'run') await runDesignReview(options);
  else {
    mkdirSync(options.output, {recursive: true});
    const file = path.join(options.output, 'source.json');
    if (options.command === 'fingerprint') {
      writeFileSync(file, JSON.stringify(sourceFingerprint(), null, 2) + '\n', {flag: 'wx'});
      return;
    }
    const report = collect(path.resolve(options.result), options.output, existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : null);
    validateDesignEvidence(report, designMethods(options.groups));
  }
  console.log(`Design evidence: ${path.join(options.output, 'index.html')}`);
}

export function validateCoverage(report, methods) {
  const missing = methods.filter(method => !report.observations.some(o => o.test?.includes(`${method}()`)));
  if (missing.length) throw Error(`Missing design test evidence: ${missing.join(', ')}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(error.message); process.exitCode = 1; });
}
