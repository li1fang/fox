# 系统架构

## 总体结构

fox 的目标架构分为五层：

1. iPad Pro 客户端
2. 后台 API
3. 后台数据库
4. Linux 4090 算力中心
5. AI 与 ASR/TTS 服务

第一版只需要数据库和 TUI 原型，iPad、ASR/TTS 和姿态识别后置。

## iPad Pro 客户端

iPad 是长期主要交互设备。

未来职责：

- 显示今日训练计划。
- 显示当前动作和倒计时。
- 提供大按钮反馈：完成、没跟上、太轻松、疼痛、跳过。
- 展示训练总结和历史。
- 后续接入麦克风和 TTS。

第一版不实现 iPad App，只确保文档和数据模型支持它。

## 后台 API

后台 API 是客户端、TUI 和算力中心之间的边界。

未来职责：

- 创建和读取 Entry。
- 创建 WorkoutSession。
- 推进训练状态机。
- 接收 FeedbackEvent。
- 保存 TimerEvent 和 CoachMessage。
- 调用 AI 服务生成计划、调整建议和总结。

第一版 TUI 可以直接访问本地服务或本地数据库，但接口概念应保持清晰。

## 后台数据库

数据库保存所有长期状态。

第一阶段重点对象：

- Entry
- WorkoutSession
- WorkoutPlan
- ExerciseBlock
- SetRecord
- FeedbackEvent
- TimerEvent
- CoachMessage

饮食、医疗、记账先保留轻量 Entry 和 payload。

## Linux 4090 算力中心

家中的 Linux 服务器带 4090。

当前定位：

- 作为未来算力中心预留。
- 可承接 ASR/TTS、视频处理或视觉模型。
- 第一版不运行本地大模型。

第一版不要求训练流程依赖 4090，否则会增加部署复杂度。

## AI 服务

AI 的职责是语言和策略建议，不是状态控制。

允许 AI 做：

- 根据用户档案和旧训练记录生成今日计划草稿。
- 根据反馈生成调整建议。
- 生成鼓励话术。
- 生成训练总结草稿。

不允许 AI 做：

- 直接启动或停止计时器。
- 绕过状态机改写训练状态。
- 在疼痛反馈后强行继续训练。
- 生成医疗诊断或用药决策。

## ASR/TTS

ASR/TTS 后置，并且重新设计。

未来职责：

- ASR 把用户语音变成反馈事件。
- TTS 把 CoachMessage 播放出来。

ASR/TTS 是输入输出层，不应污染状态机、数据库或训练策略。

