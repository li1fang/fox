# Fox Agent Entry

Read [current state](docs/development/CURRENT.md) for the active task and candidate. Follow only the routes relevant to the change; history is reference, not new authorization.

## Work

- State the intended outcome and relevant checks briefly. Use the [task contract](docs/development/task-contract.example.json) for substantial cross-module work, not every small edit.
- Within an authorized task, carry reversible local edits, diagnosis, focused tests and coherent local commits through completion without step-by-step approval. Ask when scope or an irreversible external effect changes.
- Prefer existing code and standard tools. Do not add speculative abstractions, monitoring or governance to complete a one-off task.
- Reproduce bugs with existing evidence or a focused failing regression, then fix and verify the affected behavior. Tests should check outcomes, not mirror trivial implementation or document wording.
- Keep one writer per tree, including docs and generated projects. A task owner may work across modules; workstreams are not approval gates. Use [module ownership](docs/development/MODULES.md#协作入口与职责) for handoff.
- Preserve unrelated edits, originals and device records. Device install/uninstall, signing, networking, destructive data changes, spending and publishing require explicit authorization.

## Verification

- Iterate with affected tests or `npm run verify:workstream -- <client|vision|data|storage|tooling> --list`. Broaden coverage for changed shared contracts or concrete unresolved risk; do not repeat passing checks without a reason.
- Check `npm run resources` before native builds/tests and hold the existing lease. Worktrees do not isolate simulators. Never steal a stale claim, edit a tree under verification or stop another owner's resources.
- If orchestration blocks a test, classify the failure and prefer an authorized direct tool path with the same assertions, bounded runtime and owned-resource cleanup. Pause only the affected group on repeated failure; fixing the whole harness is not a prerequisite for unrelated work.
- For formal candidate acceptance, freeze a clean commit and use `npm run verify:candidate -- public --commit <full-sha>` (or `private`). Scoped/direct results are scoped results, not full acceptance. Existing matching receipts may be reused through `npm run verify:receipt`; different-commit results remain diagnostic.
- New repository tests belong in `tests/verification/catalogue.json`. Do not weaken assertions or silently skip failures. Private verification requires `FOX_PRIVATE_INPUT_MANIFEST`; Linux runs only the web component.
- See [verification](docs/development/VERIFICATION.md) for command details. Do not load the whole procedure for routine edits.

## Evidence And Delivery

- Keep raw media, health records, identifiers, credentials and local receipts outside Git. Retain failed attempts; check each commit for disclosure and scope.
- Review a coherent delivery with fresh context, covering its commits. Routine patch revisions do not each require a separate agent or human approval; review high-risk migrations/control before execution.
- Distinguish installed version, source candidate, scoped tests and real-world behavior. Never invent counts/durations, infer motion from speech, or present manual correction as visual evidence.
- Push/PR/merge and device delivery follow their own authorization. Do not request real exercise to validate tooling-only changes.

## Routes

| Change | Read | Code |
| --- | --- | --- |
| Counting / phase / recovery | [motion strategy](docs/fitness/VISION_STRATEGY_AND_EVIDENCE_V1.zh-CN.md) | `apps/ipad/FoxTrainingCore` |
| Camera / training / guidance | [modules](docs/development/MODULES.md) | `apps/ipad/FoxNative` |
| Text / photos / backup | [storage](docs/journal/RECORD_STORAGE_V1.zh-CN.md) | `apps/ipad/FoxJournalCore` |
| Layout | [UI constraints](docs/design/UI_INTENT_AND_REVIEW.zh-CN.md) | SwiftUI + affected phone/pad tests |
| Web / Fox Say | [architecture](docs/architecture.md) | `apps/api`, `apps/web-runtime`, `packages` |

Use Node 22, Python 3.12, XcodeGen 2.45.x and per-process Xcode 27.1 (27A9275), profile `xcode-27.1`, general iOS 27.0. iOS 27.1 is Duo-only, selected explicitly. CI retains its Xcode 26.3 compatibility lane; do not change global xcode-select. See [toolchain](docs/development/TOOLCHAIN_TRANSITION.zh-CN.md).
