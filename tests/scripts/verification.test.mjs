import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm, cp, chmod} from 'node:fs/promises';
import {spawnSync, spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {validatePrivateInputs} from '../../scripts/private-inputs.mjs';
import * as privateInputs from '../../scripts/private-inputs.mjs';
import {discoverTests} from '../../scripts/test-inventory.mjs';
import * as developmentEnvironment from '../../scripts/development-environment.mjs';
import * as verificationContracts from '../../scripts/verification-contracts.mjs';
import * as verification from '../../scripts/verify.mjs';
import {execute as executeSuiteCommand} from '../../scripts/trial-suite.mjs';
import {auditInventory, auditNativeCoverage, auditReceipt, auditCommandOutput, classifyDeviceError} from '../../scripts/verification-contracts.mjs';

test('toolchain selection retains exact pins and distinguishes the general runtime from Duo-only support', () => {
  const legacy = developmentEnvironment.xcodeConfiguration('xcode-26.3');
  const modern = developmentEnvironment.xcodeConfiguration('xcode-27.1');
  assert.equal(legacy.version, 'Xcode 26.3\nBuild version 17C529');
  assert.equal(modern.version, 'Xcode 27.1\nBuild version 27A9275');
  assert.equal(modern.runtime, 'com.apple.CoreSimulator.SimRuntime.iOS-27-0');
  assert.equal(developmentEnvironment.resolveSimulatorRuntime(modern.id, null), modern.runtime);
  assert.equal(developmentEnvironment.resolveSimulatorRuntime(modern.id, 'explicit-runtime'), 'explicit-runtime');
  assert.doesNotThrow(() => developmentEnvironment.assertXcodeVersion(modern.version, modern.id));
  assert.throws(() => developmentEnvironment.assertXcodeVersion(modern.version, legacy.id), /expected Xcode 26.3/);
  assert.throws(() => developmentEnvironment.assertXcodeVersion('Xcode 27.2\nBuild version unknown', modern.id), /expected Xcode 27.1/);
  assert.throws(() => developmentEnvironment.xcodeConfiguration('latest'), /Unknown Xcode profile/);
  assert.throws(() => developmentEnvironment.resolveSimulatorRuntime('latest', 'explicit-runtime'), /Unknown Xcode profile/);
});

test('local default selects the accepted modern profile while CI pins its legacy compatibility lane explicitly', async () => {
  const env = {...process.env}; delete env.FOX_XCODE_PROFILE; delete env.FOX_SIMULATOR_RUNTIME;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e',
    'import {xcodeConfiguration} from "./scripts/development-environment.mjs"; console.log(JSON.stringify(xcodeConfiguration()))'],
  {cwd: developmentEnvironment.root, env, encoding: 'utf8'});
  assert.equal(result.status, 0, result.stderr);
  const profile = JSON.parse(result.stdout);
  assert.equal(profile.id, 'xcode-27.1');
  assert.equal(profile.runtime, 'com.apple.CoreSimulator.SimRuntime.iOS-27-0');
  for (const file of ['ci.yml', 'native-ui-diagnostic.yml']) {
    const text = await readFile(path.join(developmentEnvironment.root, '.github/workflows', file), 'utf8');
    assert.match(text, /FOX_XCODE_PROFILE: xcode-26\.3/);
    assert.match(text, /DEVELOPER_DIR: \/Applications\/Xcode_26\.3\.app\/Contents\/Developer/);
  }
});

test('Duo-only and unavailable runtime metadata reject unsupported models before claiming a session or creating anything', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-runtime-support-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const type = 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB';
  const info = {simulatorRuntime: 'duo-only', simulators: {'duo-only': []}, simulatorTypes: [{identifier: type}],
    simulatorRuntimes: [{identifier: 'duo-only', isAvailable: true,
      supportedDeviceTypes: [{identifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo'}]}]};
  const calls = [];
  const execute = async (...args) => {calls.push(args); throw Error('must not execute');};
  const sessionPath = path.join(dir, 'session');
  await assert.rejects(developmentEnvironment.allocateSimulators(info,
    {execute, sessionPath, families: ['ipad'], overrides: {}}), /runtime.*does not support.*iPad/);
  await assert.rejects(readFile(path.join(sessionPath, 'owner.json')), /ENOENT/);
  const phone = 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro';
  await assert.rejects(developmentEnvironment.allocateSimulators({...info,
    simulatorTypes: [...info.simulatorTypes, {identifier: phone}],
    simulatorRuntimes: [{...info.simulatorRuntimes[0], supportedDeviceTypes: [{identifier: type}]}]},
  {execute, sessionPath, overrides: {}}), /runtime.*does not support.*iPhone/);
  await assert.rejects(readFile(path.join(sessionPath, 'owner.json')), /ENOENT/);
  await assert.rejects(developmentEnvironment.allocateSimulators({...info,
    simulatorRuntimes: [{...info.simulatorRuntimes[0], isAvailable: false}]},
  {execute, sessionPath, families: ['ipad'], overrides: {}}), /runtime unavailable/);
  await assert.rejects(developmentEnvironment.allocateSimulators({...info, simulatorRuntimes: []},
    {execute, sessionPath, families: ['ipad'], overrides: {}}), /runtime unavailable/);
  assert.equal(calls.length, 0);
});

test('a supported general runtime with no persistent devices can create its pinned tablet without fallback', async () => {
  const type = 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB';
  const info = {simulatorRuntime: 'general', simulators: {}, simulatorTypes: [{identifier: type}],
    simulatorRuntimes: [{identifier: 'general', isAvailable: true, supportedDeviceTypes: [{identifier: type}]}]};
  const calls = [];
  const execute = async (command, args) => {calls.push(args); return args[1] === 'create' ? '00000000-0000-0000-0000-000000000001' : '';};
  const lease = await developmentEnvironment.allocateSimulators(info, {execute, coordinate: false, families: ['ipad'], overrides: {}});
  assert.equal(lease.selection.ipad.runtime, 'general');
  assert.equal(calls[0].at(-1), 'general');
  await developmentEnvironment.releaseSimulators(lease, execute);
});

test('a fresh modern runtime can create pinned models from installed device types without persistent template devices', async () => {
  const info = {simulatorRuntime: 'modern', simulators: {modern: [
    {udid: 'user-duo', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo'}]},
  simulatorTypes: [{identifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}]};
  const calls = [];
  const execute = async (command, args) => {calls.push(args); return args[1] === 'create' ? '00000000-0000-0000-0000-000000000001' : '';};
  const lease = await developmentEnvironment.allocateSimulators(info, {execute, coordinate: false, families: ['iphone'], overrides: {}});
  assert.equal(lease.selection.iphone.deviceType, 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro');
  assert.equal(calls[0].at(-1), 'modern');
  await developmentEnvironment.releaseSimulators(lease, execute);
  assert.ok(calls.every(args => !args.includes('user-duo')));
  await assert.rejects(developmentEnvironment.allocateSimulators(info,
    {execute, coordinate: false, families: ['iphone'], overrides: {iphone: 'not-present'}}), /invalid override/);
});

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

test('unknown native profile cannot preempt candidate mismatch or dirty-tree failed receipts', async t => {
  for (const kind of ['mismatch', 'dirty']) {
    const {cwd, git} = await candidateRepository(t);
    await cp(new URL('../../scripts/', import.meta.url), path.join(cwd, 'scripts'), {recursive: true});
    git('add', 'scripts');
    git('-c', 'user.name=Fox Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false',
      'commit', '-qm', 'synthetic scripts');
    const commit = git('rev-parse', 'HEAD');
    if (kind === 'dirty') await writeFile(path.join(cwd, 'source.txt'), 'preserved user edit');
    const output = path.join(cwd, '.tmp', kind);
    const result = spawnSync(process.execPath, ['scripts/verify.mjs', 'candidate', 'public',
      '--commit', kind === 'mismatch' ? '0'.repeat(40) : commit, '--output', output],
    {cwd, encoding: 'utf8', env: {...process.env, FOX_XCODE_PROFILE: 'unknown-profile',
      FOX_PRIVATE_INPUT_MANIFEST: '/must-not-be-read'}, timeout: 10_000});
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, kind === 'dirty' ? /candidate.*dirty/i : /candidate.*commit/i);
    const receipt = JSON.parse(await readFile(path.join(output, 'suite.json')));
    assert.equal(receipt.status, 'failed');
    assert.deepEqual(receipt.steps, []);
    assert.deepEqual(receipt.environment, {simulatorIsolation: []});
    if (kind === 'dirty') assert.equal(await readFile(path.join(cwd, 'source.txt'), 'utf8'), 'preserved user edit');
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

test('full verification owns isolated simulators and never deletes existing or explicit devices', async () => {
  const info = {simulatorRuntime: 'runtime-test', simulators: {'runtime-test': [
    {udid: 'existing-pad', name: 'Custom tablet', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB'},
    {udid: 'existing-phone', name: 'Custom phone', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}]}};
  const calls = []; let n = 0;
  const execute = (command, args) => { calls.push(args); return args[1] === 'create' ? `00000000-0000-0000-0000-00000000000${++n}` : ''; };
  const lease = await developmentEnvironment.allocateSimulators(info, {execute, coordinate: false, overrides: {}});
  assert.equal(lease.created.length, 2);
  assert.notEqual(lease.devices.ipad, 'existing-pad');
  await developmentEnvironment.releaseSimulators(lease, execute);
  assert.equal(calls.filter(args => args[1] === 'delete').length, 2);
  assert.ok(calls.every(args => !args.includes('existing-pad') && !args.includes('existing-phone')));
  calls.length = 0;
  const explicit = await developmentEnvironment.allocateSimulators(info, {execute, coordinate: false, overrides: {ipad: 'existing-pad', iphone: 'existing-phone'}});
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
  const info = {simulatorRuntime: 'runtime-test', simulators: {'runtime-test': [
    {udid: 'pad', name: 'iPad', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB'},
    {udid: 'phone', name: 'iPhone', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}]}};
  const calls = []; let n = 0;
  const owned = '00000000-0000-0000-0000-000000000001';
  const execute = (command, args) => {
    calls.push(args);
    if (args[1] === 'create') { if (++n === 2) throw Error('creation unavailable'); return owned; }
    return '';
  };
  await assert.rejects(developmentEnvironment.allocateSimulators(info, {execute, coordinate: false, overrides: {}}), /creation unavailable/);
  assert.ok(calls.some(args => args[1] === 'delete' && args[2] === owned));
  await assert.rejects(developmentEnvironment.releaseSimulators({created: [owned]}, () => { throw Error('cleanup unavailable'); }), /cleanup/);
  await assert.doesNotReject(developmentEnvironment.releaseSimulators({created: [owned]}, (command, args) => {
    if (args[1] === 'shutdown') throw Error('Unable to shutdown device in current state: Shutdown');
  }));
});

test('simulator runtime is pinned regardless of installation order and overrides cannot cross it', () => {
  const info = {simulators: {
    newer: [{udid: 'new', deviceTypeIdentifier: 'type.iPhone-Duo'}],
    stable: [{udid: 'old', deviceTypeIdentifier: 'type.iPhone-17-Pro'}]
  }};
  assert.deepEqual(developmentEnvironment.simulatorCandidates(info, 'stable').map(x => x.udid), ['old']);
  assert.throws(() => developmentEnvironment.simulatorCandidates(info, 'missing'), /runtime unavailable/);
});

test('simulator session excludes other worktrees and retains ownership after incomplete cleanup', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-sim-lock-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const directory = path.join(dir, 'session');
  const session = developmentEnvironment.acquireSimulatorSession(directory);
  assert.throws(() => developmentEnvironment.acquireSimulatorSession(directory), /simulator session busy/);
  assert.throws(() => developmentEnvironment.releaseSimulatorSession({...session, token: 'wrong'}), /ownership/);
  developmentEnvironment.saveSimulatorSession(session, {created: ['owned'], devices: {ipad: 'owned'}});
  assert.equal(JSON.parse(await readFile(path.join(directory, 'owner.json'), 'utf8')).created[0], 'owned');
  const child = spawnSync(process.execPath, ['--input-type=module', '-e',
    `import {acquireSimulatorSession} from ${JSON.stringify(new URL('../../scripts/development-environment.mjs', import.meta.url).href)}; acquireSimulatorSession(${JSON.stringify(directory)});`], {encoding: 'utf8'});
  assert.notEqual(child.status, 0);
  assert.match(child.stderr, /simulator session busy/);
  developmentEnvironment.releaseSimulatorSession(session);
  const next = developmentEnvironment.acquireSimulatorSession(directory);
  developmentEnvironment.releaseSimulatorSession(next);
});

test('foreign booted or booting simulators block without shutdown or deletion', async () => {
  const calls = [];
  const execute = async (command, args) => {
    calls.push(args);
    return JSON.stringify({devices: {stable: [{udid: 'other', name: 'Another project', state: 'Booted'}]}});
  };
  await assert.rejects(developmentEnvironment.assertSimulatorAvailability(['ours'], execute), /other.*Another project/);
  assert.deepEqual(calls, [['simctl', 'list', 'devices', '--json']]);
  await assert.doesNotReject(developmentEnvironment.assertSimulatorAvailability(['other'], execute));
  await assert.rejects(developmentEnvironment.assertSimulatorAvailability([], async () =>
    JSON.stringify({devices: {stable: [{udid: 'booting', state: 'Booting'}]}})), /booting/);
});

test('coordinated allocation records ownership, hands token to children and keeps failed cleanup recoverable', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-sim-lifecycle-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const sessionPath = path.join(dir, 'session');
  const info = {simulatorRuntime: 'stable', simulators: {stable: [
    {udid: 'template', deviceTypeIdentifier: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'}]}};
  const owned = '00000000-0000-0000-0000-000000000001';
  const execute = async (command, args) => args[1] === 'list' ? JSON.stringify({devices: {stable: []}})
    : args[1] === 'create' ? owned : '';
  const lease = await developmentEnvironment.allocateSimulators(info, {execute, sessionPath, families: ['iphone'], overrides: {}});
  const step = {id: 'phone', env: {FOX_IOS_SIMULATOR: owned}};
  await developmentEnvironment.isolateSimulatorStep(lease, step, execute);
  const owner = developmentEnvironment.readSimulatorSession(step.env.FOX_SIMULATOR_SESSION_TOKEN, sessionPath);
  assert.deepEqual(owner.created, [owned]);
  assert.equal(owner.creationIntents.length, 1);
  await assert.rejects(developmentEnvironment.releaseSimulators(lease, async () => {throw Error('unavailable');}), /cleanup failed/);
  assert.throws(() => developmentEnvironment.acquireSimulatorSession(sessionPath), /busy/);
  await developmentEnvironment.releaseSimulators(lease, execute);
  assert.throws(() => developmentEnvironment.readSimulatorSession(lease.session.token, sessionPath), /ENOENT/);
});

test('runtime overrides and fixed models fail before creation instead of falling through to new devices', async () => {
  const calls = [];
  const execute = async (command, args) => {calls.push(args); return '';};
  const info = {simulatorRuntime: 'stable', simulators: {
    newer: [{udid: 'new', deviceTypeIdentifier: 'type.iPhone-Duo'}],
    stable: [{udid: 'old', deviceTypeIdentifier: 'type.iPhone-Old'}]
  }};
  await assert.rejects(developmentEnvironment.allocateSimulators(info,
    {coordinate: false, execute, families: ['iphone'], overrides: {iphone: 'new'}}), /invalid override/);
  await assert.rejects(developmentEnvironment.allocateSimulators(info,
    {coordinate: false, execute, families: ['iphone'], overrides: {}}), /missing iPhone/);
  assert.equal(calls.length, 0);
});

test('partial successful cleanup persists progress and can resume without deleting an ID twice', async t => {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-sim-resume-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const session = developmentEnvironment.acquireSimulatorSession(path.join(dir, 'session'));
  const lease = {session, devices: {}, created: ['a', 'b']};
  developmentEnvironment.saveSimulatorSession(session, lease);
  const deleted = new Set(); let fail = true;
  const execute = async (command, args) => {
    assert.ok(!deleted.has(args[2]), 'already deleted ID must not be retried');
    if (args[1] === 'delete') {
      if (args[2] === 'b' && fail) throw Error('temporary delete failure');
      deleted.add(args[2]);
    }
  };
  await assert.rejects(developmentEnvironment.releaseSimulators(lease, execute), /cleanup failed/);
  assert.deepEqual(developmentEnvironment.readSimulatorSession(session.token, session.directory).released, ['a']);
  fail = false;
  await developmentEnvironment.releaseSimulators(lease, execute);
  assert.deepEqual([...deleted], ['a', 'b']);
});

async function fakeNativeCommands(t) {
  const dir = await mkdtemp(path.join(tmpdir(), 'fox-native-entry-'));
  t.after(() => rm(dir, {recursive: true, force: true}));
  const bin = path.join(dir, 'bin'); await mkdir(bin);
  const id = '00000000-0000-0000-0000-000000000001';
  const body = `#!${process.execPath}
import {appendFileSync,writeFileSync} from 'node:fs';
import path from 'node:path';
const name=path.basename(process.argv[1]), args=process.argv.slice(2);
appendFileSync(process.env.FOX_TEST_TRACE,JSON.stringify({name,args})+'\\n');
if(name==='xcrun' && args[1]==='list') {
 const family=process.env.FOX_TEST_FRESH_RUNTIME==='1'?'iPhone-Duo':'iPad-Pro-11-inch-M5-12GB';
 const tablet='com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB';
 const output=args[2]==='devicetypes'?{devicetypes:[{identifier:tablet}]}:
 args[2]==='runtimes'?{runtimes:[{identifier:process.env.FOX_SIMULATOR_RUNTIME,isAvailable:true,
 supportedDeviceTypes:[{identifier:process.env.FOX_TEST_DUO_ONLY==='1'?'com.apple.CoreSimulator.SimDeviceType.iPhone-Duo':tablet}]}]}:
 {devices:{[process.env.FOX_SIMULATOR_RUNTIME]:process.env.FOX_TEST_FRESH_RUNTIME==='1'?[]:[{udid:'${id}',state:'Shutdown',deviceTypeIdentifier:'com.apple.CoreSimulator.SimDeviceType.'+family}]}};
 console.log(JSON.stringify(output));
}
if(name==='xcrun' && args[1]==='create') console.log('${id}');
if(name==='xcodebuild') console.log('NATIVE_PARTIAL_OUTPUT');
if(name==='xcodebuild' && process.env.FOX_TEST_IDLE_EXPIRED==='1') console.log('    t = 60.00s App animations complete notification not received, will attempt to continue.');
if(name==='xcodebuild' && process.env.FOX_TEST_WAIT==='1'){writeFileSync(process.env.FOX_TEST_READY,String(process.pid));if(process.env.FOX_TEST_RESIST==='1')process.on('SIGTERM',()=>{});setTimeout(()=>{},60000);}
if(name==='xcrun' && args[1]==='delete' && process.env.FOX_TEST_CLEANUP_WAIT==='1'){writeFileSync(process.env.FOX_TEST_READY,'cleanup');setTimeout(()=>{},400);}
`;
  for (const name of ['xcrun', 'xcodegen', 'xcodebuild']) {
    const file = path.join(bin, name); await writeFile(file, body); await chmod(file, 0o755);
  }
  return {dir, id, env: {...process.env, HOME: dir, PATH: `${bin}:${process.env.PATH}`,
    FOX_SIMULATOR_SESSION_TOKEN: '', FOX_IOS_SIMULATOR: '', FOX_SIMULATOR_RUNTIME: 'com.apple.CoreSimulator.SimRuntime.iOS-26-3',
    FOX_TEST_TRACE: path.join(dir, 'trace.jsonl'), FOX_TEST_READY: path.join(dir, 'ready')}};
}

test('real UI child entry accepts the parent lease without path-format rejection or reacquisition', async t => {
  const fixture = await fakeNativeCommands(t);
  const session = developmentEnvironment.acquireSimulatorSession(path.join(fixture.dir, '.cache/fox/simulator-session'));
  developmentEnvironment.saveSimulatorSession(session, {created: [], devices: {ipad: fixture.id}});
  const result = spawnSync(process.execPath, ['scripts/ipad.mjs', 'test-ui'], {cwd: developmentEnvironment.root,
    env: {...fixture.env, FOX_SIMULATOR_SESSION_TOKEN: session.token, FOX_IOS_SIMULATOR: fixture.id}, encoding: 'utf8', timeout: 10_000});
  assert.equal(result.status, 0, result.stderr);
  const calls = (await readFile(fixture.env.FOX_TEST_TRACE, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.ok(calls.some(x => x.name === 'xcodebuild'));
  assert.ok(!calls.some(x => ['create', 'delete'].includes(x.args[1])));
  developmentEnvironment.releaseSimulatorSession(session);
});

test('direct modern UI entry creates its pinned tablet in an empty compatible general runtime', async t => {
  const fixture = await fakeNativeCommands(t);
  const result = spawnSync(process.execPath, ['scripts/ipad.mjs', 'test-ui'], {cwd: developmentEnvironment.root,
    env: {...fixture.env, FOX_XCODE_PROFILE: 'xcode-27.1', FOX_SIMULATOR_RUNTIME: 'com.apple.CoreSimulator.SimRuntime.iOS-27-0',
      FOX_TEST_FRESH_RUNTIME: '1'}, encoding: 'utf8', timeout: 10_000});
  assert.equal(result.status, 0, result.stderr);
  const calls = (await readFile(fixture.env.FOX_TEST_TRACE, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.ok(calls.some(x => x.args[1] === 'create' && x.args.includes('com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB')
    && x.args.at(-1) === 'com.apple.CoreSimulator.SimRuntime.iOS-27-0'));
});

test('native UI command preserves cases and result bundles without the unaccepted XCTest timeout mode', async t => {
  const fixture = await fakeNativeCommands(t);
  const output = path.join(fixture.dir, 'result.xcresult');
  const ids = ['FoxUITests/FoxDesignReviewUITests/testHomeScenarios', 'FoxUITests/FoxDesignReviewUITests/testHomeSmokeScenarios'];
  const result = spawnSync(process.execPath, ['scripts/ipad.mjs', 'test-ui'], {cwd: developmentEnvironment.root,
    env: {...fixture.env, FOX_IOS_UI_RESULT: output, FOX_IOS_UI_TEST: ids.join(',')}, encoding: 'utf8', timeout: 10_000});
  assert.equal(result.status, 0, result.stderr);
  const args = (await readFile(fixture.env.FOX_TEST_TRACE, 'utf8')).trim().split('\n').map(JSON.parse).find(x => x.name === 'xcodebuild').args;
  assert.equal(args[args.indexOf('-resultBundlePath') + 1], output);
  assert.equal(args[args.indexOf('-test-timeouts-enabled') + 1], 'NO');
  assert.equal(args.includes('-default-test-execution-time-allowance'), false);
  assert.equal(args.includes('-maximum-test-execution-time-allowance'), false);
  assert.deepEqual(args.filter(x => x.startsWith('-only-testing:')), ids.map(x => `-only-testing:${x}`));
});

test('direct native entry rejects animation-idle expiry and releases only its owned simulator', async t => {
  const fixture = await fakeNativeCommands(t);
  const result = spawnSync(process.execPath, ['scripts/ipad.mjs', 'test-ui'], {cwd: developmentEnvironment.root,
    env: {...fixture.env, FOX_TEST_IDLE_EXPIRED: '1'}, encoding: 'utf8', timeout: 10_000});
  assert.equal(result.status, 1);
  assert.match(result.stderr, /native_automation_idle_timeout/);
  const calls = (await readFile(fixture.env.FOX_TEST_TRACE, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.ok(calls.some(x => x.args[1] === 'delete' && x.args[2] === fixture.id));
  await assert.rejects(readFile(path.join(fixture.dir, '.cache/fox/simulator-session/owner.json')), /ENOENT/);
});

test('direct UI entry rejects a Duo-only runtime without a creation intent or stale claim', async t => {
  const fixture = await fakeNativeCommands(t);
  const result = spawnSync(process.execPath, ['scripts/ipad.mjs', 'test-ui'], {cwd: developmentEnvironment.root,
    env: {...fixture.env, FOX_XCODE_PROFILE: 'xcode-27.1', FOX_SIMULATOR_RUNTIME: 'com.apple.CoreSimulator.SimRuntime.iOS-27-1',
      FOX_TEST_FRESH_RUNTIME: '1', FOX_TEST_DUO_ONLY: '1'}, encoding: 'utf8', timeout: 10_000});
  assert.equal(result.status, 1, result.stderr);
  assert.match(result.stderr, /runtime.*does not support.*iPad/);
  const calls = (await readFile(fixture.env.FOX_TEST_TRACE, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.ok(calls.some(x => x.args[2] === 'runtimes'));
  assert.ok(!calls.some(x => ['create', 'delete'].includes(x.args[1]) || x.name === 'xcodebuild'));
  await assert.rejects(readFile(path.join(fixture.dir, '.cache/fox/simulator-session/owner.json')), /ENOENT/);
});

test('simulator builds share the explicit isolated derived-data path with UI verification', async t => {
  const fixture = await fakeNativeCommands(t);
  const derived = path.join(fixture.dir, 'modern-derived');
  const result = spawnSync(process.execPath, ['scripts/ipad.mjs', 'build-simulator'], {cwd: developmentEnvironment.root,
    env: {...fixture.env, FOX_IOS_UI_DERIVED_DATA: derived}, encoding: 'utf8', timeout: 10_000});
  assert.equal(result.status, 0, result.stderr);
  const builds = (await readFile(fixture.env.FOX_TEST_TRACE, 'utf8')).trim().split('\n').map(JSON.parse).filter(x => x.name === 'xcodebuild');
  assert.equal(builds.length, 2);
  assert.ok(builds.every(x => x.args[x.args.indexOf('-derivedDataPath') + 1] === derived));
});

test('direct UI entry cancels its command, releases owned simulators and frees the shared session', {timeout: 15_000}, async t => {
  const fixture = await fakeNativeCommands(t);
  const child = spawn(process.execPath, ['scripts/ipad.mjs', 'test-ui'], {cwd: developmentEnvironment.root,
    env: {...fixture.env, FOX_TEST_WAIT: '1'}, stdio: ['ignore', 'ignore', 'pipe']});
  t.after(() => {if (child.exitCode === null) child.kill('SIGKILL');});
  let stderr = ''; child.stderr.on('data', bytes => {stderr += bytes;});
  const closed = new Promise(resolve => child.on('close', (code, signal) => resolve({code, signal})));
  const deadline = Date.now() + 8000;
  while (true) {
    try {await readFile(fixture.env.FOX_TEST_READY); break;} catch {}
    assert.equal(child.exitCode, null, stderr);
    assert.ok(Date.now() < deadline, 'fake build did not start');
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  child.kill('SIGTERM');
  const result = await closed;
  assert.equal(result.code, 1, stderr);
  const calls = (await readFile(fixture.env.FOX_TEST_TRACE, 'utf8')).trim().split('\n').map(JSON.parse);
  assert.ok(calls.some(x => x.args[1] === 'delete' && x.args[2] === fixture.id));
  await assert.rejects(readFile(path.join(fixture.dir, '.cache/fox/simulator-session/owner.json')), /ENOENT/);
});

test('suite cancellation kills a resistant inherited native child and retains partial output', {timeout: 15_000}, async t => {
  const fixture = await fakeNativeCommands(t);
  const session = developmentEnvironment.acquireSimulatorSession(path.join(fixture.dir, '.cache/fox/simulator-session'));
  developmentEnvironment.saveSimulatorSession(session, {created: [], devices: {ipad: fixture.id}});
  const logPath = path.join(fixture.dir, 'outer.log');
  await assert.rejects(executeSuiteCommand({command: process.execPath, args: ['scripts/ipad.mjs', 'test-ui'], timeoutMs: 2000,
    env: {...fixture.env, FOX_TEST_WAIT: '1', FOX_TEST_RESIST: '1', FOX_SIMULATOR_SESSION_TOKEN: session.token,
      FOX_IOS_SIMULATOR: fixture.id}}, {logPath}), /timed out/);
  assert.match(await readFile(logPath, 'utf8'), /NATIVE_PARTIAL_OUTPUT/);
  const pid = Number(await readFile(fixture.env.FOX_TEST_READY, 'utf8'));
  assert.throws(() => process.kill(pid, 0), /ESRCH/);
  developmentEnvironment.releaseSimulatorSession(session);
});

test('cancellation during direct cleanup cannot exit successfully', {timeout: 10_000}, async t => {
  const fixture = await fakeNativeCommands(t);
  const child = spawn(process.execPath, ['scripts/ipad.mjs', 'test-ui'], {cwd: developmentEnvironment.root,
    env: {...fixture.env, FOX_TEST_CLEANUP_WAIT: '1'}, stdio: 'ignore'});
  t.after(() => {if (child.exitCode === null) child.kill('SIGKILL');});
  const closed = new Promise(resolve => child.on('close', code => resolve(code)));
  const deadline = Date.now() + 6000;
  while (true) {
    try {await readFile(fixture.env.FOX_TEST_READY); break;} catch {}
    assert.equal(child.exitCode, null);
    assert.ok(Date.now() < deadline);
    await new Promise(resolve => setTimeout(resolve, 25));
  }
  child.kill('SIGTERM');
  assert.equal(await closed, 1);
  await assert.rejects(readFile(path.join(fixture.dir, '.cache/fox/simulator-session/owner.json')), /ENOENT/);
});
