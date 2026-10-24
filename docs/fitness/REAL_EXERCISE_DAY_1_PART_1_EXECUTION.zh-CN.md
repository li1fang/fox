# Real exercise · Day 1 · Part 1 执行记录

日期：2026-10-06。依据：[开发计划](REAL_EXERCISE_DAY_1_PART_1.zh-CN.md)。状态：软件自动化验收通过；当前 Fox 0.4.0 / build 10 补修候选已安装、启动，原有草稿与记录保持不变。build 9 及其证据按历史保留。M4 真人相机与真实训练验收尚未完成，不标整体计划完成。

## 交付范围

复用原生 Fox，不启动 Web/API/Linux。训练页完成就位、倒计时、所选臂视觉计数、暂停、人工确认、休息、总结、历史和导出。独立视觉页继续作为诊断工具。

`Real exercise · Day 1` 是可编辑草稿，预定 2026-10-07 / Asia/Bangkok。每个动作暂设两组、每侧五次、2/1/3 秒节奏、90 秒休息，用于软件闭环准备，不是完整健身处方。所有重量留空；用户开始前确认动作、组数、次数、节奏、重量和身体状态。录像中的 7.5 / 5 kg 不自动套用。

## 工作包与证据

| 工作包 | 已实现内容 | 验收状态 |
| --- | --- | --- |
| P1-01 契约 | `accepted` / `observed_below_minimum` / `unobservable` 尝试事件；节奏事实独立，动作维度未评估、分数为空 | Swift 核心通过；不声称专业动作评判 |
| P1-02 回放 | 保留主体选择与完整画面；侧平举增加受约束的新鲜对侧躯干参考，不复用旧坐标 | 本视频逐峰及粗循环窗口通过；M4 未验收 |
| P1-03 绑定 | 当前组持久化 UUID、观察段 UUID；换组清零；暂停后新段不拼半次；配置每组冻结 | 核心、连续四组换手、竖屏暂停恢复与全量原生 UI 通过 |
| P1-04 闭环 | 正式训练页、左右分别核对、原自动值保留、实际时长自动算、离线总结 | 视觉四组确认重启、人工更正、相机拒绝人工路径及全量回归通过 |
| P1-05 恢复 | 原子保存、失败不推进、旧档案兼容、进程恢复暂停、有界证据及截断状态 | 核心通过；新增毫秒时间兼容回归通过 |
| P1-06 发布 | Fox 0.4.0 / build 10 候选；原有 Web 和核心回归 | 构建/签名/安装/启动及旧档案保留通过；M4 真人检查待完成 |

## 侧平举 v4 与录像边界

在 121 秒附近，所选左髋不稳定，但同一主体的新鲜对侧肩/髋仍可见。原 v3 的 0.30 秒运动阶段容差不足以跨过该缺失，首次循环被丢弃。

新策略 `fresh_opposite` 只在所选髋缺失或低置信度时使用同一主体、同一当前帧的对侧肩到髋向量。所选肩和肘仍必须可用；肩跨度、躯干长度、近似垂直关系和躯干方向各有门槛。两侧髋都不可用、主体不明确、所选臂不可见、躯干参照不合理时仍拒绝计数，不扩大长遮挡容差。弯举不使用该参照。

算法为 `lateral_raise_2d_v4`；弯举仍为 v3。缺少新参数的历史报告保留旧 v3 语义。每次代理参照帧数另存，涉及的节奏时长标为估计，不伪装成可靠精确时间。

| 本视频目标 | 当前候选计数 | 一对一顶峰 | 粗起点/顶峰/返回窗口 |
| --- | --- | --- | --- |
| A01 左弯举 | 10 | 10 | 10 |
| A02 右弯举 | 9 | 9 | 9 |
| A03 左侧平举 | 5 | 5 | 5 |
| A03 右侧平举 | 5 | 5 | 5 |

检查包含额外事件、漏事件、跨循环合并、返回后确认、主体粗检查点和负例窗口。旧 `replay-v3.json` 门禁仍返回 2，左侧漏 1 次，不改绿。

完整循环标签来自本轮完整画面的人工辅助复核：弯举 1 Hz、侧平举 2 Hz，两个关键边界再以 5 Hz 复核并保留修订记录。这是同一开发视频的粗窗口标签，不是盲测、专家动作标签或逐帧精确真值。Mac Vision revision 1 / 10 Hz 缓存不是 M4 实时相机。击掌不输入计数器；路人没有被剪掉。

私有文件在 `.data/vision-corpus/20261005-fox-fitness-reference/`，不提交：`replay-part1-v4.json`、`peak-acceptance-part1-v4.json`、`cycles-part1-coarse.v1.json`、`cycle-acceptance-part1-v4.json`。原视频哈希与归档位置保持不变。

在项目根目录复现，已有文件保持原名，不覆盖历史缓存或 v3 报告：

```bash
# 重新评价使用新输出名；会同时保留历史 v3 基线和当前版本结果
npm run vision:video -- evaluate \
  .data/vision-corpus/20261005-fox-fitness-reference/manifest.json \
  .data/vision-corpus/20261005-fox-fitness-reference/mac-vision-10hz.jsonl \
  .data/vision-corpus/20261005-fox-fitness-reference/replay-next-review.json

npm run vision:check -- \
  .data/vision-corpus/20261005-fox-fitness-reference/manifest.json \
  .data/vision-corpus/20261005-fox-fitness-reference/replay-part1-v4.json
npm run vision:cycles -- \
  .data/vision-corpus/20261005-fox-fitness-reference/cycles-part1-coarse.v1.json \
  .data/vision-corpus/20261005-fox-fitness-reference/replay-part1-v4.json
```

标签不确定或循环不对应会返回 2，错误来源或无效时间序列返回 1。只调参数让总数吻合不能通过逐事件门禁。

## 记录契约

正式组记录内嵌 `fox.workout_visual_evidence.v1`，绑定 session / exercise / set / attempt，包含算法与参数快照、观察侧、每次阶段事件、失败尝试、重置原因、覆盖范围及观察段。屏幕倾角、人工朝向、画面尺度和相机几何存入观察段的有界 `captureContext`，不推测米制距离。

实际左右次数由用户分别确认。没有观察的侧保持未知；差异不被平均数覆盖。更正后保留自动原值。节奏目标来自确认计划，缺失或代理躯干参照对应的阶段标为估计；动作质量为 `not_assessed`，不产生节奏/动作/总分。

Schema：`schemas/workout-visual-evidence.schema.json`。JSON Schema 检查结构，Swift 同时校验绑定、时间顺序、单调追加和评估一致性。正式记录不包含逐帧骨架、录像、人脸或路人轨迹。

## 自动化与待补验收

- 最新 Swift 核心：109 项通过。日志 `.tmp/part1-core-release.log`。
- 工作区类型、测试、构建：通过。日志 `.tmp/part1-workspace-release.log`。
- 浏览器流程：最终 16 项通过。日志 `.tmp/part1-e2e-release.log`。
- build 9 全量原生 UI：22 项通过。日志 `.tmp/part1-ui-release-full.log`。首轮失败截图与状态保留：正常模拟动作卡在最短时长边界、右臂模拟坐标越界、后台返回点击没有执行。没有放宽真实计数规则或删除断言。正常模拟动作留足时长并镜像右臂；恢复测试等待前台/可点击后短按，仍验证新观察段及累积次数。正式按钮完整触摸区域、暂停紧凑布局和人工开始文案也已优化。临时诊断已移除。build 10 的最新 23 项全量结果见下节。
- build 9 全量最后一个用例发生 XCTest 动画静止等待，执行 276 秒后断言全部通过，总运行约 764 秒；另有 Xcode 清理阶段 `simctl` 查找警告，最终退出码仍为 0。它们不是 M4 卡顿或性能结论，下一轮可单独优化测试等待，不删除恢复断言来缩短时间。
- 默认策略、全部 Schema、6 份历史真人报告及最终 UI 生成的四组正式视觉证据均通过结构检查；暂停恢复的正式记录另验证两个观察段、四次完整循环。历史数值轨迹精确复现 4、1 次；四份无数值轨迹的旧汇总保持“不可回放”，不补造数据。
- Fox 和 Fox Say 真机目标均构建成功。Fox 0.4.0 / build 9 在已配对 M4 iPad Pro 13-inch 上安装并启动；Fox Say 保持 0.1 / build 1，未重新安装或替代入口。没有主动启动相机、开始训练或生成完成记录。
- 安装前后，旧 confirmed session 的三组记录结构完全一致，六份视觉报告文件逐字节一致。可编辑 Day 1 草稿已保存到本机，日期 2026-10-07 / Asia/Bangkok，全部重量为空。设备回执和前后档案在 `.tmp/part1-device-*`，不进入 Git。
- 默认开发构建目录也已重建，确认含当前草稿和 v4 策略资源，避免后续安装旧产物。日志 `.tmp/part1-default-device-build.log`；首次候选使用独立目录 `.tmp/part1-ipad-device-data`。
- M4 实时就位、相机时延、左右计数、现场遮挡和真实训练体验：待独立验证。不得用模拟器或 Mac 回放替代。

训练期间不临时调算法。视觉不稳定时切人工完成，保留故障和已观察事实，不要求多练、加重或扭曲姿势来配合软件。Part 2 提醒、更多动作、语音、深度与 AI 本轮不启用。

## 续审补修：build 10

逐项审计发现：提前结束保存失败后，原界面仍停止相机，造成 active 与 stopped 不一致。新增 `testFailedEarlyEndKeepsCameraAndObservationForRetry`，先复现失败，再修为保存成功才停止相机并进入总结。后台心跳和视觉快照成功保存也不再清除未处理的错误提示；显式重试成功或用户关闭提示仍可清除。

- 先红结果：`.tmp/part1-ipad-simulator-data/Logs/Test/Test-Fox-2569.10.06_02-12-58-+0700.xcresult`，断言捕获“相机已停止”。没有删除这个断言。
- 针对性修复后通过：`Test-Fox-2569.10.06_02-14-06-+0700.xcresult`，验证错误提示不会被后台写入撤掉、相机与观测保持、重试结束、确认与重启后原始 2 次仍在，实际次数仍未确认。一次写失败注入仅用于隔离的 UI 测试档案，真机启动未传测试标志。
- build 10 全量原生 UI：**23 项通过、0 失败、0 跳过**；测试约 564 秒，竖屏暂停恢复约 38 秒。结果包 `.tmp/part1-ipad-simulator-data/Logs/Test/Test-Fox-2569.10.06_02-15-07-+0700.xcresult`，另以 `xcresulttool get test-results summary` 核对全部数量与 Passed 状态。清理阶段仍有 `simctl` 查找警告，但测试退出 0。不同运行时长不能说明 M4 性能改善。
- Swift 核心再次运行 109 项通过；计数、模型、Schema 和参数没有改动。本视频 `vision:check` 与 `vision:cycles` 再次通过，原视频 SHA-256 与归档一致；build 9 的工作区及浏览器测试按其原日志保留，本轮未改 Web/API。
- `npm run ipad:build:fox` 重建默认真机构建目录，版本 0.4.0 / build 10；签名严格校验通过，草稿与 runtime policy 资源和源文件逐字节一致。当前默认安装命令不再取 build 9 产物。
- 更新前重新读取 iPad 档案，未发现进行中的训练。build 10 安装、前台启动均成功；设备回执 `.tmp/part1-b10-device-install.json`、`.tmp/part1-b10-device-launch.json`、`.tmp/part1-b10-apps-after.json`。Fox Say 仍为 0.1 / build 1，未更新。
- 更新前后 `training-records.v1.json`、`vision-trials.v1.json`、旧 `vision-live-status.v1.json` 三个文件逐字节一致，只有原 confirmed session 的 3 组及 6 份报告。草稿日期与空重量保持不变；没有启动相机、新建训练或补造真人验收。私有快照 `.tmp/part1-b10-device-before`、`.tmp/part1-b10-device-after`。

## 下一次真实使用

完整要求与分层证据逐项对应见[验收审计](REAL_EXERCISE_DAY_1_PART_1_ACCEPTANCE_AUDIT.zh-CN.md)。其中包含本轮续审发现的提前结束保存失败问题，以及仍需 M4 真人确认的项目。

先在计划页确认或编辑草稿，不把软件示例当成完整训练处方。下一次真人测试需要独立核对侧身弯举和正面侧平举的启动、所选侧实际次数、漏计/误计位置、连续组及正常疲劳早停；从实际记录检查相机时延、机位标量和中断。当前只验收受支持机位，不宣称正面弯举可用。

正常训练过程中不改代码、不加练来迎合计数。漏计时人工核对，训练结束后再集中复盘。累积真实证据后再进入 Part 2，分别选择节奏和动作质量指标，不仓促加总分或扩动作库。
