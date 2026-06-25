# 开发路线图

这份路线图描述 fox 从文档进入可运行产品的开发顺序。

核心原则：

- 先跑通健身闭环，再扩展智能能力。
- 先做本地 Web Runtime UI，不做传统终端 TUI。
- 先用确定性状态机保证训练可靠，再把 AI 接进来。
- 先单用户、本地优先，后续再考虑多端同步和长期部署。
- 每个阶段都必须有可演示结果。

## 当前实现进度

截至当前原型：

- Milestone 0 已完成：monorepo、前端、API、core、schemas、测试和构建脚本已可运行。
- Milestone 1 已完成主体：训练状态机、反馈、休息、总结、终态保护和规则调整器已覆盖测试。
- Milestone 2 已完成主体：本地 Web Runtime UI 已能走完整训练闭环，包含节奏动画、倒计时、反馈和历史页。
- Milestone 3 已完成主体：SQLite session、event log、confirmed Entry 和刷新恢复已存在。
- Milestone 4 已完成主体：规则教练、保守计划、反馈后的强度调整和模板总结已存在。
- Milestone 5 已完成接口地基：AI provider、plan draft、feedback options、adjustment suggestion、audit、器材档案和历史重量推荐已存在；真实大模型 provider、AI summary 和多轮计划讨论待选型后实现。

## 技术默认选择

### 第一版应用形态

```text
本地 Web Runtime UI + 本地后台 API + 本地数据库
```

### 前端

默认：

- Vite
- React
- TypeScript
- CSS animation / requestAnimationFrame

理由：

- 适合美观界面和触控交互。
- 易于 AI 辅助开发。
- 可直接在 iPad 浏览器验证。
- 后续可以迁移到 PWA、WebView 或原生 iPad App。

### 后台

默认：

- TypeScript 后台 API。
- 训练状态机与前端共享 TypeScript 类型。
- 通过 HTTP API 起步，后续需要实时推送时再加 WebSocket。

理由：

- 前后端类型一致，减少重复决策。
- 状态机、事件、schema 都能用同一套类型表达。
- 第一版没有本地大模型，不需要为了推理提前引入 Python 后台。

### 数据库

默认：

- SQLite 起步。
- 事件日志优先。
- 后续需要多设备或长期服务化时迁移到 Postgres。

理由：

- 单用户、本地原型阻力最低。
- 非常适合快速验证 WorkoutSession、FeedbackEvent、TimerEvent。
- 避免一开始被部署和运维拖住。

### AI 接入

默认：

- 第一版先使用规则和模板跑通。
- 第二步接远程大模型 API。
- 不在第一版运行本地大模型。

AI 只输出计划、调整建议、反馈选项和总结草稿，不直接推进状态机。

## Milestone 0：项目工程骨架

目标：

建立可持续开发的最小工程结构。

交付物：

- 包管理和脚本。
- 前端 app 目录。
- 后台 API 目录。
- 共享 types/schema 目录。
- 基础 lint/test/typecheck。
- 本地开发启动命令。

建议结构：

```text
apps/web-runtime/
apps/api/
packages/core/
packages/schemas/
docs/
```

验收标准：

- 一个命令启动前端和后台。
- 一个命令跑类型检查。
- 一个命令跑测试。
- 浏览器能打开空白训练运行页。

暂不做：

- 登录系统。
- iPad 原生工程。
- ASR/TTS。
- Docker 化部署。

## Milestone 1：核心类型与状态机

目标：

把训练主持流程做成可测试的纯逻辑核心。

交付物：

- WorkoutSession 类型。
- WorkoutPlan 类型。
- ExerciseBlock / SetRecord 类型。
- FeedbackEvent / TimerEvent / Adjustment / CoachMessage 类型。
- 训练状态机。
- 规则调整器。

最小状态：

```text
idle
planning
awaiting_approval
active_exercise
rest_timer
feedback
adapting
summary_pending
confirmed
cancelled
aborted
```

验收标准：

- 能用测试模拟一次完整训练。
- 完成本组后能进入反馈。
- 没跟上后能降低后续强度或延长休息。
- 疼痛反馈能停止当前动作或中止训练。
- confirmed 后不能继续推进训练状态。

暂不做：

- AI 调用。
- 数据库。
- 动画界面。

## Milestone 2：本地 Web Runtime UI 骨架

目标：

把训练状态机可视化，先使用内存状态和固定计划。

交付物：

- 今日状态 check-in 页面。
- 计划确认页面。
- 主训练执行页面。
- 组后反馈页面。
- 休息倒计时页面。
- 总结确认页面。
- 节奏方块动画。
- 圆环或进度条倒计时。

验收标准：

- 用户可以在浏览器里完整走完一次固定训练。
- 当前动作、当前组、目标、今日主训练进度常驻可见。
- 节奏方块能放大、缩小、顶峰震动。
- 休息倒计时使用真实时间戳计算剩余时间。
- 紧急停止按钮常驻可用。

暂不做：

- 数据持久化。
- AI 生成选项。
- 多训练历史。

## Milestone 3：数据库与事件持久化

目标：

让训练过程可以保存、恢复、复盘。

交付物：

- SQLite 数据库。
- Entry 表。
- WorkoutSession 表或 JSON session 存储。
- Event log 表。
- 保存 FeedbackEvent。
- 保存 TimerEvent。
- 保存 Adjustment。
- 保存 Summary。
- 页面刷新后恢复当前训练。

验收标准：

- 训练中刷新浏览器不会丢失当前状态。
- 训练结束后能在历史列表看到记录。
- 每组反馈都能追溯到事件日志。
- 总结确认后生成 confirmed Entry。

暂不做：

- 复杂查询报表。
- 多用户。
- 云同步。

## Milestone 4：规则教练

目标：

在没有 AI 的情况下，让系统已经能给出可靠调整。

交付物：

- 今日 check-in 影响计划强度。
- 根据旧用户档案生成保守计划。
- 固定动作库。
- 固定反馈选项。
- 规则调整器。
- 模板化 CoachMessage。
- 模板化训练总结。

验收标准：

- 睡眠差或疲劳高时计划会保守。
- 第一组没跟上会降低当前动作后续强度。
- 最后一组没跟上只记录疲劳，不乱改已结束计划。
- 太轻松时只小幅增加，不激进加码。
- 疼痛时停止相关动作。

暂不做：

- 大模型计划生成。
- 自动识别动作。

## Milestone 5：AI 建议层

目标：

把大模型接入为建议层，而不是控制层。

交付物：

- AI plan draft。
- AI feedback option generator。
- AI adjustment suggestion。
- AI summary draft。
- AI 输出 schema 校验。
- AI 建议审计日志。

验收标准：

- AI 生成计划后仍需用户确认。
- AI 生成的反馈选项显示在固定选项之后。
- AI 调整建议必须经过规则校验。
- AI 输出非法 schema 时系统回退到规则教练。
- 无网络或 AI 失败时训练仍可继续。

暂不做：

- 本地大模型。
- 自由 agent。
- 直接 tool use 改状态。

## Milestone 6：训练体验打磨

目标：

让本地 Web Runtime UI 真正适合训练时使用。

交付物：

- iPad 横屏布局。
- 大按钮触控布局。
- Screen Wake Lock。
- 页面可见性恢复后重新同步状态。
- 节奏动画开关。
- 低干扰视觉风格。
- 训练中错误恢复。

验收标准：

- iPad 浏览器可舒服使用。
- 屏幕不会轻易熄灭，或能提示用户手动保持常亮。
- 页面切后台回来后倒计时仍准确。
- 训练时每屏只有一个主操作。
- 误触紧急停止概率低，但紧急时容易找到。

暂不做：

- 原生 iPad App。
- 语音。
- 3D 形象。

## Milestone 7：历史与复盘

目标：

让训练记录开始反哺下次训练。

交付物：

- 训练历史列表。
- 单次训练详情。
- 同动作历史表现。
- 最近 7 天训练摘要。
- 肩部/疼痛等风险提示。
- 下次训练建议输入。

验收标准：

- 生成计划时能读取最近训练。
- 相同动作能展示历史重量和次数。
- 疼痛或跳过记录会影响后续计划。
- 用户能手动修正历史记录备注。

暂不做：

- 复杂图表。
- 长周期训练计划。

## Milestone 8：iPad App 或 PWA 决策

目标：

根据本地 Web Runtime UI 的使用体验，决定下一步形态。

选项：

- 继续强化 PWA。
- 用 WebView 包装成 iPad App。
- 重写为 SwiftUI。
- 用 React Native / Expo。

验收标准：

- 已经完成至少多次真实训练。
- 明确 Web 形态的痛点。
- 明确是否需要原生麦克风、音频、后台、传感器能力。

暂不做：

- 在 Web Runtime UI 验证前启动原生 App。

## Milestone 9：ASR/TTS

目标：

降低训练中点击操作成本。

交付物：

- ASR 将语音转成反馈事件。
- TTS 播放 CoachMessage。
- 语音确认机制。
- 静音和文本模式。

验收标准：

- 用户说“完成了七个”能变成 set_finished + reps。
- 用户说“太重了”能变成 too_hard feedback。
- TTS 不阻塞状态机。
- ASR 识别不确定时要求确认。

暂不做：

- 复用旧 ASR/TTS。
- 让语音直接控制危险状态。

## Milestone 10：传感器与姿态识别

目标：

在核心闭环成熟后，研究辅助感知。

交付物：

- 加速度计计数实验。
- 摄像头姿态估计实验。
- 少数动作的辅助校验。
- 置信度展示。

验收标准：

- 自动计数低置信度时不覆盖用户输入。
- 姿态反馈只作为建议。
- 任何视觉模型失败都不影响手动训练流程。

暂不做：

- 让自动感知成为训练必需条件。
- 医疗级动作纠正。

## 开发节奏

每个 milestone 必须满足：

- 可演示。
- 可测试。
- 不依赖后续 milestone 才能工作。
- 失败时能回退到上一阶段。

推荐顺序：

```text
M0 -> M1 -> M2 -> M3 -> M4 -> M5 -> M6 -> M7 -> M8 -> M9 -> M10
```

不得提前做：

- 3D 形象。
- 自动计数。
- 原生 iPad App。
- ASR/TTS。
- 多领域联动分析。

这些能力只有在训练闭环已经多次真实使用后才进入开发。
