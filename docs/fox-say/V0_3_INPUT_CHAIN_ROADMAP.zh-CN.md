# Fox Say v0.3：可日用输入链路线图

## 目标

Fox Say 的下一目标不是把 ASR 做成一个更大的实验台，而是让它成为一条可反复使用、可解释、可回退的输入通道：

```text
iPad 短录音
-> Fox API durable ASR job
-> Linux ASR
-> 已绑定 capture 的文本结果
-> [Mac 剪贴板]
   或 [Fox 草稿 -> 人工确认 -> Entry]
```

这条链的成功标准不是“模型曾经返回过一句话”，而是用户能知道当前录音正在做什么、失败后能重试、文本会准确送到指定的下一站，并且不会暗中改变 Fox 的训练状态或生活记录。

## v0.3 交付范围

### 1. Durable ASR job

Fox API 负责保存每个 ASR 请求的状态：

```text
queued -> running -> succeeded
                 -> failed
```

- 一段 capture 至多有一个进行中的 job；重复点击会复用它。
- job 与 `captureId`、ASR result、错误信息和时间戳绑定。
- iPad 停止并上传后自动排队，而不是要求用户猜测是否还要点击第二个识别按钮。
- Linux runner 处理指定 capture，而不是重新读取“全局最新录音”，避免后来的录音串进前一个 job。
- 旧的 `POST /say/asr/run-latest` 保留为兼容/诊断入口；日常 UI 改走 job API。

### 2. Mac 输入桥：明确、拉取式、剪贴板优先

“输入到 Mac”第一版的定义是：**用户在 iPad 明确发送一条 ASR 文本，Mac 本机 bridge 把它写入系统剪贴板，用户在目标 App 按 Command-V。**

```text
iPad: 发送到 Mac
-> Fox API: queued mac-input job
-> Mac local bridge (loopback only)
-> pbcopy
-> completed receipt
```

- iPad 只能创建待处理的 Mac input job；它不能直接调用 `pbcopy`。
- 只有运行在 Mac loopback 的 bridge 可以领取文本、写剪贴板并回报完成。
- bridge 只记录 job id、状态、字符数和文本 hash，不重复写入文本内容或原始音频。
- 默认不自动粘贴到前台 App，也不申请 Accessibility 权限。自动键入是单独的后续能力，必须有焦点保护、可见确认和系统权限说明。
- Mac 输入与 Fox 入库是两条独立动作。发送文本不会创建 Entry，也不会变更 workout state machine。

### 3. Fox 收件箱保持人工确认边界

现有路径继续成立：

```text
ASR result -> needs_review voice draft -> confirmed Entry
```

- 草稿可以编辑、丢弃或确认。
- 只有确认动作才创建生活 Entry。
- ASR 原文、草稿 JSON 和确认内容保留可追溯关系。

## 使用方式

开发时启动 Fox Say：

```bash
npm run say:ipad-run
```

这会同时启动 API、Web runtime 和本机 Mac clipboard bridge。若只启动普通 LAN runtime，则另开一个本机终端：

```bash
npm run say:mac-bridge
```

可用 `FOX_SAY_MAC_BRIDGE=0 npm run say:ipad-run` 临时关闭自动启动的 bridge。

之后在 iPad：

1. 点击“开始录音”，说一条短句。
2. 点击“停止并上传”。页面自动创建并轮询 ASR job。
3. 文本出现后，选择“发送到 Mac”或“生成 Fox 草稿”。
4. 选择 Mac 时，等待“已复制到 Mac”，再到目标 App 按 Command-V。
5. 选择 Fox 时，在收件箱修订并确认入库。

## 验收门

| 门 | 自动化证据 | 人工证据 |
| --- | --- | --- |
| capture/job 绑定 | 指定 capture 的 job 不会消费较新的录音 | 连续录两段时，第一段结果不会变成第二段文本 |
| 可见状态 | queued/running/succeeded/failed 都有 API 与 UI 表示 | iPad 不会长期只显示“等待识别”而无原因 |
| 失败可恢复 | runner 失败可见，重新识别会创建新 job | 断开 Linux 后能看懂错误并重试 |
| Mac 桥边界 | 远端不能领取待复制文本；loopback bridge 可完成 job | iPad 明确发送后，Mac 剪贴板变为该文本 |
| Fox 边界 | 发送 Mac 不创建 Entry、不改变 workout state | 草稿确认前，Fox 主应用没有被悄悄修改 |
| 隐私 | raw audio 仍为 runtime-only | git 中没有音频或绝对 runtime 路径 |

## 后续顺序与准入条件

### v0.4：录音质量、VAD 与分段

先完成 v0.3 的日常使用，再进入这一阶段。第一版保持 push-to-talk；不要把音量条误称为 VAD。

进入条件：至少有一段稳定的日常使用记录，能区分“录音过长/空白/噪声/ASR 错误/用户说错”。

交付：录音时长与空白检测、可解释的 VAD evidence、分段策略，以及按 capture/job 记录的延迟。

### v0.5：词库、纠错与评测

进入条件：有真实、人工确认过的错误样本，而不仅是未标注录音。

交付顺序：手工词库 -> 错词规则 -> eval sample/result -> 5-10 条对照 -> 可选 LLM 草稿纠错。词库先覆盖动作、器材、数字、单位、个人表达和别名。

### v0.6：声纹识别

声纹只作为“这像不像本人”的上下文信号，不能作为登录或医疗/财务动作授权。

进入条件：VAD 与样本隐私策略已稳定，且确有多说话人或误触发问题需要解决。

### v0.7：模型对照与微调决策

进入条件：词库/规则/草稿纠错无法解决的重复关键错误，有固定 eval dataset、train/dev/test 切分、SenseVoice 与 faster-whisper baseline，以及可量化收益门槛。

在这些条件之前，不把“收集很多音频”或“训练一个模型”当作进度。

## 明确止线

- 不做实时 streaming。
- 不做自动训练命令执行。
- 不做无确认的 Fox Entry 写入。
- 不做自动键入前台 App。
- 不做声纹身份认证。
- 不做 ASR 微调。

这些不是放弃，而是让每一步都有能被真实使用和验证的边界。
