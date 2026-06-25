# 训练状态机

健身模块必须由确定性状态机控制。

AI 可以生成文本和建议，但不能绕过状态机修改训练状态。

## 状态列表

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

## 状态含义

### idle

没有正在进行的训练。

可进入：

- `planning`

### planning

系统正在生成训练计划草稿。

输入：

- 用户档案
- 最近训练记录
- 今日约束

可进入：

- `awaiting_approval`
- `cancelled`

### awaiting_approval

等待用户接受或修改计划。

可进入：

- `active_exercise`
- `planning`
- `cancelled`

### active_exercise

用户正在执行当前动作或当前组。

可进入：

- `rest_timer`
- `feedback`
- `adapting`
- `summary_pending`
- `aborted`

### rest_timer

组间或动作间休息倒计时。

倒计时由程序控制。

可进入：

- `active_exercise`
- `feedback`
- `aborted`

### feedback

系统等待用户报告完成情况。

可进入：

- `rest_timer`
- `adapting`
- `active_exercise`
- `summary_pending`

### adapting

系统根据反馈调整后续计划。

调整必须产生 adjustment 记录。

可进入：

- `active_exercise`
- `rest_timer`
- `summary_pending`
- `aborted`

### summary_pending

训练已结束，等待用户确认总结。

可进入：

- `confirmed`
- `active_exercise`
- `cancelled`

### confirmed

训练总结已确认，记录写入 Entry。

终态。

### cancelled

用户取消训练，通常不生成正式训练记录。

终态。

### aborted

训练因疼痛、不适或异常中止。

应生成记录，但标记为提前停止。

终态。

## 事件

标准事件：

- `start_requested`
- `plan_generated`
- `plan_accepted`
- `plan_rejected`
- `set_started`
- `set_completed`
- `rest_started`
- `rest_finished`
- `feedback_received`
- `adjustment_applied`
- `workout_finished`
- `summary_generated`
- `summary_confirmed`
- `cancel_requested`
- `abort_requested`

## 安全规则

- `pain` 反馈必须进入 `adapting` 或 `aborted`。
- `confirmed` 后不能继续修改训练状态，只能追加修正记录。
- 计时事件必须由程序产生，不能由 AI 伪造。
- AI 建议必须先被系统校验，再转成状态事件。

## TUI 最小映射

TUI 只需要支持以下操作：

- 开始训练
- 接受计划
- 当前组完成
- 没跟上
- 太轻松
- 太重
- 疼痛
- 跳过
- 延长休息
- 结束训练
- 确认总结

