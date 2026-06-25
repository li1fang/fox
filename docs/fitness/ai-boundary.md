# AI 边界

fox 健身模块采用：

```text
ai-plan-feedback 核心 + 有限 tool use 外层
```

这意味着系统主体不是自由 agent，而是确定性训练程序。AI 参与计划、建议、鼓励和总结，但所有状态推进由程序控制。

## AI 可以做什么

AI 可以：

- 根据用户档案生成训练计划草稿。
- 把旧记录转成可读总结。
- 根据反馈提出调整建议。
- 生成鼓励话术。
- 生成训练总结草稿。
- 解释为什么降低强度。

## AI 不能做什么

AI 不能：

- 直接启动计时器。
- 直接结束计时器。
- 直接跳转状态机。
- 在用户疼痛时继续推进高强度训练。
- 覆盖用户确认过的训练记录。
- 编造用户没有报告的完成次数。
- 做医疗诊断。

## Tool use 原则

未来可以给 AI 有限工具调用能力。

允许的工具类型：

- `propose_plan`
- `propose_adjustment`
- `draft_coach_message`
- `draft_summary`

不允许的工具类型：

- `force_state_transition`
- `write_confirmed_record`
- `override_timer`

## 建议对象

AI 输出应该是建议对象，而不是最终事实。

示例：

```json
{
  "kind": "adjustment_suggestion",
  "reason": "not_followed",
  "target": {
    "exercise_name": "Dumbbell Shoulder Press",
    "set_index": 2
  },
  "suggested_change": {
    "reps": 8,
    "weight": 7.5,
    "rest_seconds": 120
  },
  "coach_message": "这一组先降一点强度，保持动作稳。"
}
```

程序收到建议后必须校验：

- 是否处于允许调整的状态。
- 是否违反疼痛安全规则。
- 是否在可用器材范围内。
- 是否超出合理强度变化。

## 话术层

角色、人格、鼓励语气和未来视觉形象都属于表现层。

表现层不能改变：

- 训练计划事实。
- 用户反馈事实。
- 计时器状态。
- 安全规则。

旧记录中出现过角色化陪练话术。后续可以保留“陪伴感”这个产品目标，但不把历史角色话术写入核心逻辑。

