# Fox Say Handoff Test Plan v0

## 结论

Fox Say 可以进入受控 handoff 的前提不是“页面能打开”，而是以下链路能被重复验证：

```text
iPad Fox Say app -> native microphone capture -> Fox API capture store
-> local export -> VCompose Linux staged smoke -> evidence report
```

截至 2026-07-01，最新真实 iPad 录音已经通过 staged Linux smoke：

- capture id: `say_1782923628160_54e3baac`
- content type: `audio/mp4`
- bytes: `1455477`
- VCompose job: `job-1782923656-e4cbb4f2b6cd27b7`
- decision: `roundtrip_capture_linux_evidence_ready`
- raw audio committed: `false`

这说明“真实 iPad 录音上传并进入 Linux evidence gate”已经正常。它仍不是完整实时语音产品，因为 streaming latency、50-100 条真实样本矩阵、ASR 文本回流、TTS 音频回放到 iPad、训练状态自动变更都还没有打开。

## Handoff 最低功能要求

进入 handoff 前，任务台账至少必须证明以下项目为 green。

| Gate | 最低要求 | 当前状态 | 证据 |
| --- | --- | --- | --- |
| app isolation | Fox 和 Fox Say 是两个 iPad App，分别使用 `com.whipa.fox` 与 `com.whipa.foxsay` | green | XcodeGen 生成 `Fox` / `FoxSay` 两个 target；脚本支持分别 build/install/open |
| iPad native capture | Fox Say 内点击录音会触发麦克风权限、录音、停止、上传 | green with real sample | 最新 `.m4a` capture 已上传到 Fox API |
| capture API | API 能保存 capture metadata、回放 audio、拒绝空 capture | green | `apps/api/test/server.test.ts` |
| no raw audio commit | raw audio 只存在 runtime storage，不进入 git artifact | green | capture report `rawAudioCommitted=false` |
| export to VCompose | 最新 capture 能导出到 `/srv/vcompose/data/fox/voice/roundtrip` | green with real sample | `npm run say:export-capture` |
| Linux staged smoke | Linux gate 能消费真实 capture export 并组合 ASR/TTS evidence | green with real sample | `roundtrip_capture_linux_evidence_ready` |
| one-command smoke runner | 一个命令完成 latest capture 检查、导出、Linux smoke、报告汇总 | green | `npm run say:handoff-smoke` |
| fallback TTS truthfulness | iPad/browser TTS 明确只是 basic fallback，不宣传为自然 TTS | green | handoff doc 与 feature ledger |

## 测试设计

### T1: App Isolation Smoke

目标：证明 Fox Say 不顶替 Fox，并且 iPad 主屏幕上存在两个独立 App。

步骤：

1. 运行 `npm run ipad:build`。
2. 运行 `npm run ipad:install`。
3. 在 iPad 主屏幕确认有 `Fox` 和 `Fox Say` 两个图标。
4. 运行 `npm run ipad:open:fox`，预期打开 Fox 主应用。
5. 运行 `npm run ipad:open:say`，预期打开 Fox Say 语音入口。

可自动化方向：

- 增加一个小型 Swift unit-like launch-state test 会更理想，但当前先由 iPad build、install、launch 和代码审查覆盖。

### T2: Native Capture Upload Smoke

目标：证明 iPad 真实麦克风录音能进入 Fox API。

步骤：

1. 运行 `npm run say:ipad-run`。
2. 在 iPad 点 `开始录音`。
3. 首次运行时接受麦克风权限。
4. 说一句短命令或训练反馈。
5. 点 `停止并上传`。
6. 运行：

```bash
curl -fsS http://<mac>:4177/say/captures/latest | jq .
```

预期：

- `capture.schema=fox.say_capture.v0`
- `contentType=audio/mp4`
- `bytes > 0`
- `sha256` 存在
- `rawAudioCommitted=false`
- 页面展示 latest capture id / bytes / sha prefix
- 如果失败，页面展示 native error code、iOS error message、domain/code、context，而不是只显示通用失败。

ASR 操作：

1. 确认 iPad 页面已选中当前 capture。
2. 在 iPad 点 `运行当前录音 ASR`。
3. 如果需要排障，再在 Mac 运行 `npm run say:linux-asr` 查看原始命令行报告。
4. 预期 ASR result 的 `captureId` 与当前 capture 一致；页面不得读取其他旧 capture 的 ASR 结果。

自动化覆盖：

- Playwright mock `window.webkit.messageHandlers.foxPadAudioCapture` 的成功路径。
- Playwright mock Swift native failure payload，确认错误细节可见。
- Playwright mock `postMessage` exception，确认 UI 回到可重试状态。

### T3: Capture API Regression

目标：保证 API 行为稳定。

命令：

```bash
npm run test -w @fox/api
```

预期：

- `POST /say/capture` 接受非空音频。
- `GET /say/captures/latest` 返回最新 metadata。
- `GET /say/captures/:id/audio` 可回放。
- 空 capture 返回 `400 empty_capture`。

### T4: Export To VCompose

目标：证明 latest capture 可以进入 Linux runtime storage。

命令：

```bash
npm run say:export-capture
```

预期：

- 输出 `fox.say_roundtrip_capture_export.v0`
- `remote.host=fox-voice-host`
- `remote.directory=/srv/vcompose/data/fox/voice/roundtrip`
- `capture.rawAudioCommitted=false`

### T5: Linux Roundtrip Staged Smoke

目标：证明 VCompose gate 能消费真实 capture，并连接现有 ASR/TTS evidence。

命令：

```bash
ssh fox-voice-host 'cd /srv/fox-voice/VCompose && go run ./cmd/vfctl submit -f examples/job-fox-voice-roundtrip-smoke-gate.yaml --submitter fox-say-handoff'
```

报告：

```text
/srv/vcompose/output/fox/voice/runtime/e2e/fox-voice-ipad-linux-roundtrip-smoke-v0.json
```

预期：

- `ok=true`
- `decision=roundtrip_capture_linux_evidence_ready`
- `capture_export.audio.exists=true`
- `capture_export.sha256_match=true`
- `linux_asr_evidence.ok=true`
- `linux_tts_evidence.ok=true`
- `full_realtime_e2e_measured=false`
- `raw_audio_committed=false`

### T6: One-command Handoff Smoke

目标：让接手团队不用记住多条命令，也能重复验证当前 handoff 是否仍然 green。

命令：

```bash
npm run say:handoff-smoke
```

本地摘要：

```text
.tmp/fox-say-handoff-smoke-report.json
```

预期：

- `ok=true`
- `schema=fox.say_handoff_smoke_report.v0`
- `decision=fox_say_handoff_smoke_ready`
- `linux_asr_ready=true`
- `linux_tts_ready=true`
- `full_realtime_e2e_measured=false`
- `raw_audio_committed=false`

### T7: Handoff Boundary Check

目标：防止下游误解。

需要明确为未开放：

- iPad -> Linux streaming realtime latency
- Linux ASR text 自动改 Fox workout state
- Linux TTS audio 自动回放到 iPad
- 50-100 条真实人声/iPad/噪声样本矩阵
- 提交 raw audio 到 git
- 宣称 iPad/browser fallback TTS 是自然 TTS

## Handoff 判定

如果 T1-T7 全部通过，Fox Say 可以作为“真实录音 capture + staged Linux evidence handoff”交给 UI/native 团队。

如果目标是“可日常使用的 Fox 语音产品”，还不能 handoff；那需要先完成真实样本矩阵、streaming latency、ASR/TTS 回流和训练状态机接入。
