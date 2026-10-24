# Fox Say Roundtrip and Corpus Handoff v0

## Status

Fox Say is now a preview handoff path, not a finished voice product.

Companion ledgers:

- Test plan: `docs/fox-say/HANDOFF_TEST_PLAN_V0.zh-CN.md`
- Corpus capture mode: `docs/fox-say/CORPUS_CAPTURE_MODE_V0.md`
- ASR to Fox draft TDD: `docs/fox-say/ASR_TO_FOX_DRAFT_TDD_V0.md`
- Guided flow 1.1: `docs/fox-say/GUIDED_FLOW_1_1.md`
- v0.2 retrospective: `docs/fox-say/V0_2_RETROSPECTIVE.zh-CN.md`
- Feature ledger: `docs/fox-say/feature-ledger.v0.json`
- Task ledger: `docs/fox-say/tasks.v0.json`

What is green:

- Fox and Fox Say are separate iPad apps backed by shared WKWebView shell code.
- `Fox` uses Bundle ID `com.whipa.fox` and defaults to the main Fox route.
- `Fox Say` uses Bundle ID `com.whipa.foxsay` and defaults to `/?mode=say`.
- iPad Fox Say can capture microphone audio through the native iPad audio bridge. Browser `MediaRecorder` remains a fallback for browsers that expose it.
- `apps/api` accepts `POST /say/capture`, stores runtime audio under `.tmp`, and exposes latest metadata plus audio replay.
- `npm run say:export-capture` exports the latest capture to VCompose runtime storage.
- `npm run say:handoff-smoke` runs the full latest-capture handoff smoke: export, VCompose submit, report polling, and local summary.
- Fox Say can label latest captures into corpus sample manifests with `POST /say/corpus-samples`.
- Fox API can receive Linux ASR result evidence with `POST /say/asr-results`.
- `npm run say:linux-asr` runs the latest iPad capture through Linux SenseVoice and posts the real transcript back to Fox API.
- Fox Say can turn a Linux ASR result into a `needs_review` Fox draft and manually confirm it into a `confirmed` Entry.
- Fox Say has a Review Inbox for listing pending voice drafts, editing type/title/structured JSON, discarding drafts, and confirming selected drafts into Entries.
- Fox Say has a guided 1.1 flow with `日常记录`, `测试链路`, and `收件箱` workspaces, plus a one-click local smoke that generates test drafts.
- Fox Say v0.3 creates durable ASR jobs for each capture. The normal iPad flow queues ASR after upload and visibly reports `queued`, `running`, `succeeded`, or `failed` instead of waiting on one long HTTP request.
- Fox Say can queue an explicit Mac clipboard delivery. A loopback-only Mac bridge claims the text and writes it to the clipboard; this does not auto-paste, create an Entry, or mutate workout state.
- ASR result ingestion, draft creation, and draft confirmation do not mutate the workout state machine.
- VCompose has a roundtrip smoke gate that verifies:
  - capture metadata and audio reached Linux storage,
  - existing Linux ASR corpus evidence is green,
  - existing Linux TTS evidence is green,
  - a playback package can be generated.

What is not green yet:

- Full realtime iPad -> Linux streaming -> TTS playback latency.
- Natural high-quality TTS on-device. The browser/iPad `speechSynthesis` path is a basic fallback; attractive voice output remains a Linux TTS/runtime path.
- 50-100 real human/iPad/noise sample matrix.
- Native iPad UI polish.
- Automatic speech-driven workout state changes.
- VAD-backed automatic segmentation, voiceprint context, and ASR fine-tuning.

## Current Daily Input Path

The current daily path is documented in `V0_3_INPUT_CHAIN_ROADMAP.zh-CN.md`:

```text
iPad recording
-> Fox API ASR job
-> Linux SenseVoice
-> capture-bound transcript
-> Mac clipboard or Fox review draft
```

Use:

```bash
npm run say:ipad-run
```

For `Fox Say`, this starts the Mac clipboard bridge as well as the local API/Web runtime. It writes only after the iPad explicitly chooses `发送到 Mac`; pasting into the focused Mac app remains a manual `Command-V` action.

## Current Real ASR Path

Run latest-capture ASR after recording on iPad:

```bash
npm run say:linux-asr
```

This command:

1. exports the latest runtime capture,
2. creates a derived `16kHz mono wav` for Linux ASR while preserving the original iPad `m4a`,
3. submits VCompose template `fox/k3s-heavy-gpu-fox-say-sensevoice-latest-capture-asr`,
4. polls `/srv/vcompose/output/fox/voice/runtime/asr-benchmark/fox-say-latest-capture-sensevoice-v0.json`,
5. posts the transcript to `POST /say/asr-results`.

Latest verified real run:

```text
job=job-1782929178-5ea870d0c5532b
provider=linux-sensevoice
transcript=吃葡萄不吐葡大皮。
asr_result_id=asr_1782929185333_27c4873d
draft_id=draft_1782929213885_21695272
raw_audio_committed=false
```

The generated draft remains `needs_review`; it is not automatically confirmed into an Entry.

## Current Smoke Path

Start local services:

```bash
npm run say:ipad-run
```

This command starts the API on `0.0.0.0:4177`, starts the web runtime on `0.0.0.0:5177`, and opens Fox Say on the iPad.

If services are already running and you only need to reopen the page:

```bash
npm run ipad:open:say
```

Do not use plain `npm run dev:api` for iPad testing; it listens on localhost and the iPad cannot reach `:4177`.

On the iPad page:

1. Tap `开始录音`.
2. Accept the iPad microphone prompt if this is the first run.
3. Speak one short training command or feedback sentence.
4. Tap `停止并上传`.
5. Confirm the page shows a latest capture id, byte size, and sha256 prefix.
6. Tap `运行当前录音 ASR`.
7. Confirm the ASR text appears.

`读取最近录音` only loads the latest uploaded capture metadata/audio from Fox API. It does not play audio by itself; playback is the audio control shown after a capture is loaded. `运行当前录音 ASR` starts the staged Linux ASR runner for the currently selected latest capture. `读取当前录音 ASR` only rereads an ASR result that has already been posted for the currently selected capture.

Terminal fallback:

```bash
npm run say:linux-asr
```

Use this if the iPad-triggered runner fails and you want the raw command-line report.

If the page is opened inside `Fox Say`, the supported recording path is the native iPad bridge. WKWebView may not expose `MediaRecorder`; that is expected and should not be treated as a failed browser feature.

If native recording fails, the page should show a diagnostic such as:

```text
iPad 原生录音失败：native_recording_start_failed · <iOS error message> · <domain>#<code> · context beginRecording
```

This means the JavaScript bridge is alive and Swift reported the underlying failure. If the page says `iPad 原生录音桥启动失败`, the JavaScript `postMessage` call failed before Swift received the request.

Export the latest capture to VCompose:

```bash
npm run say:export-capture
```

Or run the whole handoff smoke in one command:

```bash
npm run say:handoff-smoke
```

Expected local summary:

```text
.tmp/fox-say-handoff-smoke-report.json
```

The summary should say:

- `schema=fox.say_handoff_smoke_report.v0`
- `decision=fox_say_handoff_smoke_ready`
- `linux_asr_ready=true`
- `linux_tts_ready=true`
- `full_realtime_e2e_measured=false`
- `raw_audio_committed=false`

Run the VCompose smoke gate on Linux:

```bash
ssh fox-voice-host 'cd /srv/fox-voice/VCompose && go run ./cmd/vfctl submit -f examples/job-fox-voice-roundtrip-smoke-gate.yaml --submitter fox-say-handoff'
```

Expected report:

```text
/srv/vcompose/output/fox/voice/runtime/e2e/fox-voice-ipad-linux-roundtrip-smoke-v0.json
```

The smoke report should say:

- `decision=roundtrip_capture_linux_evidence_ready`
- `full_realtime_e2e_measured=false`
- `raw_audio_committed=false`

The strict realtime report intentionally remains not green:

```text
/srv/vcompose/output/fox/voice/runtime/e2e/fox-voice-ipad-linux-roundtrip-v0.json
```

Its current next constraint is:

```text
human_ipad_noisy_corpus_matrix_with_streaming_latency
```

## Sample Matrix Plan

The next owner should collect 50-100 real samples using the iPad microphone.

Recommended buckets:

| Bucket | Count | Examples |
| --- | ---: | --- |
| Short commands | 15-20 | 完成本组, 准备好了, 跳过, 紧急停止, 加 30 秒 |
| Training feedback | 15-20 | 太重了, 少做两次, 右肘有点酸, 动作不确定 |
| Equipment/context | 10-15 | 哑铃有 2.5 到 25kg, 地面不干净, 今天睡眠一般 |
| Mixed utterances | 10-15 | 一句话同时包含训练反馈、产品反馈、记录修正 |
| Noise and distance | 10-20 | 跑步机, 风扇, 远距离 iPad 收音, 房间回声 |

Minimum manifest fields:

```json
{
  "sample_id": "fox-say-0001",
  "bucket": "short_command",
  "expected_text": "完成本组",
  "audio_path": "runtime-only/path.wav",
  "device": "iPad",
  "environment": "quiet_room",
  "noise_notes": "",
  "speaker_profile": "owner",
  "created_at": "2026-07-01T00:00:00Z"
}
```

Do not commit raw audio. Keep audio in runtime storage and commit only manifests, summaries, and shape-only reports.

## Handoff Boundary

This handoff is suitable for a UI/native team to take over:

- Build a better iPad recording UI.
- Replace staged upload/export with a streaming WebSocket or native bridge.
- Route Linux ASR text into Fox workout commands.
- Route Linux TTS audio back to iPad playback.
- Optionally send recognized text to Mac input as a dictation bridge.

This handoff is not asking the next team to select ASR/TTS models from scratch. The current technical direction is:

- ASR main candidate: SenseVoice/FunASR on Linux GPU.
- ASR fallback: faster-whisper or whisper.cpp depending on hardware.
- TTS current evidence: cached short-response playback is green.
- Scheduler policy: background lifecycle and foreground session policy have gate artifacts in VCompose.

## Evidence Pointers

VCompose evidence paths:

- `runtime/asr-corpus/sensevoice-small-fox-chinese-corpus-v0.json`
- `runtime/tts/fox-voice-tts-candidate-matrix-v0.json`
- `runtime/scheduler/fox-voice-scheduler-policy-v0.json`
- `runtime/e2e/fox-voice-ipad-linux-roundtrip-smoke-v0.json`

Fox local interfaces:

- `POST /say/capture`
- `GET /say/captures/latest`
- `GET /say/captures/:id/audio`
- `POST /say/corpus-samples`
- `GET /say/corpus-samples`
- `POST /say/asr-results`
- `GET /say/asr-results/latest`
- `POST /say/drafts`
- `GET /say/drafts`
- `PATCH /say/drafts/:id`
- `POST /say/drafts/:id/confirm`
- `GET /entries?source=voice_draft`
- `npm run say:export-capture`
- `npm run say:linux-asr`
