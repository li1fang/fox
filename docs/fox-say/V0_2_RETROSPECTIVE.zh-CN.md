# Fox Say v0.2 复盘

## 结论

Fox Say v0.2 已经证明一条最小真实语音链路成立：

```text
iPad 原生录音
-> Fox API capture
-> Linux SenseVoice ASR
-> Fox API ASR result
-> iPad 显示识别文本
```

但它还没有证明“语音助手可用”。当前链路更准确地说是一个可运行的 ASR 实验入口，而不是稳定的语音产品。

本轮最重要的产品判断是：

- 继续堆 TTS、agent、数字人、实时 streaming 都偏早。
- 单纯收集 50-100 条真实语料也偏早。
- 下一步应该先补齐词库、评测、纠错和结果承接基础设施。

真实语料只有在能进入评测、词库、纠错、路由或微调闭环时才有价值。否则它只是录音档案。

## 已经成立

### iPad 侧

- `Fox` 和 `Fox Say` 已经是两个独立 iPad App。
- Fox Say 可以通过原生 iPad microphone bridge 录音。
- 录音可以上传到 Fox API。
- 已上传录音可以在 iPad 页面回放。
- 原生录音失败时能显示 iOS error message、domain/code、context。

### API 侧

- `POST /say/capture` 可保存 capture metadata 与 runtime audio。
- `GET /say/captures/latest` 可读取最近录音。
- `GET /say/captures/:id/audio` 可回放音频。
- `POST /say/asr/run-latest` 可触发当前 latest capture 的 Linux ASR。
- `GET /say/asr-results/latest?captureId=...` 可读取指定 capture 的 ASR result。
- ASR result、voice draft、confirmed Entry 之间仍然保持人工确认边界。

### Linux/VCompose 侧

- latest capture 可以导出到 Linux runtime storage。
- Linux SenseVoice runner 可以消费 iPad capture。
- ASR 文本可以回写 Fox API。
- iPad 页面可以看到 ASR 返回文本。

### 自动化

- Playwright 覆盖原生录音桥成功、失败、bridge exception。
- Playwright 覆盖 ASR 结果必须绑定当前 capture，避免读取旧结果。
- Playwright 覆盖 iPad 页面触发当前录音 ASR。
- API 测试覆盖 server-side ASR runner endpoint 和非 latest capture 拒绝。
- `npm run verify` 与 `npm run test:e2e` 已作为主回归门。

## 刚修掉的关键问题

### 按钮语义混乱

旧按钮名：

- `录音上传`
- `结束上传`
- `读取最新`
- `读取识别`

问题是这些词没有表达真实动作。现在改为：

- `开始录音`
- `停止并上传`
- `读取最近录音`
- `运行当前录音 ASR`
- `读取当前录音 ASR`

### ASR 没有自动启动

用户合理预期是：录音上传后，ASR 会开始处理。

实际旧逻辑是：页面只会读取已有 ASR result，不会启动 Linux ASR。

v0.2 已修复为：iPad 页面可以触发 `POST /say/asr/run-latest`，由 Fox API 调用 server-side runner。

### 页面可能读取旧 ASR

旧逻辑读取全局 latest ASR，可能把旧测试结果显示给当前录音。

v0.2 已修复为：ASR 读取必须绑定当前 `captureId`。触发 ASR 时，后端也会拒绝非 latest capture。

## 仍然不成熟

### ASR 质量没有证明

目前已经出现过明显离谱的识别结果。链路可通不等于质量可用。

当前不能承诺：

- 噪声环境可用。
- 健身动作、器材、重量、组数识别稳定。
- 中文夹英文、数字、单位、口语修正稳定。
- 可直接自动入库。

### 没有常用词数据库

Fox 现在还没有系统化词库。缺少：

- 动作名：哑铃飞鸟、罗马尼亚硬拉、高位下拉。
- 器材名：多功能推举训练器、高位下拉训练器。
- 单位与数量：kg、千克、公里每小时、组、次、秒。
- 个人上下文：用户常用表达、家庭器材、常见训练计划。
- 纠错映射：例如 ASR 常错词应修正为什么。

这会导致 ASR 和后续 LLM extraction 都缺乏领域上下文。

### 没有 ASR 评测数据库

现在只能看单次输出，不知道：

- 某个模型在 Fox 语料上总体表现如何。
- 错误集中在数字、动作、器材、噪声还是口语。
- 改了音频预处理、词库、模型后是否真的变好。
- SenseVoice 是否比 faster-whisper 更适合当前场景。

没有评测数据库，真实语料不能形成可比较证据。

### 没有微调基础设施

即使收集真实语料，也还不能直接微调，因为缺少：

- 样本清洗规则。
- train/dev/test 切分。
- 隐私与 raw audio 管理策略。
- 模型训练脚本。
- 对照评测。
- 回滚和版本记录。

所以 v0.2 不应把“收集大量语料”当成下一步主线。

## 关于真实语料的重新判断

原先的“收集 50-100 条真实样本”需要降级。

更合理的顺序是：

1. 先做词库 schema。
2. 再做 ASR evaluation schema。
3. 再收 5-10 条小样本验证评测链路。
4. 再做规则/词库纠错。
5. 再做 SenseVoice 与 faster-whisper baseline 对照。
6. 最后再决定是否收 50-100 条。

真实语料的价值不在“数量”，而在它能进入哪个闭环：

- 词库扩展。
- ASR 错误分类。
- 后处理纠错。
- LLM 草稿纠错。
- 模型路由选择。
- 未来微调数据集。

## 下一阶段建议

### Phase 0.2.1：词库基础设施

目标：让 Fox 知道用户常说的词、动作、器材、单位和别名。

建议新增概念：

```text
LexiconTerm
LexiconAlias
CorrectionRule
DomainPhrase
```

建议字段：

```json
{
  "schema": "fox.say_lexicon_term.v0",
  "id": "lex_...",
  "domain": "workout",
  "canonicalText": "哑铃罗马尼亚硬拉",
  "aliases": ["哑铃 RDL", "罗马尼亚硬拉", "RDL"],
  "kind": "exercise",
  "priority": 80,
  "notes": "用户不熟悉该动作，语音中可能说成硬拉或罗马尼亚。",
  "active": true
}
```

第一版不需要智能拍照登记，也不需要自动发现。可以手动维护。

### Phase 0.2.2：ASR 评测数据库

目标：每次 ASR 都能留下可比较结果。

建议新增概念：

```text
AsrEvalSample
AsrEvalRun
AsrEvalResult
AsrErrorTag
```

核心字段：

- capture id
- expected text
- actual text
- provider
- model
- audio environment
- domain
- character similarity
- critical error tags
- pass/fail
- human notes

第一版不追求复杂算法，先支持人工标注错误类型。

### Phase 0.2.3：后处理纠错

目标：在不微调模型的情况下，先吃到词库红利。

推荐顺序：

1. 规则纠错：数字、单位、常见错词。
2. 词库匹配：动作名、器材名、别名归一。
3. LLM 草稿纠错：只生成待确认草稿，不自动入库。
4. 人工确认：用户修改后反哺词库与评测。

这比直接微调便宜、快、可解释，也更适合当前阶段。

### Phase 0.2.4：双后端对照

目标：避免 SenseVoice 单一路线锁死。

需要至少比较：

- SenseVoice on 4090。
- faster-whisper baseline。
- 可能的 whisper.cpp on M1 fallback。

对照必须使用同一套 eval sample 和同一套指标。

### Phase 0.2.5：微调决策

只有在以下条件满足后才讨论 ASR 微调：

- 至少有稳定的 eval dataset。
- 错误类型重复出现，并且词库/规则/LLM 后处理不能解决。
- 有 train/dev/test 切分。
- 有 baseline 对照。
- 有明确收益指标。

否则微调很容易变成昂贵而不可验证的工程。

## 当前不建议做

- 不建议马上做实时 streaming。
- 不建议马上做 TTS 回放闭环。
- 不建议马上做语音命令自动修改 workout state。
- 不建议马上做 ASR 微调。
- 不建议盲目收集 50-100 条录音。
- 不建议让 LLM 直接把 ASR 文本自动入库。

## v0.2 验收状态

当前 v0.2 可以算作：

```text
voice_capture_green = true
asr_roundtrip_green = true
ipad_asr_trigger_green = true
human_review_boundary_green = true
asr_quality_green = false
lexicon_infra_green = false
eval_infra_green = false
finetune_infra_green = false
```

下一步不应追求“更像完整助手”，而应追求“更能判断语音能力是否真的可靠”。

