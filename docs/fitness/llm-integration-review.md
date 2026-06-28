# 大模型介入接口复查

## 当前状态

当前 fox runtime 已经有确定性状态机、SQLite 事件日志、规则教练、器材档案、历史重量推荐和很薄的 AI 建议层。

它能做到：

- 固定 check-in 后生成保守计划。
- 根据 `PlanningContext` 生成 AI/模板计划草稿，并进入用户确认。
- 读取结构化 `EquipmentInventory`。
- 从 confirmed workout entries 中提取 `ExerciseHistorySnapshot`。
- 根据历史同动作表现推荐重量、次数和保守理由。
- 进入训练执行、反馈、休息、总结确认。
- 让 AI/模板生成反馈选项。
- 让 AI/模板生成调整建议。
- 在组间/动作间记录追加反馈，并可保守延长休息。
- 将 AI 输出写入 audit。
- 用规则层阻止 AI 直接推进状态机。

它还没有做到：

- 接入真实远程大模型 provider。
- 开局多轮计划讨论。
- 大模型根据历史表现推荐动作替代。
- 动作间、组间让真实大模型持续理解反馈并主持下一步。
- 训练总结由大模型根据完整上下文生成。
- 大模型提出的计划变更经过用户确认后落入状态机。

## 原则修正

fox 不应该走完全自由 agent。

推荐结构：

```text
确定性状态机
  控制：状态推进、计时器、confirmed 记录、危险停止

LLM coach
  负责：计划草稿、计划讨论、解释、反馈选项、调整建议、总结草稿

validator
  负责：schema、器材可用性、安全边界、强度变化幅度、用户确认
```

大模型可以不断参与，但每次参与都必须产出结构化对象。

## 必须补齐的上下文

### PlanningContext

用于开局生成计划。

应该包含：

- `checkIn`：睡眠、疲劳、饥饿、压力、疼痛、可训练时间。
- `equipmentInventory`：家庭健身房器材清单。
- `exerciseHistory`：同动作最近重量、次数、RPE、失败原因。
- `recentRiskSignals`：疼痛、跳过、明显跟不上。
- `preferences`：偏好动作、讨厌动作、训练风格。
- `constraints`：今天不能做什么、时间限制、器材限制。

已实现字段：

- `checkIn`
- `equipmentInventory`
- `exerciseHistory`
- `recentRiskSignals`

待补字段：

- `preferences`
- `constraints`
- 更压缩的最近训练摘要。

### EquipmentInventory

器材需要和用户讨论后建档。第一版采用手动结构化登记，不做拍照识别或智能登记。

第一版不需要极其精细，但至少需要：

- 哑铃：重量范围、是否可调、最小增量。
- 杠铃/单杠/壶铃。
- 凳子、瑜伽垫。
- 机器：中文名、英文名、动作模式、调节方式、支持功能、限制条件、档位或重量范围。
- 有氧/自重选项：跑步、游泳、俯卧撑等可用训练方式。
- 空间限制。

已实现：

- `GET /profile/equipment`
- `PATCH /profile/equipment`
- 默认器材档案：多功能推举训练器、高位下拉训练器、哑铃、跑步、游泳、俯卧撑。
- 高位下拉训练器已明确限制：仅支持垂直下拉，不支持标准水平划船。
- Web UI 中的器材编辑页。

### SetContext

用于每组结束后的判断。

必须包含：

- 当前动作、当前组、当前目标。
- 实际完成次数、实际重量、实际时长。
- 本组开始/完成时间。
- 当前动作已完成情况。
- 今日总进度。
- 用户反馈选项和自由备注。
- 最近同动作表现。
- 当前 check-in。

部分已实现：

- 状态机记录 `activeSetStartedAt`。
- `SET_FINISHED` 可自动计算实际时长。
- pending set 记录开始/完成时间。
- UI 实际重量默认来自目标推荐重量。

待补：

- 独立 `SetContext` 构造器。
- 将当前进度、历史同动作表现、check-in 打包给真实大模型。

### TransitionContext

用于组间和动作间。

必须包含：

- 上一组记录。
- 下一组或下一动作目标。
- 当前休息时间。
- 规则层已做出的调整。
- 是否存在疼痛或危险信号。
- 用户在休息中追加的反馈。

部分已实现：

- `SUBMIT_TRANSITION_FEEDBACK`。
- 休息中可记录“还没恢复”“上一组太重”“动作注意”。
- `too_hard` / `not_followed` 会保守延长休息 30 秒。

待补：

- 独立 `TransitionContext` 构造器。
- 真实大模型生成组间提示和下一步建议。

## 推荐接口

### `draft_plan`

输入：

- `PlanningContext`

输出：

- `WorkoutPlan`
- `assumptions`
- `questions`
- `coach_message`

状态机处理：

- 进入 `awaiting_approval`。
- 用户可以接受、取消或继续讨论。

实现状态：

- 已实现为 `AiProvider.draftPlan(context)`。
- 已提供 `draftPlanWithFallback` 和 `createTemplateAiProvider()`。
- 已提供 `POST /sessions/current/ai/plan-draft`。
- 当最新 session 是 `confirmed`、`cancelled` 或 `aborted` 时，服务端会自动新建 planning session。

### `revise_plan`

输入：

- 当前 `WorkoutPlan`
- 用户回复
- `PlanningContext`

输出：

- 更新后的 `WorkoutPlan`
- 修改说明
- 仍需用户确认的问题

实现状态：

- 未实现。下一步如果选择多轮计划讨论，需要新增 `plan_discussion` 或在 `awaiting_approval` 下保存讨论线程。

### `draft_feedback_options`

输入：

- `SetContext`

输出：

- 2-4 个动作相关反馈选项。

实现状态：

- 已实现 `draftFeedbackOptionsWithFallback`。
- 当前输入仍是完整 `WorkoutSession`，后续应收敛为 `SetContext`。

### `propose_adjustment`

输入：

- `SetContext`
- `TransitionContext`

输出：

- `AdjustmentSuggestion`
- `coach_message`
- `safety_flags`

状态机处理：

- validator 校验。
- 需要改变已确认计划时，生成 pending adjustment。
- 用户确认或规则自动确认后应用。

实现状态：

- 已实现 `draftAdjustmentSuggestionWithFallback`。
- 当前仍是建议层，实际训练调整主要由规则层完成。

### `draft_transition_message`

输入：

- `TransitionContext`

输出：

- 组间提示、鼓励、动作注意点。

实现状态：

- 未实现真实 AI 版本。
- 已有模板化组间反馈记录和休息延长。

### `draft_summary`

输入：

- 完整 `WorkoutSession`
- 最近历史摘要

输出：

- 总结草稿。
- 下次训练建议。
- 风险提醒。

实现状态：

- 当前仍是规则/模板总结。
- 真实 AI summary draft 待智能模块选型后补。

## 已修复的基础问题

- `SET_FINISHED` 不再依赖 UI 手填实际时长。
- 状态机记录 `activeSetStartedAt`。
- pending set 记录 `startedAt` 和 `finishedAt`。
- UI 反馈页将实际时长显示为只读。
- UI 实际重量默认来自推荐重量，并提供“推荐”按钮恢复。
- 新增 `LOAD_PLAN_DRAFT`，允许外部/AI 计划草稿进入计划确认。
- 新增 API `POST /sessions/current/plan-draft`。
- 新增 API `POST /sessions/current/ai/plan-draft`。
- 新增器材档案 API 与 Web 编辑页。
- 新增历史重量推荐基础逻辑。
- 新增组间反馈事件。
- 新增 API server 注入式创建函数，便于未来替换真实 AI provider 和做端点测试。

## 仍需讨论的抉择

### 1. 大模型是主持计划讨论，还是只提交计划草稿？

方案 A：一次性计划草稿。

- 简单。
- 更快进入训练。
- 适合第一版。

方案 B：计划讨论多轮。

- 更像真正教练。
- 可以询问器材、疼痛、目标。
- 状态机和 UI 都要新增 `plan_discussion`。

建议：先做 A，但数据结构按 B 预留。

### 2. 器材清单粒度

方案 A：粗粒度文本。

- 快。
- 大模型自由理解。
- 校验弱。

方案 B：结构化器材档案。

- 可校验。
- 能推荐重量。
- 初始录入麻烦。

建议：做结构化档案，但允许大模型通过对话帮用户补全。

### 3. 组内是否允许反馈？

之前我们倾向“不允许中途打断”，只允许紧急停止。

现在建议保持：

- 组内：不做普通反馈。
- 组间/动作间：允许追加反馈。
- 紧急停止：始终可用。

### 4. AI 调整是否需要用户确认？

方案 A：规则安全范围内自动应用。

- 流程顺。
- 风险是用户可能不理解计划变化。

方案 B：每次调整都确认。

- 安全透明。
- 打断训练节奏。

建议：小调整自动应用并解释；大调整、换动作、提前结束需要确认。

### 5. 推荐重量由谁决定？

建议顺序：

1. 历史同动作表现。
2. 当前 check-in 与疼痛风险。
3. 器材可用重量。
4. 规则层安全范围。
5. 大模型给理由，但不能突破 validator。

## 下一步建议

在进入智能模块选型前，先做：

1. 结构化器材档案。
2. 计划草稿导入和确认 UI。
3. 计划讨论状态。
4. 组间反馈事件。
5. 历史推荐重量 helper。

完成这些之后再选模型，模型选型才有清晰接口和评测标准。
