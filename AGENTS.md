# Fox Agent Entry

Read [current state](docs/development/CURRENT.md) first. This file is a routing guide, not a substitute for source or runtime evidence.

## Collaboration

- Use [module ownership and handoff](docs/development/MODULES.md#协作入口与职责) and the existing task ledger. One task has one owner who may finish cross-module work within its authorization; workstreams are not approval gates.
- Keep a single writer per working tree for code, documentation, the ledger, test registration and project generation. Separate worktrees do not isolate simulators, devices or heavy build/test resources; reuse existing ownership/lease rules.
- Initial workstream intake is read-only. Return a receipt in that chat; the coordinator reads it and records the shared state. A candidate task is not an assignment. Do not start work or message another chat without user authorization.
- Verify project membership, actual default working directory, Git root and guidance provenance separately. Explicit workdir and manually reading this file do not prove that an existing chat changed its default context.

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

- Use Node 22, Python 3.12 and XcodeGen 2.45.x. Local defaults require Xcode 27.1 (27A9275), profile `xcode-27.1`, and the general iOS 27.0 runtime. iOS 27.1 is Duo-only: choose its runtime and model explicitly, never as an iPad fallback. CI retains an explicit `xcode-26.3` (17C529) compatibility lane. Select `DEVELOPER_DIR` per process; no global selection is changed. See [transition](docs/development/TOOLCHAIN_TRANSITION.zh-CN.md) for installation, acceptance and removal gates.
- `npm run bootstrap`, then `npm run doctor`. No Apple account or physical device is needed for simulator verification.
- `npm run verify:fast` for local iteration; `npm run verify:public` for complete public software coverage.
- Before expensive acceptance, finish known blockers, focused tests and review; freeze a clean commit. Use `npm run verify:candidate -- public --commit <full-sha>` (or `private`). A component run is not whole-product acceptance. Keep evidence in ignored output directories, not candidate source files.
- Classify failures with evidence before rerunning: product, test/fixture, environment, orchestration/budget, cancellation/superseded, or unknown. Record the next hypothesis; do not retry to green or require human approval for routine diagnosis.
- Reuse matching receipts through `npm run verify:receipt`; check the required environment separately. Old/different-commit results are diagnostic evidence, not current acceptance. See [workflow and acceptance rules](docs/development/VERIFICATION.md#开发流程与候选验收).
- `npm run verify:private` requires `FOX_PRIVATE_INPUT_MANIFEST`; missing or changed inputs fail. `npm run test:trial -- <fresh-directory>` is the strict compatibility entry, not a shortcut.
- On Linux, use `npm run verify:public -- --component web`. Native verification is a separate macOS job.
- New tests must appear in `tests/verification/catalogue.json`; do not weaken assertions or add silent skips to obtain green.

## Publish / Stop

- Raw media, health/training records, local receipts, device/account identifiers and credentials stay outside Git. No private artifacts in CI uploads or PR attachments. Third-party documents need redistribution permission.
- Review every new commit, not only the final tree. Stop on uncertain disclosure rights, changed baselines, data loss, missing toolchain or conflicting concurrent edits.
- Commit coherent changes and require a fresh-context review. Push/PR only within user authorization; never merge automatically. Record failed/cancelled attempts, not only the last success.
- Freeze the candidate, not all work: other worktrees may progress, but never edit the tree under verification. If a new blocker requires replacement, retain old receipts and explain cancellation. CI triggers are unchanged; a draft PR still runs checks on updates.
- The installed trial candidate is distinct from this development branch. Do not ask the user to repeat exercise to validate a tooling-only change.
