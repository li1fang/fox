# Fox Say Corpus Capture Mode v0

## Status

Fox Say now supports a corpus capture mode for collecting real iPad voice samples with shape-only manifests.

This is still not realtime ASR/TTS integration. The goal is to collect labeled audio evidence safely before admitting ASR text into Fox workout state.

## Flow

```text
iPad recording
-> POST /say/capture
-> user labels the latest capture in Fox Say
-> POST /say/corpus-samples
-> runtime-only manifest under .tmp/fox-say-corpus
```

Raw audio stays in runtime capture storage. Git should only receive code, docs, and shape-only summaries.

## API

### `POST /say/corpus-samples`

Request:

```json
{
  "captureId": "say_...",
  "bucket": "training_feedback",
  "expectedText": "右肘有点酸，少做两次",
  "device": "iPad",
  "environment": "quiet_room",
  "noiseNotes": "iPad 近距离，无明显噪声",
  "speakerProfile": "owner"
}
```

Allowed buckets:

- `short_command`
- `training_feedback`
- `equipment_context`
- `mixed_utterance`
- `noise_distance`

Response sample:

```json
{
  "sample": {
    "schema": "fox.say_corpus_sample.v0",
    "sampleId": "fox-say-0001",
    "bucket": "training_feedback",
    "expectedText": "右肘有点酸，少做两次",
    "captureId": "say_...",
    "audioPath": "runtime-only/say_....m4a",
    "rawAudioCommitted": false
  }
}
```

The manifest also includes snake_case aliases for Linux/script compatibility.

### `GET /say/corpus-samples`

Returns recent sample manifests and a bucket summary.

## UI

Open:

```bash
npm run say:ipad-run
```

Then:

1. Tap `开始录音`.
2. Speak one sample.
3. Tap `停止并上传`.
4. Fill Corpus Capture metadata.
5. Tap `保存样本`.

If the page was refreshed after recording, tap `读取最近录音` to load the latest capture before labeling.

## Tests

```bash
npm run test -w @fox/api
npm run test:e2e
```

Coverage:

- capture API still rejects empty audio and exposes replay.
- corpus manifests reference runtime-only audio paths.
- corpus manifests keep `rawAudioCommitted=false`.
- Fox Say UI can load latest capture and save a labeled sample.
