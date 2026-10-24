import { createHash } from 'node:crypto';
import { createReadStream, constants } from 'node:fs';
import { copyFile, mkdir, readFile, stat, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export async function sha256(file) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}

export async function archiveVideo({ source, draft, root, id, move = false }) {
  if (!/^[a-z0-9][a-z0-9_-]{1,70}$/.test(id)) throw new Error('Invalid corpus id');
  const hash = await sha256(source);
  if (hash !== draft.sha256) throw new Error('Source checksum differs from the reviewed video');
  if (!Number.isFinite(draft.duration_seconds) || draft.duration_seconds <= 0 || !Array.isArray(draft.segments) ||
      draft.segments.some(segment => !Number.isFinite(segment.start) || !Number.isFinite(segment.end) ||
        segment.start < 0 || segment.start >= segment.end || segment.end > draft.duration_seconds)) {
    throw new Error('Invalid reviewed timeline; source preserved');
  }
  const directory = path.resolve(root, id);
  await mkdir(directory, { recursive: true });
  const asset = `${id}.mov`, destination = path.join(directory, asset);
  // No overwrite; source is removed only after both verified video and manifest exist.
  await copyFile(source, destination, constants.COPYFILE_EXCL);
  if (await sha256(destination) !== hash) throw new Error('Archive verification failed; source preserved');
  const manifest = {
    schema: 'fox.video_corpus.v1', id, asset, sha256: hash,
    bytes: (await stat(destination)).size, duration_seconds: draft.duration_seconds,
    source_kind: draft.source_kind, original_filename: path.basename(source),
    label_status: draft.label_status, audio_is_annotation_not_counter_input: true,
    mirror_status: 'unknown', device_inclination_degrees: null,
    clips_are_virtual_original_timeline: true, peak_visual_review: draft.peak_visual_review,
    weight_source: draft.weight_source, framing_notes: draft.framing_notes,
    negative_windows: draft.negative_windows, segments: draft.segments,
    known_events: draft.known_events ?? [],
    subject_checkpoints: draft.subject_checkpoints ?? [],
    privacy: 'Local private corpus; contains bystanders; do not commit or upload'
  };
  const manifestPath = path.join(directory, 'manifest.json');
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, { flag: 'wx' });
  if (move) await unlink(source);
  return { destination, manifestPath, sha256: hash, sourceRemoved: move };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const value = name => args[args.indexOf(name) + 1];
  try {
    if (!args.includes('--source') || !args.includes('--draft') || !args.includes('--id'))
      throw new Error('Usage: npm run vision:corpus -- --source <mov> --draft <json> --id <id> [--move]');
    const result = await archiveVideo({ source: value('--source'),
      draft: JSON.parse(await readFile(value('--draft'), 'utf8')),
      root: path.resolve('.data/vision-corpus'), id: value('--id'), move: args.includes('--move') });
    console.log(JSON.stringify(result, null, 2));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
