import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {validatePrivateInputs} from '../../scripts/private-inputs.mjs';
import {auditInventory, auditNativeCoverage, auditReceipt, auditCommandOutput, classifyDeviceError} from '../../scripts/verification-contracts.mjs';

test('private inputs are explicit, complete, pinned and rechecked, never an implicit local cache', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-input-test-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const file = path.join(dir, 'input.json'), manifest = path.join(dir, 'manifest.json');
  await writeFile(file, 'synthetic');
  const hash = createHash('sha256').update('synthetic').digest('hex');
  const contract = {schema: 'fox.private_input_contract.v1', assets: {sample: {sha256: hash, purpose: 'Synthetic unit test'}}};
  await assert.rejects(validatePrivateInputs(undefined, contract), /FOX_PRIVATE_INPUT_MANIFEST.*sample/);
  await writeFile(manifest, JSON.stringify({schema: 'fox.private_inputs.v1', assets: {}}));
  await assert.rejects(validatePrivateInputs(manifest, contract), /sample/);
  await writeFile(manifest, JSON.stringify({schema: 'fox.private_inputs.v1', assets: {sample: {path: file, sha256: hash, bytes: 9}}}));
  assert.equal((await validatePrivateInputs(manifest, contract)).length, 1);
  await writeFile(file, 'tampered');
  await assert.rejects(validatePrivateInputs(manifest, contract), /digest|bytes/);
  const selfSigned = createHash('sha256').update('tampered').digest('hex');
  await writeFile(manifest, JSON.stringify({schema: 'fox.private_inputs.v1', assets: {sample: {path: file, sha256: selfSigned, bytes: 8}}}));
  await assert.rejects(validatePrivateInputs(manifest, contract), /pinned/);
});

test('new or removed native cases and unknown classifications fail the inventory gate', () => {
  const found = [{id: 'Core/Example/testOne', file: 'Example.swift'}];
  assert.throws(() => auditInventory(found, []), /Unclassified/);
  assert.throws(() => auditInventory([], [{...found[0], scope: 'public'}]), /Missing/);
  assert.throws(() => auditInventory(found, [{...found[0], scope: 'maybe'}]), /scope/);
  assert.doesNotThrow(() => auditInventory(found, [{...found[0], scope: 'public'}]));
});

test('a native batch must execute every selected case once without unexpected extras or skips', () => {
  const one = "Test Case '-[Core.Example testOne]' passed (0.1 seconds).";
  assert.throws(() => auditNativeCoverage('** TEST SUCCEEDED **', ['Core/Example/testOne']), /coverage/);
  assert.throws(() => auditNativeCoverage(one, ['Core/Example/testOne', 'Core/Example/testTwo']), /coverage/);
  assert.throws(() => auditNativeCoverage(one.replace('passed', 'skipped'), ['Core/Example/testOne']), /skipped/);
  assert.throws(() => auditNativeCoverage(one + '\n' + one, ['Core/Example/testOne']), /duplicate/);
  assert.equal(auditNativeCoverage(one, ['Core/Example/testOne']).passed, 1);
});

test('cross-commit, wrong-scope, cancelled, incomplete and physical claims cannot reuse software green', () => {
  const receipt = {status: 'software_suite_passed', commit: 'abc', sourceSHA256: 'hash', scope: 'public',
    deviceVerified: false, steps: [{status: 'passed'}]};
  const expected = {commit: 'abc', sourceSHA256: 'hash', scope: 'public'};
  assert.doesNotThrow(() => auditReceipt(receipt, expected));
  for (const changed of [{commit: 'def'}, {scope: 'private'}, {status: 'cancelled'}, {steps: []}, {deviceVerified: true}]) {
    assert.throws(() => auditReceipt({...receipt, ...changed}, expected));
  }
});

test('device errors remain environment conditions, not algorithm failures or permission bypass advice', () => {
  assert.equal(classifyDeviceError('The device is locked'), 'device_locked');
  assert.equal(classifyDeviceError('Unable to verify app: internet connection required'), 'developer_verification');
  assert.equal(classifyDeviceError('Provisioning profile has expired'), 'signature_expired');
  assert.equal(classifyDeviceError('Unknown failure'), 'unknown');
});

test('non-native zero, skipped and placeholder-file tests cannot be counted as coverage', () => {
  assert.throws(() => auditCommandOutput('0 passed','browser'), /incomplete/);
  assert.throws(() => auditCommandOutput('# pass 1\n# skipped 1','node'), /skipped/);
  assert.throws(() => auditCommandOutput('# Subtest: tests/scripts/empty.test.mjs\n# pass 1','node'), /missing/);
  assert.throws(() => auditCommandOutput('Tests 1 passed | 1 skipped\n# pass 1','web'), /skipped/);
  assert.throws(() => auditCommandOutput('Ran 7 tests\nOK (skipped=1)','python'), /incomplete/);
});
