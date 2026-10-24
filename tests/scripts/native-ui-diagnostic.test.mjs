import test from 'node:test';
import assert from 'node:assert/strict';
import {phoneDiagnosticCase, phoneDiagnosticStep, checkDiagnosticContext} from '../../scripts/native-ui-diagnostic.mjs';
import * as diagnostic from '../../scripts/native-ui-diagnostic.mjs';
import {auditReceipt} from '../../scripts/verification-contracts.mjs';

test('phone diagnostic is one fixed synthetic case, never a full-suite substitute', () => {
  const step = phoneDiagnosticStep('owned-phone');
  assert.deepEqual(step.expectedNative, [phoneDiagnosticCase]);
  assert.equal(step.env.FOX_IOS_UI_TEST, phoneDiagnosticCase);
  assert.equal(step.env.FOX_IOS_SIMULATOR, 'owned-phone');
  assert.equal(step.env.TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST, '');
  assert.equal(step.env.TEST_RUNNER_FOX_REAL_SPEECH, '0');
  assert.equal(step.timeoutMs, 15 * 60 * 1000);
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
  const catalogue = [{id: phoneDiagnosticCase, scope: 'public', surface: 'iphone'}];
  assert.doesNotThrow(() => checkDiagnosticContext({}, catalogue));
  for (const key of ['FOX_PRIVATE_INPUT_MANIFEST', 'TEST_RUNNER_FOX_PRIVATE_INPUT_MANIFEST']) {
    assert.throws(() => checkDiagnosticContext({[key]: '/private/manifest'}, catalogue), /private/i);
  }
  for (const rows of [[], [{...catalogue[0], scope: 'private'}], [{...catalogue[0], surface: 'ipad'}]]) {
    assert.throws(() => checkDiagnosticContext({}, rows), /classification/);
  }
});

test('input diagnostics retain the original exact-value result even if it later settles', () => {
  const ids = ['trial-information', 'trial-software-issue', 'trial-training-feeling'];
  const rows = ids.map((id, index) => ({schema: 'fox.ui_input_probe.v1', id, expected: `test ${index}`,
    immediateValue: `test ${index}`, immediateMatched: true, deadlineSeconds: 4, observations: []}));
  const log = values => values.map(value => `FOX_UI_INPUT ${JSON.stringify(value)}`).join('\n');
  assert.doesNotThrow(() => diagnostic.auditPhoneInputObservations(log(rows)));
  for (const invalid of [rows.slice(0, 2), [...rows, rows[0]],
    rows.map((x, index) => index === 2 ? {...x, immediateValue: 'test ', immediateMatched: false,
      observations: [{value: 'test 2', elapsedSeconds: 0.2}]} : x),
    rows.map(x => ({...x, immediateValue: 'wrong'})), rows.map(x => ({...x, expected: 'changed'})),
    rows.map(x => ({...x, immediateMatched: false})), rows.map(x => ({...x, deadlineSeconds: 8})),
    rows.map(x => ({...x, observations: [{value: x.expected, elapsedSeconds: 0.2}]}))]) {
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
