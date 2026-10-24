import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, access, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { archiveVideo, sha256 } from '../../scripts/vision-corpus.mjs';

test('private corpus move verifies bytes, preserves full asset, and refuses overwrite', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'fox-corpus-'));
  try {
    const source = path.join(root, 'draft.mov');
    await writeFile(source, 'complete-video-with-bystanders');
    const draft = { sha256: await sha256(source), duration_seconds: 200.366667, segments: [], negative_windows: [],
      known_events: [{ time: 133, kind: 'brief-interruption', estimated_step_metres_less_than: 0.05 }] };
    const result = await archiveVideo({ source, draft, root, id: 'reference-01', move: true });
    assert.equal(await readFile(result.destination, 'utf8'), 'complete-video-with-bystanders');
    await assert.rejects(access(source));
    const manifest = JSON.parse(await readFile(result.manifestPath, 'utf8'));
    assert.equal(manifest.audio_is_annotation_not_counter_input, true);
    assert.equal(manifest.known_events[0].kind, 'brief-interruption');
    await writeFile(source, 'complete-video-with-bystanders');
    await assert.rejects(archiveVideo({ source, draft, root, id: 'reference-01', move: true }), /EEXIST/);
    await access(source);
    await assert.rejects(archiveVideo({ source, draft: { ...draft, sha256: 'wrong' }, root, id: 'reference-02', move: true }), /checksum/);
    await access(source);
    await assert.rejects(archiveVideo({ source, draft: { ...draft, duration_seconds: 0 }, root, id: 'reference-03', move: true }), /timeline/);
    await access(source);
    const unrelated = await archiveVideo({ source, draft: { ...draft, known_events: [] }, root, id: 'reference-04' });
    assert.deepEqual(JSON.parse(await readFile(unrelated.manifestPath, 'utf8')).known_events, []);
  } finally { await rm(root, { recursive: true, force: true }); }
});
