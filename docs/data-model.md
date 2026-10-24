# 数据模型

## 当前：通用原始记录（2026-10-16）

本轮只实现记录与本地存储，契约见 [通用记录与本地存储 v1](journal/RECORD_STORAGE_V1.zh-CN.md)。`CaptureRecord` 保存原文、照片、记录时间、可选发生时间、来源、可选标签与修订号，不要求先选饮食/健康/消费类型，也没有等待 AI 的保存状态。

数据库使用当前记录、修订快照、附件、修订附件引用和标签表；照片为私有文件，元数据和摘要存库。删除整条记录才删除其全部历史；备份覆盖历史与仍被引用的原图。结构见 [记录 Schema](../schemas/capture-record.schema.json) 和 [备份 Schema](../schemas/journal-backup.schema.json)，跨记录及文件完整性由 Swift 核心校验。

未来可从一条原始记录得到多个用户确认事实，但本轮不实现事实表或分析流程。新记录核心未接入 App，也没有迁移训练 JSON 或修改既有 `Entry` 格式，不能把下面旧设计的生命周期套到新原始记录上。

## 历史：领域 Entry 与健身设计

以下保留此前统一 Entry、后台数据库和 TUI 原型的概念设计及既有原型契约，供后续明确映射；不表示它们已与新原生存储合并。

## 统一 Entry

`Entry` 是所有用户生活记录的根对象。

每条 Entry 表示一件发生过的事：

- 类型
- 发生时间
- 原始证据
- 原始文本
- AI 提取草稿
- 用户确认结果
- 状态

## Entry 类型

```text
meal
medical
workout
expense
note
```

## Entry 生命周期

```text
draft -> extracted -> needs_review -> confirmed
                 \              /
                  -> confirmed -
```

含义：

- `draft`：用户刚创建，尚未提取结构化信息。
- `extracted`：AI 生成结构化草稿。
- `needs_review`：草稿存在，但信息不完整或置信度低。
- `confirmed`：用户确认或修正后成为正式记录。

## Evidence

Evidence 是原始证据。

支持：

- 图片
- PDF
- 音频
- 文本
- 票据
- 处方

原则：

- Evidence 一旦附加，不应被结构化修正覆盖。
- 错误修正发生在 payload 中。
- 医疗和财务 evidence 视为敏感数据。

## 健身扩展模型

健身模块的核心不是单条日志，而是一次训练会话。

### WorkoutSession

一次训练。

字段草案：

```text
WorkoutSession
- id
- entry_id
- status
- started_at
- ended_at
- timezone
- location
- plan
- actual
- feedback_events
- timer_events
- adjustments
- coach_messages
- summary
- created_at
- updated_at
```

`entry_id` 指向统一 Entry。训练结束并确认后，Entry 的 `confirmed_json` 保存 workout payload。

### WorkoutPlan

训练计划。

字段草案：

```text
WorkoutPlan
- focus
- estimated_duration_minutes
- exercises
- warmup
- cooldown
- safety_notes
```

计划可以由 AI 生成，但必须经用户确认后才执行。

### ExerciseBlock

训练中的一个动作。

字段草案：

```text
ExerciseBlock
- exercise_id
- name
- category
- target_sets
- completed_sets
- rest_seconds
- tempo
- notes
```

### SetRecord

一组实际完成记录。

字段草案：

```text
SetRecord
- set_index
- planned_set_index
- status
- reps
- weight
- weight_unit
- duration_seconds
- rpe
- pain
- notes
- counting_method
```

`counting_method` 第一版固定为 `manual` 或 `timer`。

### FeedbackEvent

用户反馈。

字段草案：

```text
FeedbackEvent
- id
- at
- state
- kind
- exercise_name
- set_index
- message
```

标准 `kind`：

- `completed`
- `not_followed`
- `too_easy`
- `too_hard`
- `pain`
- `skip`
- `note`

### TimerEvent

计时事件。

字段草案：

```text
TimerEvent
- id
- at
- kind
- duration_seconds
- target
```

标准 `kind`：

- `exercise_timer_started`
- `exercise_timer_finished`
- `rest_timer_started`
- `rest_timer_finished`
- `timer_extended`
- `timer_cancelled`

计时事件必须由程序产生，不能由 AI 伪造。

### Adjustment

根据反馈产生的计划调整。

字段草案：

```text
Adjustment
- id
- at
- reason
- decided_by
- target
- before
- after
```

`decided_by` 可为：

- `rules`
- `ai_suggestion`
- `user`

### CoachMessage

教练消息。

字段草案：

```text
CoachMessage
- id
- at
- role
- state
- text
- source
```

`source` 可为：

- `system`
- `ai`
- `template`

CoachMessage 是表现层记录，不应作为训练事实。

## workout payload

`workout_payload` 应表达三类事实：

1. 计划做什么。
2. 实际做了什么。
3. 训练过程中发生了什么反馈和调整。

最小结构：

```text
workout_payload
- workout_name
- location
- started_at
- ended_at
- plan
- actual
- feedback_events
- timer_events
- adjustments
- coach_summary
- user_confirmation_status
```

## 其他领域

### meal

第一版保留：

- 食物名
- 份量描述
- 估算热量
- 总估算热量
- 备注

### medical

第一版保留：

- 药名
- 剂量
- 频率
- 持续时间
- 医生备注
- 注意事项

不做诊断，不做自动用药决策。

### expense

第一版保留：

- 金额
- 货币
- 商户
- 分类
- 支付方式
- 备注

记账保持手动输入。

