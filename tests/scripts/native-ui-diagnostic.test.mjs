import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {phoneDiagnosticCase, phoneDiagnosticStep, checkDiagnosticContext} from '../../scripts/native-ui-diagnostic.mjs';
import * as diagnostic from '../../scripts/native-ui-diagnostic.mjs';
import {auditReceipt} from '../../scripts/verification-contracts.mjs';

test('feedback target stability samples immediately without extending its original deadline', () => {
  const source = readFileSync(new URL('../../apps/ipad/FoxUITests/FoxPhoneLayoutUITests.swift', import.meta.url), 'utf8');
  const body = source.slice(source.indexOf('private func stableTarget('), source.indexOf('private func screenshot('));
  assert.match(body, /let start = ProcessInfo\.processInfo\.systemUptime, deadline = start \+ 4/);
  assert.match(body, /let predicate = NSPredicate/);
  assert.match(body, /self\.fullyVisible\(element, in: app, viewport: viewport, above: footer\)/);
  assert.match(body, /previous = nil; stableSince = nil; return false/);
  assert.match(body, /previous != frame/);
  assert.match(body, />= 0\.25/);
  assert.match(body, /let immediate = predicate\.evaluate\(with: nil\)/);
  assert.match(body, /remaining = deadline - ProcessInfo\.processInfo\.systemUptime/);
  assert.match(body, /timeout: remaining/);
  assert.match(body, /result == \.completed && ProcessInfo\.processInfo\.systemUptime <= deadline/);
  assert.match(body, /XCTAssertTrue\(completed, element\.identifier/);
  assert.doesNotMatch(body, /timeout: 4|sleep\(|insetBy|retry/i);
});

test('feedback prepares portrait only after a single configured app launch', () => {
  const source = readFileSync(new URL('../../apps/ipad/FoxUITests/FoxPhoneLayoutUITests.swift', import.meta.url), 'utf8');
  const method = name => {
    const start = source.indexOf(`func ${name}(`);
    assert.notEqual(start, -1, `Missing method ${name}`);
    const end = source.indexOf('\n    }', start);
    assert.notEqual(end, -1);
    return source.slice(start, end);
  };
  const caller = method('testFeedbackKeyboardAndThreeCategoriesRemainReachableAfterRotation');
  const setup = caller.slice(0, caller.indexOf('app.buttons["start-training"].tap()'));
  const configured = setup.indexOf('app.launchEnvironment = ["FOX_UI_TESTING": "1", "FOX_START_SCREEN": "training"]');
  const reset = setup.indexOf('app.launchArguments = ["--ui-testing-reset"]');
  assert.ok(configured >= 0 && reset > configured && setup.indexOf('launchFeedbackInPortrait(app)') > reset);
  assert.equal((setup.match(/launchFeedbackInPortrait\(app\)/g) ?? []).length, 1);
  assert.doesNotMatch(setup, /app\.launch\(\)|XCUIDevice\.shared\.orientation/);
  const helper = method('launchFeedbackInPortrait');
  const tokens = ['app.launch()', 'app.buttons["start-training"].waitForExistence(timeout: 10)',
    'XCUIDevice.shared.orientation = .portrait', 'waitForOrientation(.portrait, in: app)'];
  let previous = -1;
  for (const token of tokens) {
    const index = helper.indexOf(token);
    assert.ok(index > previous, `Preparation order: ${token}`);
    assert.equal(helper.indexOf(token, index + token.length), -1, `Single operation: ${token}`);
    previous = index;
  }
});

test('phone diagnostic covers fixed input and framing cases, never a full-suite substitute', () => {
  const step = phoneDiagnosticStep('owned-phone');
  const cases = [phoneDiagnosticCase,
    'FoxUITests/FoxPhoneLayoutUITests/testFramingValidationRequiresEveryCorner',
    'FoxUITests/FoxPhoneLayoutUITests/testVisionOptionsLockCorrectionAndSavedReportRemainUsable'];
  assert.deepEqual(step.expectedNative, cases);
  assert.equal(step.env.FOX_IOS_UI_TEST, cases.join(','));
  assert.equal(step.env.FOX_IOS_SIMULATOR, 'owned-phone');
  assert.equal(step.env.TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST, '');
  assert.equal(step.env.TEST_RUNNER_FOX_REAL_SPEECH, '0');
  assert.equal(step.timeoutMs, 25 * 60 * 1000);
  assert.throws(() => auditReceipt({status: 'software_suite_passed', scope: 'diagnostic',
    commit: 'same', sourceSHA256: 'same', deviceVerified: false, steps: [{status: 'passed'}]},
    {scope: 'public', commit: 'same', sourceSHA256: 'same'}), /scope/);
});

test('a passing diagnostic must retain all four measured visibility observations', () => {
  const row = {schema: 'fox.ui_visibility_probe.v2', viewportSource: 'main-window', id: 'feedback-dismiss-keyboard', completed: true,
    deadlineSeconds: 4, observations: [{exists: true, hittable: true, contained: true, elapsedSeconds: 0.2,
      existsQuerySeconds: 0.03, hittableQuerySeconds: 0.04, window: [0, 0, 400, 800], frame: [12, 600, 44, 44]}]};
  const log = values => values.map(value => `FOX_UI_VISIBILITY ${JSON.stringify(value)}`).join('\n');
  assert.doesNotThrow(() => diagnostic.auditPhoneObservations(log([row, row, row, row])));
  for (const rows of [[], [row], [row, row, row, {...row, observations: []}],
    [row, row, row, {...row, deadlineSeconds: 10}], [row, row, row, {...row, completed: false}],
    [row, row, row, {...row, viewportSource: 'application-root'}]]) {
    assert.throws(() => diagnostic.auditPhoneObservations(log(rows)), /observations/);
  }
  const missing = {exists: false, elapsedSeconds: 0.1, existsQuerySeconds: 0.05};
  assert.doesNotThrow(() => diagnostic.auditPhoneObservations(log(Array(4).fill({...row, observations: [missing, ...row.observations]}))));
  const incomplete = [null, 'missing', missing, {exists: false, elapsedSeconds: 0},
    {...row.observations[0], hittable: false}, {...row.observations[0], contained: false},
    {...row.observations[0], frame: undefined}, {...row.observations[0], window: [0]},
    {...row.observations[0], hittableQuerySeconds: undefined}, {...row.observations[0], existsQuerySeconds: -1}];
  for (const observation of incomplete) {
    assert.throws(() => diagnostic.auditPhoneObservations(log(Array(4).fill({...row, observations: [observation]}))), /observations/);
  }
  for (const geometry of [
    {window: [0, 0, 0, 0], frame: [0, 0, 0, 0]},
    {window: [0, 0, 400, 800], frame: [0, 0, 0, 0]},
    {window: [0, 0, 400, 800], frame: [-10, 600, 44, 44]},
    {window: [0, 0, 400, 800], frame: [10, 790, 44, 44]},
    {window: [0, 0, 400, 800], frame: [390, 600, 44, 44]}]) {
    const observation = {...row.observations[0], ...geometry, contained: true};
    assert.throws(() => diagnostic.auditPhoneObservations(log(Array(4).fill({...row, observations: [observation]}))), /observations/);
  }
});

test('diagnostic refuses private inputs or changed case classification before device allocation', () => {
  const catalogue = [phoneDiagnosticCase,
    'FoxUITests/FoxPhoneLayoutUITests/testFramingValidationRequiresEveryCorner',
    'FoxUITests/FoxPhoneLayoutUITests/testVisionOptionsLockCorrectionAndSavedReportRemainUsable']
    .map(id => ({id, scope: 'public', surface: 'iphone'}));
  assert.doesNotThrow(() => checkDiagnosticContext({}, catalogue));
  for (const key of ['FOX_PRIVATE_INPUT_MANIFEST', 'TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST']) {
    assert.throws(() => checkDiagnosticContext({[key]: '/private/manifest'}, catalogue), /private/i);
  }
  for (const rows of [[], catalogue.slice(0, 1), [{...catalogue[0], scope: 'private'}, ...catalogue.slice(1)],
    catalogue.map((x, i) => i === 2 ? {...x, surface: 'ipad'} : x)]) {
    assert.throws(() => checkDiagnosticContext({}, rows), /classification/);
  }
});

test('framing observations retain all rotations and the original per-channel tolerance', () => {
  const colors = [[0, 255, 0], [255, 0, 0], [255, 255, 0], [0, 0, 255]];
  const geometry = {window: [0, 0, 874, 402], preview: [372, 12, 428, 358]};
  const rows = [3, 4, 1].map(orientation => ({schema: 'fox.ui_framing_probe.v1', orientation,
    completed: true, deadlineSeconds: 4, elapsedSeconds: 0.4, stableSeconds: 0.3, cornerRGB: colors,
    observations: [{...geometry, elapsedSeconds: 0.1, stableSeconds: 0, cornerRGB: colors},
      {...geometry, elapsedSeconds: 0.4, stableSeconds: 0.3, cornerRGB: colors}]}));
  const log = values => values.map(x => `FOX_UI_FRAMING ${JSON.stringify(x)}`).join('\n');
  assert.doesNotThrow(() => diagnostic.auditFramingObservations(log(rows)));
  for (const change of [{orientation: 3}, {completed: false}, {deadlineSeconds: 8}, {elapsedSeconds: 4.1},
    {cornerRGB: colors.slice(0, 3)}, {cornerRGB: [[0, 235, 0], ...colors.slice(1)]}, {observations: []},
    {stableSeconds: 0}, {stableSeconds: 0.24}, {stableSeconds: 1}, {stableSeconds: undefined},
    {observations: [rows[1].observations[1]]},
    {observations: rows[1].observations.map((x, i) => i === 0 ? {...x, preview: [370, 12, 428, 358]} : x)}]) {
    assert.throws(() => diagnostic.auditFramingObservations(log([rows[0], {...rows[1], ...change}, rows[2]])), /framing/);
  }
  assert.throws(() => diagnostic.auditFramingObservations(log(rows.slice(0, 2))), /framing/);
  assert.throws(() => diagnostic.auditFramingObservations(log([...rows, rows[2]])), /framing/);
});

test('input completion requires exact text within four seconds with the first reading retained', () => {
  const ids = ['trial-information', 'trial-software-issue', 'trial-training-feeling'];
  const rows = ids.map((id, index) => ({schema: 'fox.ui_input_probe.v2', id, expected: `test ${index}`,
    immediateValue: 'test ', finalValue: `test ${index}`, completed: true, deadlineSeconds: 4, elapsedSeconds: 1.2,
    observations: [{value: 'test ', elapsedSeconds: 0.1, querySeconds: 0.1},
      {value: `test ${index}`, elapsedSeconds: 1.1, querySeconds: 0.1}]}));
  const log = values => values.map(value => `FOX_UI_INPUT ${JSON.stringify(value)}`).join('\n');
  assert.doesNotThrow(() => diagnostic.auditPhoneInputObservations(log(rows)));
  assert.doesNotThrow(() => diagnostic.auditPhoneInputObservations(log(rows.map(x => ({...x,
    immediateValue: x.expected, observations: [{value: x.expected, elapsedSeconds: 0.1, querySeconds: 0.1}]})))));
  for (const invalid of [rows.slice(0, 2), [...rows, rows[0]],
    rows.map(x => ({...x, immediateValue: 'wrong'})), rows.map(x => ({...x, expected: 'changed'})),
    rows.map(x => ({...x, finalValue: 'test '})), rows.map(x => ({...x, completed: false})),
    rows.map(x => ({...x, elapsedSeconds: 4.1})), rows.map(x => ({...x, elapsedSeconds: 0.5})),
    rows.map(x => ({...x, elapsedSeconds: 4.2, observations: [x.observations[0],
      {value: x.expected, elapsedSeconds: 4.1, querySeconds: 0.2}]})),
    rows.map(x => ({...x, observations: [x.observations[0], {...x.observations[1], querySeconds: 1.05}]})),
    rows.map(x => ({...x, deadlineSeconds: 8})), rows.map(x => ({...x, observations: []})),
    rows.map(x => ({...x, observations: [{value: 'test ', elapsedSeconds: 0.1, querySeconds: 0.1}]})),
    rows.map(x => ({...x, observations: [...x.observations, {value: x.expected, elapsedSeconds: 1.15, querySeconds: 0.1}]})),
    rows.map(x => ({...x, observations: x.observations.map(y => ({...y, querySeconds: -1}))})),
    rows.map(x => ({...x, schema: 'fox.ui_input_probe.v1', immediateMatched: false})),
    rows.map(x => ({schema: 'fox.ui_input_probe.v1', id: x.id, expected: x.expected,
      immediateValue: x.expected, immediateMatched: true, deadlineSeconds: 4, observations: []}))]) {
    assert.throws(() => diagnostic.auditPhoneInputObservations(log(invalid)), /input observations/);
  }
});

test('a specified diagnostic runtime/model is exact and never silently falls back', () => {
  const phone = {deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'};
  const pad = {deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch'};
  const other = {deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-Air'};
  const info = {simulators: {same: [phone, pad, other], different: [phone]}};
  assert.equal(diagnostic.diagnosticRuntime(info), info);
  assert.deepEqual(diagnostic.diagnosticRuntime(info, 'same').simulators, {same: [phone, pad]});
  assert.throws(() => diagnostic.diagnosticRuntime(info, 'missing'), /unavailable/);
  assert.throws(() => diagnostic.diagnosticRuntime({simulators: {same: [pad, other]}}, 'same'), /unavailable/);
});

test('native diagnostic adds the exact pad exercise-switch case without dropping phone cases', () => {
  const step = diagnostic.visionDiagnosticStep('owned-pad');
  assert.deepEqual(step.expectedNative, ['FoxUITests/FoxVisionUITests/testLateralRaiseCountsSavesSeparateExerciseAndThenCurlStillWorks']);
  assert.equal(step.env.FOX_IOS_UI_TEST, step.expectedNative.join(','));
  assert.equal(step.env.FOX_IOS_SIMULATOR, 'owned-pad');
  assert.equal(step.env.TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST, '');
  assert.equal(step.timeoutMs, 25 * 60 * 1000);
  const catalogue = diagnostic.phoneDiagnosticCases.map(id => ({id, scope: 'public', surface: 'iphone'}));
  assert.throws(() => checkDiagnosticContext({}, catalogue, true), /classification/);
  const vision = {id: step.expectedNative[0], scope: 'public', surface: 'ipad'};
  assert.doesNotThrow(() => checkDiagnosticContext({}, [...catalogue, vision], true));
  assert.throws(() => checkDiagnosticContext({}, [...catalogue, {...vision, surface: 'iphone'}], true), /classification/);
});

test('vision count diagnostics require both original two-count results, not later convergence', () => {
  const rows = ['lateral-raise', 'curl-after-relaunch'].map(stage => ({schema: 'fox.ui_count_probe.v1', stage,
    completed: true, deadlineSeconds: 12, elapsedSeconds: 9, expected: '2',
    observations: [{label: '0', elapsedSeconds: 1, querySeconds: 0.1},
      {label: '2', elapsedSeconds: 9, querySeconds: 0.1}], afterFailure: []}));
  const log = values => values.map(value => `FOX_UI_COUNT ${JSON.stringify(value)}`).join('\n');
  assert.doesNotThrow(() => diagnostic.auditVisionCountObservations(log(rows)));
  for (const changed of [{stage: 'lateral-raise'}, {completed: false}, {deadlineSeconds: 20}, {expected: '1'},
    {observations: []}, {observations: [{label: '1', elapsedSeconds: 9, querySeconds: 0.1}]},
    {observations: [{label: '2', elapsedSeconds: 9, querySeconds: -1}]},
    {completed: false, afterFailure: [{label: '2', elapsedSeconds: 13, querySeconds: 0.1}]},
    {afterFailure: [{label: '2', elapsedSeconds: 13, querySeconds: 0.1}]}]) {
    assert.throws(() => diagnostic.auditVisionCountObservations(log([rows[0], {...rows[1], ...changed}])), /count observations/);
  }
  assert.throws(() => diagnostic.auditVisionCountObservations(log(rows.slice(0, 1))), /count observations/);
  assert.throws(() => diagnostic.auditVisionCountObservations(log([...rows, rows[0]])), /count observations/);
});

test('diagnostic CLI rejects unknown, duplicate or ambiguous arguments before running', () => {
  assert.deepEqual(diagnostic.parseDiagnosticArguments(['out']), {output: 'out', includeVision: false});
  for (const args of [['out', '--vision'], ['--vision', 'out']]) {
    assert.deepEqual(diagnostic.parseDiagnosticArguments(args), {output: 'out', includeVision: true});
  }
  for (const args of [[], ['--vision'], [''], [' '], ['--visoin'], ['out', '--visoin'], ['--visoin', 'out'],
    ['out', 'other'], ['--vision', 'out', '--vision'], ['out', '-v'], ['--output', 'out']]) {
    assert.throws(() => diagnostic.parseDiagnosticArguments(args), /arguments/);
  }
});

test('the single diagnostic job budgets both cold-start batches plus setup and cleanup', () => {
  const workflow = readFileSync(new URL('../../.github/workflows/native-ui-diagnostic.yml', import.meta.url), 'utf8');
  const budgets = [...workflow.matchAll(/^    timeout-minutes: (\d+)\s*$/gm)].map(x => Number(x[1]));
  const required = Math.ceil((phoneDiagnosticStep('phone').timeoutMs + diagnostic.visionDiagnosticStep('pad').timeoutMs) / 60000) + 10;
  assert.deepEqual(budgets, [required], 'The outer job must not terminate either inner batch before its own timeout');
});
