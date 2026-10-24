import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm, cp} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {validatePrivateInputs} from '../../scripts/private-inputs.mjs';
import * as privateInputs from '../../scripts/private-inputs.mjs';
import {discoverTests} from '../../scripts/test-inventory.mjs';
import * as developmentEnvironment from '../../scripts/development-environment.mjs';
import * as verificationContracts from '../../scripts/verification-contracts.mjs';
import * as verification from '../../scripts/verify.mjs';
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
  const found = [{id: 'FoxTrainingCoreTests/Example/testOne', file: 'Example.swift', surface: 'host'}];
  assert.throws(() => auditInventory(found, []), /Unclassified/);
  assert.throws(() => auditInventory([], [{...found[0], scope: 'public'}]), /Missing/);
  assert.throws(() => auditInventory(found, [{...found[0], scope: 'maybe'}]), /scope/);
  assert.doesNotThrow(() => auditInventory(found, [{...found[0], scope: 'public'}]));
});

test('missing or incompatible execution surfaces cannot silently exclude classified tests', () => {
  for (const [id, valid] of [['FoxTrainingCoreTests/Example/testOne', ['host']],
    ['FoxJournalCoreTests/Example/testOne', ['host']], ['FoxAppTests/Example/testOne', ['ipad', 'iphone']],
    ['FoxUITests/Example/testOne', ['ipad', 'iphone']], ['tests/scripts/example.test.mjs', ['host']]]) {
    const row = {id, file: 'Example', scope: 'public'};
    for (const surface of [undefined, '', 'watch', ...['host', 'ipad', 'iphone'].filter(x => !valid.includes(x))]) {
      assert.throws(() => auditInventory([row], [{...row, surface}]), /surface/, `${id}: ${surface}`);
    }
    for (const surface of valid) assert.doesNotThrow(() => auditInventory([row], [{...row, surface}]));
  }
});

test('native selection must cover the declared tier and component, with exclusions explicit', () => {
  const catalogue = [
    ['FoxTrainingCoreTests/A/testOne', 'public'], ['FoxTrainingCoreTests/A/testPrivate', 'private'],
    ['FoxJournalCoreTests/A/testOne', 'public'], ['FoxAppTests/A/testOne', 'public'],
    ['FoxAppTests/A/testPrivate', 'private'], ['FoxUITests/A/testOne', 'public'],
    ['FoxAppTests/A/testSpeech', 'real-speech'], ['FoxAppTests/A/testDevice', 'physical']
  ].map(([id, scope]) => ({id, scope}));
  for (const scope of ['fast', 'public', 'private']) for (const component of ['all', 'web', 'native']) {
    const expected = component === 'web' ? [] : catalogue.filter(x => x.scope === 'public'
      || scope === 'private' && ['private', 'real-speech'].includes(x.scope))
      .filter(x => scope !== 'fast' || /^(FoxTrainingCoreTests|FoxJournalCoreTests)\//.test(x.id)).map(x => x.id);
    const steps = [{expectedNative: expected}];
    const audit = rows => verificationContracts.auditNativeSelection(catalogue, rows, {scope, component});
    assert.doesNotThrow(() => audit(steps));
    if (expected.length) assert.throws(() => audit([{expectedNative: expected.slice(1)}]), /selection.*missing/);
    assert.throws(() => audit([{expectedNative: [...expected, 'FoxAppTests/A/testDevice']}]), /selection.*unexpected/);
  }
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
  for (const changed of [{commit: 'def'}, {scope: 'private'}, {status: 'cancelled'}, {steps: []}, {deviceVerified: true},
    {finalizationError: 'cleanup failed'}, {environment: {simulatorLifecycle: {status: 'allocated'}}}]) {
    assert.throws(() => auditReceipt({...receipt, ...changed}, expected));
  }
});

async function candidateRepository(t) {
  const cwd = await mkdtemp(path.join(tmpdir(), 'fox-candidate-test-'));
  t.after(() => rm(cwd, {recursive: true, force: true}));
  const git = (...args) => {
    const result = spawnSync('git', args, {cwd, encoding: 'utf8'});
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  git('init', '-q');
  await writeFile(path.join(cwd, '.gitignore'), '.tmp/\n');
  await writeFile(path.join(cwd, 'source.txt'), 'original');
  git('add', '.');
  git('-c', 'user.name=Fox Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
    'commit', '-qm', 'synthetic fixture');
  return {cwd, git, commit: git('rev-parse', 'HEAD')};
}

test('candidate preflight binds a full commit and permits ignored evidence, without changing Git state', async t => {
  const {cwd, git, commit} = await candidateRepository(t);
  assert.equal(verification.checkCandidate(commit, cwd).commit, commit);
  for (const value of [undefined, '', 'HEAD', commit.slice(0, 7), '0'.repeat(40)]) {
    assert.throws(() => verification.checkCandidate(value, cwd), /candidate.*commit/i);
  }
  await mkdir(path.join(cwd, '.tmp'));
  await writeFile(path.join(cwd, '.tmp', 'evidence.log'), 'keep');
  assert.equal(verification.checkCandidate(commit, cwd).commit, commit);
  assert.equal(git('status', '--porcelain'), '');
  assert.equal(await readFile(path.join(cwd, '.tmp', 'evidence.log'), 'utf8'), 'keep');
  const outside = await mkdtemp(path.join(tmpdir(), 'fox-no-git-'));
  t.after(() => rm(outside, {recursive: true, force: true}));
  assert.throws(() => verification.checkCandidate(commit, outside), /candidate.*git/i);
});

test('candidate preflight rejects unstaged, staged, untracked and deleted sources, preserving bytes', async t => {
  for (const kind of ['unstaged', 'staged', 'untracked', 'deleted']) {
    const {cwd, git, commit} = await candidateRepository(t);
    const file = path.join(cwd, kind === 'untracked' ? 'new file.txt' : 'source.txt');
    if (kind === 'deleted') await rm(file); else await writeFile(file, 'user change');
    if (kind === 'staged') git('add', 'source.txt');
    const before = git('status', '--porcelain');
    assert.throws(() => verification.checkCandidate(commit, cwd), /candidate.*dirty/i, kind);
    assert.equal(git('status', '--porcelain'), before);
    if (kind !== 'deleted') assert.equal(await readFile(file, 'utf8'), 'user change');
  }
});

test('candidate CLI requires an explicit tier and commit; typos cannot fall back to ordinary verification', () => {
  const commit = 'a'.repeat(40);
  assert.deepEqual(verification.parseVerificationArgs(['candidate', 'public', '--commit', commit, '--component', 'web', '--output', '/run']),
    {action: 'run', scope: 'public', candidateCommit: commit, component: 'web', output: '/run'});
  assert.equal(verification.parseVerificationArgs(['fast']).candidateCommit, undefined);
  assert.equal(verification.parseVerificationArgs(['public', '--component', 'native']).component, 'native');
  assert.equal(verification.parseVerificationArgs(['receipt', '/run/suite.json', '--scope', 'private']).action, 'receipt');
  for (const args of [[], ['candidate'], ['candidate', 'fast', '--commit', commit], ['candidate', 'public'],
    ['candidate', 'public', '--commit', 'HEAD'], ['candidate', 'private', '--commit', commit, '--component', 'web'],
    ['public', '--candidate', commit], ['candidate', 'public', '--comit', commit],
    ['candidate', 'public', '--commit', commit, '--commit', commit], ['public', '--output'],
    ['public', '--component', 'watch'], ['public', 'unexpected'], ['receipt', '--scope', 'public']]) {
    assert.throws(() => verification.parseVerificationArgs(args), /candidate|argument|option|scope|component|usage/i, args.join(' '));
  }
});

test('real candidate entry rejects dirty source before inventory, toolchain or simulator work and retains failure', async t => {
  const {cwd, git, commit} = await candidateRepository(t);
  await cp(new URL('../../scripts/', import.meta.url), path.join(cwd, 'scripts'), {recursive: true});
  const output = path.join(cwd, '.tmp', 'rejected');
  const result = spawnSync(process.execPath, ['scripts/verify.mjs', 'candidate', 'public', '--commit', commit, '--output', output],
    {cwd, encoding: 'utf8', env: {...process.env, FOX_PRIVATE_INPUT_MANIFEST: ''}, timeout: 10000});
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /candidate.*dirty/i);
  const receipt = JSON.parse(await readFile(path.join(output, 'suite.json')));
  assert.equal(receipt.status, 'failed');
  assert.equal(receipt.candidateCommit, commit);
  assert.deepEqual(receipt.steps, []);
  assert.deepEqual(receipt.environment, {simulatorIsolation: []});
  assert.equal(git('rev-parse', 'HEAD'), commit);
  // Ordinary iteration must still reach its existing preflight on the same dirty tree.
  const ordinary = spawnSync(process.execPath, ['scripts/verify.mjs', 'fast', '--output', path.join(cwd, '.tmp', 'ordinary')],
    {cwd, encoding: 'utf8', env: {...process.env, FOX_PRIVATE_INPUT_MANIFEST: ''}, timeout: 10000});
  assert.equal(ordinary.status, 1);
  assert.doesNotMatch(ordinary.stderr, /candidate.*dirty/i);
  assert.match(ordinary.stderr, /ENOENT/);
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

test('full verification owns isolated simulators and never deletes existing or explicit devices', async () => {
  const info = {simulators: {'runtime-test': [
    {udid: 'existing-pad', name: 'Custom tablet', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch'},
    {udid: 'existing-phone', name: 'Custom phone', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}]}};
  const calls = []; let n = 0;
  const execute = (command, args) => { calls.push(args); return args[1] === 'create' ? `00000000-0000-0000-0000-00000000000${++n}` : ''; };
  const lease = await developmentEnvironment.allocateSimulators(info, {execute, overrides: {}});
  assert.equal(lease.created.length, 2);
  assert.notEqual(lease.devices.ipad, 'existing-pad');
  await developmentEnvironment.releaseSimulators(lease, execute);
  assert.equal(calls.filter(args => args[1] === 'delete').length, 2);
  assert.ok(calls.every(args => !args.includes('existing-pad') && !args.includes('existing-phone')));
  calls.length = 0;
  const explicit = await developmentEnvironment.allocateSimulators(info, {execute, overrides: {ipad: 'existing-pad', iphone: 'existing-phone'}});
  assert.deepEqual(explicit.devices, {ipad: 'existing-pad', iphone: 'existing-phone'});
  await developmentEnvironment.releaseSimulators(explicit, execute);
  assert.equal(calls.length, 0);
});

test('native steps park only owned peer simulators before switching between phone and pad', async () => {
  const lease = {devices: {ipad: 'owned-pad', iphone: 'owned-phone'}, created: ['owned-pad', 'owned-phone']};
  const calls = [], execute = async (command, args) => { calls.push([command, ...args]); return ''; };
  const phone = await developmentEnvironment.isolateSimulatorStep(lease, {id: 'phone', env: {FOX_IOS_SIMULATOR: 'owned-phone'}}, execute);
  assert.deepEqual(calls, [['xcrun', 'simctl', 'shutdown', 'owned-pad']]);
  assert.deepEqual(phone, {step: 'phone', target: 'owned-phone', parked: ['owned-pad']});
  calls.length = 0;
  await developmentEnvironment.isolateSimulatorStep(lease, {id: 'speech', env: {FOX_IOS_SIMULATOR: 'owned-pad'}}, execute);
  assert.deepEqual(calls, [['xcrun', 'simctl', 'shutdown', 'owned-phone']]);
});

test('simulator isolation preserves overrides and refuses unknown targets without any commands', async () => {
  const lease = {devices: {ipad: 'existing-pad', iphone: 'owned-phone'}, created: ['owned-phone']};
  const calls = [], execute = async (command, args) => { calls.push([command, ...args]); return ''; };
  await developmentEnvironment.isolateSimulatorStep(lease, {id: 'phone', env: {FOX_IOS_SIMULATOR: 'owned-phone'}}, execute);
  assert.equal(calls.length, 0);
  assert.equal(await developmentEnvironment.isolateSimulatorStep(lease, {id: 'web'}, execute), undefined);
  await assert.rejects(developmentEnvironment.isolateSimulatorStep(lease, {id: 'bad', env: {FOX_IOS_SIMULATOR: 'unrelated'}}, execute), /lease/);
  assert.equal(calls.length, 0);
});

test('simulator isolation accepts already stopped peers but fails closed on shutdown failure', async () => {
  const lease = {devices: {ipad: 'pad', iphone: 'phone'}, created: ['pad', 'phone']};
  const step = {id: 'phone', env: {FOX_IOS_SIMULATOR: 'phone'}};
  await assert.doesNotReject(developmentEnvironment.isolateSimulatorStep(lease, step, async () => {
    throw Error('Unable to shutdown device in current state: Shutdown');
  }));
  await assert.rejects(developmentEnvironment.isolateSimulatorStep(lease, step, async () => {
    throw Error('service unavailable');
  }), /service unavailable/);
});

test('partial simulator allocation cleans only owned instances and cleanup failures are explicit', async () => {
  const info = {simulators: {'runtime-test': [
    {udid: 'pad', name: 'iPad', deviceTypeIdentifier: 'type.iPad-Pro-11-inch'},
    {udid: 'phone', name: 'iPhone', deviceTypeIdentifier: 'type.iPhone-17-Pro'}]}};
  const calls = []; let n = 0;
  const owned = '00000000-0000-0000-0000-000000000001';
  const execute = (command, args) => {
    calls.push(args);
    if (args[1] === 'create') { if (++n === 2) throw Error('creation unavailable'); return owned; }
    return '';
  };
  await assert.rejects(developmentEnvironment.allocateSimulators(info, {execute, overrides: {}}), /creation unavailable/);
  assert.ok(calls.some(args => args[1] === 'delete' && args[2] === owned));
  await assert.rejects(developmentEnvironment.releaseSimulators({created: [owned]}, () => { throw Error('cleanup unavailable'); }), /cleanup/);
  await assert.doesNotReject(developmentEnvironment.releaseSimulators({created: [owned]}, (command, args) => {
    if (args[1] === 'shutdown') throw Error('Unable to shutdown device in current state: Shutdown');
  }));
});
