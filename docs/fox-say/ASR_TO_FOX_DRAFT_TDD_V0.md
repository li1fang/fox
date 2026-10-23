# Fox Say ASR To Fox Draft TDD v0

## Goal

Build the first safe bridge from Fox Say to Fox:

```text
Fox Say recording
-> Linux ASR result
-> reviewable Fox draft
-> manual confirmation
-> confirmed Entry
```

This stage is intentionally review-first. ASR text may create a draft, but it must not directly mutate the workout state machine, start timers, finish sets, or create a confirmed Entry without user confirmation.

## Product Contract

- Fox Say can upload audio as an immutable runtime capture.
- Linux ASR can submit transcript evidence that references a capture.
- Fox can turn an ASR result into a typed draft: `meal`, `medical`, `workout`, `expense`, or `note`.
- The draft starts as `needs_review`.
- The user can edit/confirm the draft.
- Confirmation creates one `confirmed` Entry with:
  - raw transcript,
  - audio evidence pointer,
  - extracted draft JSON,
  - confirmed JSON,
  - source `voice_draft`.

## Non Goals

- No automatic workout state changes from ASR text.
- No streaming latency claim.
- No direct ASR model hosting inside the Mac API.
- No raw audio path exposure in confirmed Entries.
- No automatic replacement of user corrections with later model output.

## TDD Gates

### T1: Linux ASR Result Ingestion

Given a valid Fox Say capture, `POST /say/asr-results` accepts a Linux ASR transcript and stores:

- `schema=fox.say_asr_result.v0`
- `captureId`
- `provider`
- `transcript`
- `rawAudioCommitted=false`

It does not create a confirmed Entry.

### T2: Reviewable Draft Creation

Given an ASR result, `POST /say/drafts` creates a draft:

- `schema=fox.voice_draft.v0`
- `status=needs_review`
- `entryType` inferred or explicitly supplied
- `rawText` equal to the ASR transcript
- `evidence.uri=fox-say-capture:<captureId>`
- no raw local audio path

### T3: Manual Confirmation

Given a draft, `POST /say/drafts/:id/confirm` creates a confirmed Entry only after user confirmation:

- `status=confirmed`
- `source=voice_draft`
- `sourceDraftId=<draft id>`
- `rawText=<ASR transcript>`
- `confirmedJson` uses user-confirmed payload

### T4: Workout State Boundary

ASR result ingestion, draft creation, and draft confirmation must not dispatch workout events or advance the current workout session.

### T5: Fox Say UI Smoke

Fox Say can:

1. load the latest ASR result,
2. create a reviewable draft,
3. edit the confirmation text,
4. confirm it into Fox,
5. display the confirmed Entry id.

### T5b: Review Inbox

Fox Say can list multiple voice drafts and let the user handle them one by one:

- show `needs_review` drafts by default,
- switch to all draft statuses,
- select a draft,
- edit `entryType`, title, confirmation text, and structured JSON,
- save edits with `PATCH /say/drafts/:id`,
- discard a draft without creating an Entry,
- confirm a selected draft into a voice-sourced Entry.

Confirmed drafts and discarded drafts must not be silently mutated back into pending work.

### T5c: Guided Flow 1.1

Fox Say can be tested without guessing the order of operations:

- `日常记录` shows capture, ASR, draft, review, and Entry stages.
- `测试链路` can create local fake capture, ASR evidence, and reviewable drafts in one action.
- `收件箱` remains the confirmation surface.
- `调试详情` contains advanced/debug tools instead of putting them on the default screen.

The local smoke path must make it obvious that drafts were created and that the next step is inbox review.

### T6: Real Linux ASR Runner Smoke

Given a latest iPad capture, `npm run say:linux-asr`:

- exports the original runtime capture,
- creates a derived `16kHz mono wav` for Linux ASR,
- submits VCompose template `fox/k3s-heavy-gpu-fox-say-sensevoice-latest-capture-asr`,
- waits for `fox-say-latest-capture-sensevoice-v0.json`,
- verifies the report matches the latest capture derivative,
- posts the transcript to `POST /say/asr-results`.

Verified run:

```text
job=job-1782929178-5ea870d0c5532b
asr_result_id=asr_1782929185333_27c4873d
draft_id=draft_1782929213885_21695272
transcript=吃葡萄不吐葡大皮。
draft_status=needs_review
raw_audio_committed=false
```

The smoke may create a review draft, but it must not auto-confirm the draft or mutate the workout state machine.
