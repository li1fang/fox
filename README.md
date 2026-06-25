# fox

fox 是一个个人生活助手项目。

当前阶段采用 **健身优先、中文为主、可开工规格**：先把 fox 定义为一个个人生活日志系统，再把健身模块做成第一个可运行闭环。第一版目标不是全自动智能生活管理，而是一个可靠的训练主持系统：计划、倒计时、反馈、动态调整、总结确认。

## 当前阶段

健身 runtime 原型与 AI 介入接口设计阶段。

当前已有本地 Web Runtime UI、后台 API、SQLite 持久化、规则教练和 AI provider 接口地基。下一步重点是智能模块选型：选择真实大模型、ASR/TTS 边界和计划讨论策略；暂不实现姿态识别、3D 形象或本地大模型。

## 核心路线

1. fox 的底层是统一的个人生活日志。
2. 每条记录都保留原始证据、结构化草稿、用户确认结果。
3. 健身是第一条主线，因为它已经有过可用原型经验，而且最适合先做闭环。
4. 第一版健身不追求自动感知，只追求训练流程稳定。
5. AI 负责计划、建议、鼓励、总结；计时器和状态机由确定性程序控制。

## 当前可运行能力

- 浏览器完成一次训练闭环：check-in、计划确认、动作执行、组后反馈、休息倒计时、总结确认。
- SQLite 保存 session、event log 和 confirmed fitness Entry。
- 器材档案可编辑，并进入计划草稿上下文。
- 历史同动作记录可用于推荐重量。
- AI provider 目前使用模板实现，接口已预留给真实大模型。

## 文档地图

- [项目愿景](docs/vision.md)
- [产品简报](docs/product-brief.md)
- [初始讨论记录](docs/initial-discussion.md)
- [系统架构](docs/architecture.md)
- [数据模型](docs/data-model.md)
- [阶段路线图](docs/roadmap.md)
- [开发路线图](docs/development-roadmap.md)

## 健身模块文档

- [健身产品设计](docs/fitness/fitness-product.md)
- [训练主持循环](docs/fitness/coach-loop.md)
- [训练状态机](docs/fitness/state-machine.md)
- [AI 边界](docs/fitness/ai-boundary.md)
- [训练运行界面调研](docs/fitness/runtime-ui-research.md)
- [训练运行界面设计](docs/fitness/training-runtime-ui.md)
- [大模型介入接口复查](docs/fitness/llm-integration-review.md)
- [2024 旧训练记录整理](docs/fitness/recovered-2024-log.md)
- [初始用户档案](docs/fitness/user-profile.md)

## Schema

- [统一 Entry schema](schemas/entry.schema.json)
- [领域 payload schema](schemas/domain-payloads.schema.json)
- [schema 示例](schemas/examples.md)

## 第一版非目标

- 不做姿态识别。
- 不做自动计数。
- 不做 3D 形象。
- 不做语音交互。
- 不运行本地大模型。
- 不做全自动记账导入。
- 不做医疗诊断或自动用药决策。
