import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {validatePrivateInputs} from '../../scripts/private-inputs.mjs';
import * as privateInputs from '../../scripts/private-inputs.mjs';
import {discoverTests} from '../../scripts/test-inventory.mjs';
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
  assert.throws(() => auditCommandOutput('Ran 3 tests\nOK (expected failures=3)','python'), /incomplete/);
  assert.equal(auditCommandOutput('Ran 3 tests in 0.03s\n\nOK\n','python').passed, 3);
});

test('nested tests are discovered across native, Python and browser directories', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-discovery-test-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const folders = ['apps/ipad/FoxTrainingCore/Tests/FoxTrainingCoreTests', 'apps/ipad/FoxJournalCore/Tests/FoxJournalCoreTests',
    'apps/ipad/FoxAppTests', 'apps/ipad/FoxUITests', 'tests/scripts', 'tests/e2e', 'packages/core/test', 'apps/api/test'];
  for (const folder of folders) await mkdir(path.join(dir, folder, 'nested'), {recursive: true});
  await writeFile(path.join(dir, folders[0], 'nested/Example.swift'), 'final class Example: XCTestCase {\nfunc testNested() {}\n@MainActor func testActor() {}\npublic func testPublic() {}\n}');
  await writeFile(path.join(dir, 'tests/scripts/nested/test_extra.py'), '');
  await writeFile(path.join(dir, 'tests/e2e/nested/extra.spec.ts'), '');
  const found = await discoverTests(dir);
  assert.equal(found.length, 5);
  for (const id of ['FoxTrainingCoreTests/Example/testNested', 'FoxTrainingCoreTests/Example/testActor', 'FoxTrainingCoreTests/Example/testPublic',
    'tests/scripts/nested/test_extra.py', 'tests/e2e/nested/extra.spec.ts']) {
    assert.ok(found.some(row => row.id === id), id);
  }
  assert.throws(() => auditInventory(found, []), /Unclassified/);
});

test('private batch consumers must use the pinned files, not unpinned siblings', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-bindings-test-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const manifest = {schema: 'fox.private_inputs.v1', assets: {}};
  const contract = {schema: 'fox.private_input_contract.v1', assets: {}};
  const contents = {job: ['job.json', JSON.stringify({files: [{path: 'input.jsonl'}]})], asset0: ['input.jsonl', 'poses'],
    status: ['status.json', JSON.stringify({files: [{path: 'result.json'}, {path: 'settings.json'}, {path: 'vision.jsonl'}]})],
    result: ['result.json', '{}'], settings: ['settings.json', '{}'], vision: ['vision.jsonl', 'observations']};
  for (const [key, [name, bytes]] of Object.entries(contents)) {
    const file = path.join(dir, name); await writeFile(file, bytes);
    const sha256 = createHash('sha256').update(bytes).digest('hex');
    manifest.assets[`sample.${key}`] = {path: file, bytes: Buffer.byteLength(bytes), sha256};
    contract.assets[`sample.${key}`] = {sha256, purpose: 'Synthetic binding test'};
  }
  const file = path.join(dir, 'manifest.private.json');
  const save = () => writeFile(file, JSON.stringify(manifest));
  await save();
  assert.deepEqual(await privateInputs.privateBatchFolders('sample', file, contract), {jobFolder: dir, resultFolder: dir});
  for (const key of ['job', 'status', 'asset0', 'result', 'settings', 'vision']) {
    const row = manifest.assets[`sample.${key}`], original = row.path;
    row.path = path.join(dir, `frozen-${key}`); await writeFile(row.path, contents[key][1]); await save();
    await assert.rejects(privateInputs.privateBatchFolders('sample', file, contract), /binding/);
    row.path = original;
  }
});
