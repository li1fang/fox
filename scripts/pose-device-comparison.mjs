import { readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { isDeepStrictEqual } from 'node:util';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { summarizeComparison } from './pose-experiment-report.mjs';

export function numericallyEqual(a, b) {
  if (typeof a === 'number' && typeof b === 'number') return Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= 1e-9;
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const keys = Object.keys(a).sort();
    return isDeepStrictEqual(keys, Object.keys(b).sort()) && keys.every(key => numericallyEqual(a[key], b[key]));
  }
  return a === b;
}

export function verifyDeviceReplay({ videoSHA256, status, device, host, mac, deviceCache, macCache }) {
  if (status.schema !== 'fox.ipad_pose_probe_status.v1' || status.phase !== 'completed'
      || status.error != null || status.source !== 'device-video-not-camera') throw new Error('Device run not completed');
  for (const [report, cache] of [[device, deviceCache], [host, deviceCache], [mac, macCache]]) {
    if (report.schema !== 'fox.pose_comparison_evaluation.v1' || report.backend !== 'vision'
        || report.videoSHA256 !== videoSHA256 || cache.header.videoSHA256 !== videoSHA256
        || cache.header.schema !== 'fox.pose_comparison_cache.v1'
        || report.inputSHA256 !== cache.sha256) throw new Error('Report/cache source mismatch');
    if (!isDeepStrictEqual(report.configuration, device.configuration)
        || !isDeepStrictEqual(report.runtimePolicy, device.runtimePolicy)) throw new Error('Counter parameters changed');
  }
  if (deviceCache.header.source !== 'device-video-not-camera'
      || device.inferencePlatform !== deviceCache.header.platform
      || host.inferencePlatform !== deviceCache.header.platform
      || device.platform !== deviceCache.header.platform || status.platform !== device.platform) throw new Error('Device provenance mismatch');
  if (!numericallyEqual(device.segments, host.segments)) throw new Error('Device/host core replay differs on the same poses');
  const a = macCache.rows, b = deviceCache.rows;
  if (!a.length || a.length !== b.length) throw new Error('Frame coverage differs');
  let pngEqual = 0, peopleCountDifferent = 0;
  for (let i = 0; i < a.length; i++) {
    if (!numericallyEqual(a[i].seconds, b[i].seconds) || a[i].width !== b[i].width || a[i].height !== b[i].height
        || !Number.isFinite(b[i].seconds) || (i && b[i].seconds <= b[i - 1].seconds)
        || b[i].imagePNG != null || !/^[a-f0-9]{64}$/.test(b[i].imageSHA256)) throw new Error('Frame alignment or privacy check failed');
    if (a[i].imageSHA256 === b[i].imageSHA256) pngEqual++;
    if (a[i].people.length !== b[i].people.length) peopleCountDifferent++;
  }
  return { frames: a.length, firstSeconds: b[0].seconds, lastSeconds: b.at(-1).seconds,
    sameEncodedPNGs: pngEqual, differentEncodedPNGs: a.length - pngEqual, peopleCountDifferent,
    note: 'Different PNG hashes can reflect platform decoding/encoding; they do not isolate inference alone',
    coreReplayParity: 'all segments and per-event fields equal within 1e-9 on identical device poses' };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const [planPath, labelsPath, macPath, devicePath, hostPath, macCachePath, deviceCachePath, statusPath, output] = process.argv.slice(2);
    if (!output) throw new Error('Usage: pose-device-comparison <plan> <labels> <mac-report> <device-report> <host-report> <mac-cache> <device-cache> <status> <new-output>');
    const json = async p => JSON.parse(await readFile(p, 'utf8'));
    const cache = async p => {
      const bytes = await readFile(p), lines = bytes.toString('utf8').trim().split('\n').map(l => JSON.parse(l));
      return { sha256: createHash('sha256').update(bytes).digest('hex'), header: lines[0], rows: lines.slice(1) };
    };
    const plan = await json(planPath), labels = await json(labelsPath), mac = await json(macPath), device = await json(devicePath);
    const verification = verifyDeviceReplay({ videoSHA256: plan.videoSHA256, status: await json(statusPath),
      mac, device, host: await json(hostPath), macCache: await cache(macCachePath), deviceCache: await cache(deviceCachePath) });
    const summarize = (report, platform) => ({ ...summarizeComparison(plan, labels, [report]),
      evidenceBoundary: `${platform} offline development video; not live camera or independent accuracy` });
    const result = { schema: 'fox.pose_device_comparison.v1', videoSHA256: plan.videoSHA256,
      verification, mac: summarize(mac, 'Mac'), ipad: summarize(device, 'iPad'),
      ipadControls: device.segments.filter(s => s.id === 'front-exploration').map(s => ({ side: s.side,
        diagnosticCount: s.diagnostic.count, gatedCount: s.gated.count,
        exitDiagnosticCount: s.negativeWindowDiagnosticCount, exitGatedCount: s.negativeWindowGatedCount })) };
    await writeFile(output, JSON.stringify(result, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
    console.log(JSON.stringify(verification));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
