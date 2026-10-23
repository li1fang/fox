# Fox Agent Entry

Read [current state](docs/development/CURRENT.md) first. This file is a routing guide, not a substitute for source or runtime evidence.

## Work Contract

- State outcome, non-goals, invariants, affected modules, acceptance tests and stop conditions before editing. Use [the task contract](docs/development/task-contract.example.json) for substantial work.
- Read existing code and focused tests; add a failing regression before changing behavior.
- Preserve dirty changes, private originals and on-device records. Do not reset, uninstall, deploy, renew signing or change device networking without explicit authorization for that operation.
- A passed replay is not new camera accuracy. A system speech callback is not audibility. A screenshot is not usability. Software green is not trial readiness.
- Never manufacture an unobserved return/eccentric duration, count from a voice cue, or promote manual correction into visual evidence.

## Route By Change

| Area | Read | Implementation |
| --- | --- | --- |
| Counting / phase / recovery | [motion strategy](docs/fitness/VISION_STRATEGY_AND_EVIDENCE_V1.zh-CN.md) | `apps/ipad/FoxTrainingCore` |
| Native camera / training / guidance | [module boundaries](docs/development/MODULES.md) | `apps/ipad/FoxNative` |
| Local text / photos / backup | [storage contract](docs/journal/RECORD_STORAGE_V1.zh-CN.md) | `apps/ipad/FoxJournalCore` |
| Layout | [UI constraints](docs/design/UI_INTENT_AND_REVIEW.zh-CN.md) | SwiftUI + phone/pad UI tests |
| Web / Fox Say | [architecture](docs/architecture.md) | `apps/api`, `apps/web-runtime`, `packages` |
| Verification / delivery | [verification](docs/development/VERIFICATION.md) | existing `scripts/trial-suite.mjs` and tier adapters |

## Commands

- Use Node 22; on macOS use Python 3.12, Xcode 26.3 (17C529), XcodeGen 2.45.x. `DEVELOPER_DIR` selects Xcode without changing global settings.
- `npm run bootstrap`, then `npm run doctor`. No Apple account or physical device is needed for simulator verification.
- `npm run verify:fast` for local iteration; `npm run verify:public` for complete public software coverage.
- `npm run verify:private` requires `FOX_PRIVATE_INPUT_MANIFEST`; missing or changed inputs fail. `npm run test:trial -- <fresh-directory>` is the strict compatibility entry, not a shortcut.
- On Linux, use `npm run verify:public -- --component web`. Native verification is a separate macOS job.
- New tests must appear in `tests/verification/catalogue.json`; do not weaken assertions or add silent skips to obtain green.

## Publish / Stop

- Raw media, health/training records, local receipts, device/account identifiers and credentials stay outside Git. No private artifacts in CI uploads or PR attachments. Third-party documents need redistribution permission.
- Review every new commit, not only the final tree. Stop on uncertain disclosure rights, changed baselines, data loss, missing toolchain or conflicting concurrent edits.
- Commit coherent changes and require a fresh-context review. Push/PR only within user authorization; never merge automatically. Record failed/cancelled attempts, not only the last success.
- The installed trial candidate is distinct from this development branch. Do not ask the user to repeat exercise to validate a tooling-only change.
