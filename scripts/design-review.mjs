import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, openSync, closeSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(fileURLToPath(new URL('..', import.meta.url)));
const env = { ...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' };
const groups = { home: ['testHomeScenarios', 'testColumnAffinitySurvivesComposerGrowth'],
  'home-smoke': ['testHomeSmokeScenarios', 'testColumnAffinitySurvivesComposerGrowth'],
  records: ['testRecordScenarios', 'testFullPhotoCanZoomAndReturnToUnchangedRecord'],
  projections: ['testTrainingProjectionScenarios', 'testReadOnlyTrainingCardCanOpenAndClose'], training: ['testTrainingScenarios'],
  'training-feedback': ['testTrainingRotatedFeedbackInput'] };
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

function main() {
  const [command = 'run', ...args] = process.argv.slice(2);
  const option = name => { const i = args.indexOf(name); return i < 0 ? undefined : args[i + 1]; };
  const output = path.resolve(option('--output') ?? path.join(root, '.tmp/design-review', new Date().toISOString().replace(/[:.]/g, '-')));
  mkdirSync(output, { recursive: true });
  if (command === 'fingerprint') {
    const s = sourceFingerprint(); writeFileSync(path.join(output, 'source.json'), JSON.stringify(s, null, 2) + '\n'); console.log(s); return;
  }
  if (command === 'collect') {
    if (!option('--result')) throw Error('collect requires --result <xcresult>');
    const file = path.join(output, 'source.json');
    collect(path.resolve(option('--result')), output, existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : null);
  } else if (command === 'run') {
    const selected = (option('--group') ?? 'home').split(',');
    if (selected.some(g => !groups[g])) throw Error('Expected --group home,home-smoke,records,projections,training,training-feedback');
    const device = option('--device') ?? 'ipad';
    if (!['ipad', 'iphone'].includes(device)) throw Error('Expected --device ipad or iphone');
    const listing = spawnSync('xcrun', ['simctl', 'list', 'devices', 'available', '--json'], { env, encoding: 'utf8' });
    if (listing.status !== 0) throw Error('Cannot inspect simulator list');
    const devices = Object.values(JSON.parse(listing.stdout).devices).flat();
    const simulator = process.env.FOX_IOS_SIMULATOR ?? devices.find(d => device === 'ipad' ? d.name.includes('iPad Pro 11-inch') : d.name.includes('iPhone 17 Pro'))?.udid;
    if (!simulator) throw Error('No matching existing simulator; no device was created or removed');
    const source = sourceFingerprint(); writeFileSync(path.join(output, 'source.json'), JSON.stringify(source, null, 2) + '\n');
    const generation = spawnSync('xcodegen', ['generate'], { env, cwd: path.join(root, 'apps/ipad'), encoding: 'utf8' });
    if (generation.status !== 0) throw Error(generation.stderr);
    const log = openSync(path.join(output, 'run.log'), 'w'), result = path.join(output, 'result.xcresult');
    let test;
    try {
      test = spawnSync('xcodebuild', ['-project', 'apps/ipad/FoxPad.xcodeproj', '-scheme', 'Fox', '-configuration', 'Debug',
        '-destination', `platform=iOS Simulator,id=${simulator}`, '-derivedDataPath', '.tmp/ipad-simulator-data',
        '-parallel-testing-enabled', 'NO', '-resultBundlePath', result,
        ...selected.flatMap(g => groups[g].map(test => `-only-testing:FoxUITests/FoxDesignReviewUITests/${test}`)), 'CODE_SIGNING_ALLOWED=NO', 'test'],
      { env, cwd: root, stdio: ['ignore', log, log], timeout: 2700000 });
    } finally { closeSync(log); }
    if (existsSync(result)) {
      const report = collect(result, output, source);
      validateCoverage(report, selected.flatMap(g => groups[g]));
    }
    if (test.error || test.status !== 0) throw Error(`Design capture failed; inspect ${path.join(output, 'run.log')}`);
  } else throw Error('Expected run, collect or fingerprint');
  console.log(`Design evidence: ${path.join(output, 'index.html')}`);
}

export function validateCoverage(report, methods) {
  const missing = methods.filter(method => !report.observations.some(o => o.test?.includes(`${method}()`)));
  if (missing.length) throw Error(`Missing design test evidence: ${missing.join(', ')}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(); } catch (error) { console.error(error.message); process.exitCode = 1; }
}
