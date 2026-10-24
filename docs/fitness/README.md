# 健身与视觉：当前入口

更新：2026-10-23（Asia/Bangkok）。当前 iPad 候选：Fox **0.6.7 / build 23**。用户认为已经迈过初步可用门槛；本页把软件验证与真实训练验收分开记录。

## 先看什么

| 想了解 | 入口 |
| --- | --- |
| 下一次试用前一口气开发到哪里 | [三阶段集成路线图](../planning/NEXT_TRAINING_TRIAL_ROADMAP_V1.zh-CN.md)；[执行记录与试用清单](../planning/NEXT_TRAINING_TRIAL_EXECUTION_V1.zh-CN.md)：A0–A6 通过，0.6.8/build 25 联网试用就绪，离线专项后置，等待自然试用 |
| 当前能力、局限和本轮结果 | [策略与档案执行记录](VISION_STRATEGY_EXECUTION_20261023.zh-CN.md) |
| 为什么这样计次、恢复与测量 | [动作适配方法](ACTION_ADAPTATION_METHOD_V1.zh-CN.md) |
| 后续做什么、不做什么 | [任务台账](../planning/LIFE_LOG_BACKLOG.zh-CN.md) |
| 三动作策略和运行档案如何维护 | [策略与档案计划/操作](VISION_STRATEGY_AND_EVIDENCE_V1.zh-CN.md) |
| 语音研究与提示边界 | [语音引导 V1](VOICE_GUIDANCE_V1.zh-CN.md)，合并到集成路线，不再逐个 G 阶段发布 |
| 最近真人训练反馈 | [现场复盘](LIVE_TRIAL_REVIEW_20261023.zh-CN.md) |
| 原始录像上的可观察性 | [三动作评测](experiments/THREE_ACTION_OBSERVABILITY_V1.results.zh-CN.md) |

## 能力边界

- 弯举：侧面固定观察臂，完整周期计次；首轮与局部缺点有软件修复。侧平举：正面固定观察臂，完整周期计次。旧两动作回放没有退步，仍需正常使用覆盖疲劳、机位和遮挡变化。
- 高位下拉：背面上半身有限适配；峰端计次，前次返回观察在下一峰发布，末次不统计离心。615 帧开发缓存通过实际控制器和 iPad 回放，不等于新实时训练验收。
- 返回区间不是完整肌肉离心真值，计数不是动作标准评分。语音引导已完成分阶段设计；本地报数及实时提醒均尚未实现。
- 卷腹/卧推暂缓，等待后续正常训练录像；深度、多机、跨平台与大规模重构未启动。

## 文件归属

- `apps/ipad/FoxTrainingCore/.../Resources/motion-strategy-*.json`：动作语义，引用同目录 defaults；不复制阈值。
- `schemas/`：文件格式。`tests/scripts/`、Swift Tests：行为与正负例。
- `.data/vision-corpus/`、`.data/vision-replay/`：私有素材与原始批次，禁止进入 git。
- `.data/vision-evidence/runs/`：不可变运行目录；`index.sqlite` 是开发索引，可重建。
- `.tmp/`：构建、测试暂存；重要本轮日志另归档到 `.data/vision-evidence/audits/strategy-v1-20261023/`。

这是导航改善，不是一次文件搬迁。旧设计和旧失败报告继续保留；历史文档中的“当前”以其日期和执行范围解释。
