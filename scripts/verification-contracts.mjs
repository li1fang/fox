import {isDeepStrictEqual} from 'node:util';

export const scopes = ['public', 'private', 'real-speech', 'physical'];
export function auditInventory(found, catalogue) {
  const expected = new Map(catalogue.map(x => [x.id, x]));
  if (expected.size !== catalogue.length) throw Error('Duplicate test classification');
  for (const row of catalogue) if (!scopes.includes(row.scope)) throw Error(`Unknown scope: ${row.id}`);
  for (const row of found) {
    const entry = expected.get(row.id);
    if (!entry) throw Error(`Unclassified test: ${row.id}`);
    if (entry.file !== row.file) throw Error(`Test moved; review classification: ${row.id}`);
    expected.delete(row.id);
  }
  if (expected.size) throw Error(`Missing test: ${[...expected.keys()].join(', ')}`);
}

export function auditNativeCoverage(output, expected) {
  const rows = [...output.matchAll(/^Test Case '(?:-\[([\w.]+) (\w+)\]|([\w.]+))' (passed|skipped|failed) /gm)].map(m => {
    const parts = m[1] ? [...m[1].split('.'), m[2]] : m[3].split('.');
    return {id: parts.slice(-2).join('/'), state: m[4]};
  });
  if (rows.some(r => r.state !== 'passed')) throw Error('Native test failed or skipped');
  if (new Set(rows.map(r => r.id)).size !== rows.length) throw Error('Native duplicate test execution');
  const wanted = expected.map(id => id.split('/').slice(-2).join('/')).sort();
  if (!rows.length || !isDeepStrictEqual(rows.map(r => r.id).sort(), wanted)) {
    const seen = new Set(rows.map(r => r.id));
    throw Error(`Native coverage mismatch; missing: ${wanted.filter(id => !seen.has(id)).join(', ')}; unexpected: ${rows.filter(r => !wanted.includes(r.id)).map(r => r.id).join(', ')}`);
  }
  return {passed: rows.length, skipped: [], cases: rows.map(r => r.id)};
}

export function auditReceipt(receipt, expected) {
  if (receipt.status !== 'software_suite_passed' || receipt.finalizationError
      || (receipt.environment?.simulatorLifecycle && receipt.environment.simulatorLifecycle.status !== 'released')
      || receipt.deviceVerified !== false || !receipt.steps?.length
      || receipt.steps.some(s => s.status !== 'passed')) throw Error('Incomplete software receipt');
  for (const key of ['commit', 'sourceSHA256', 'scope']) if (receipt[key] !== expected[key]) throw Error(`Receipt ${key} mismatch`);
  if (expected.component && receipt.component !== expected.component) throw Error('Receipt component mismatch');
  if (expected.stepIds && !isDeepStrictEqual(receipt.steps.map(s => s.id), expected.stepIds)) throw Error('Receipt step coverage mismatch');
}

export function auditCommandOutput(raw, kind) {
  const output = raw.replace(/\x1b\[[0-9;]*m/g, '');
  if (kind === 'node' || kind === 'web') {
    const passes = [...output.matchAll(/^# pass (\d+)/gm)].map(x => +x[1]);
    if (!passes.length || passes.some(x => x === 0) || /^# (?:fail|skipped|cancelled|todo) [1-9]/m.test(output)
        || /^# Subtest: tests\/scripts\/.*\.test\.mjs$/m.test(output)) throw Error('Node tests missing, failed or skipped');
    const vitest = [...output.matchAll(/Tests\s+(\d+) passed/g)].map(x => +x[1]);
    if (kind === 'web' && (!vitest.length || /\b[1-9]\d* (?:skipped|todo)\b/.test(output))) throw Error('Web unit tests missing or skipped');
    return {nodePassed: passes.reduce((a,b)=>a+b,0), ...(kind === 'web' ? {vitestPassed: vitest.reduce((a,b)=>a+b,0)} : {}), skipped: []};
  }
  if (kind === 'browser' && (!/\b[1-9]\d* passed/.test(output) || /\d+ (?:skipped|flaky|failed)/.test(output))) throw Error('Browser tests incomplete');
  if (kind === 'python') {
    const ran = output.match(/Ran ([1-9]\d*) tests?\b/);
    if (!ran || !/^OK\s*$/m.test(output) || /(?:skipped|expected failures|unexpected successes)=[1-9]/.test(output)
        || /^FAILED\b/m.test(output)) throw Error('Python tests incomplete');
    return {passed: Number(ran[1]), skipped: []};
  }
  return {scope: kind, skipped: []};
}

export function classifyDeviceError(message) {
  if (/locked|锁定/i.test(message)) return 'device_locked';
  if (/expired|过期/i.test(message)) return 'signature_expired';
  if (/verify app|untrusted|internet connection|验证.*App/i.test(message)) return 'developer_verification';
  if (/developer mode|开发者模式/i.test(message)) return 'developer_mode';
  if (/not found|unavailable|not connected/i.test(message)) return 'device_unavailable';
  return 'unknown';
}
