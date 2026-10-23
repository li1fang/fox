# Fox Say Guided Flow 1.1

## Goal

Make Fox Say understandable before adding more intelligence.

The app now separates three jobs:

- `日常记录`: record or load a capture, read ASR, create a draft, and see completion state.
- `测试链路`: generate local smoke data without iPad or Linux.
- `收件箱`: review, edit, discard, or confirm voice drafts.

## Product Contract

- The default screen must show the current stage instead of exposing every tool at once.
- The user must be able to see whether recording, ASR, draft creation, review, and Entry creation are done.
- Test mode must create reviewable drafts using existing API contracts only.
- Review Inbox remains the only place where voice drafts become confirmed Entries.
- Debug tools can remain available, but they must not dominate the first screen.

## Current User Flow

### Daily Record

1. Upload or load a capture.
2. Read the latest ASR result.
3. Create a draft.
4. Review the selected draft in Inbox.
5. Confirm it into an Entry.

The receipt shows:

- Entry id or pending state.
- Entry kind.
- `Audio=false` for raw audio committed status.
- `Workout state=false` for state-machine mutation.

### Local Test

`测试链路` has a one-click smoke path:

```text
fake capture
-> guided-test ASR results
-> two needs_review drafts
-> Review Inbox
```

This proves that the UI and Fox API can handle the review workflow without depending on the iPad microphone, Linux ASR, or VCompose availability.

### Debug Details

The older tools are still present under `调试详情`:

- Browser/iPad fallback TTS.
- Browser speech recognition.
- Corpus Capture.
- Session policy diagnostics.

## Test Gates

- `npx playwright test tests/e2e/fox-say-corpus.spec.ts`
- `npm run verify`
- `npm run test:e2e`

The key 1.1 E2E case is:

```text
open Fox Say
-> open 测试链路
-> 生成测试草稿
-> land in 收件箱
-> see generated needs_review drafts
```

The native iPad recording bridge is also covered by browser-side contract tests:

- success: mocked `window.webkit.messageHandlers.foxPadAudioCapture` emits `started` and `uploaded`, and the UI shows the latest capture.
- Swift failure: mocked native error includes code, message, domain, status/context, and the UI surfaces the diagnostic instead of a generic failure.
- bridge exception: `postMessage` throws before reaching Swift, and the UI returns to a retryable state.

## Boundary

This is still not realtime streaming, not automatic command admission, and not LLM extraction. It is the UX layer that makes the current staged voice pipeline understandable and testable.
