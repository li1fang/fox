# 视觉 M1/M2 执行记录

日期：2026-10-23。范围见 [四里程碑计划](VISION_M1_M4_PLAN_20261023.zh-CN.md)。本轮结束于 M2 复盘，不启动高位下拉或卷腹适配。

## M1 进度

- 已先增加真实控制器测试；旧实现双动作/双侧在准备走回、重新就位后二次离开时锁死，20 个断言失败。额外验证准备歧义未重置倒计时、正式训练的相机中断恢复会自动重新准备，后者独立测试 3 个断言失败。
- 准备阶段失去旧主体时重新等待，失效旧倒计时；歧义重新等待完整倒计时。运动中 `.lost` 仍需用户显式重新就位，不自动接手路人。
- 准备取消也通知正式训练协调器，撤销旧准备意图；相机恢复不擅自开始。准备时间不计入正式运动时间，重新就位分段保留。
- 独立视觉按钮与正式训练统一为“就位后开始”；已有组为“就位后继续”。等待时保留取消，暂不自动选择或更换手臂。
- 未修改 `CurlTracker`、`PoseSubjectSelector` 的运动中规则、计数/离心配置或 `PoseEccentricEstimator`。

### 自动验证

- Swift 核心 120/120，通过；私有真实输入实际存在并执行，未因缺素材跳过。包括侧平举 5/5 全 trace、左右弯举 7/6、旧冻结策略和离心区间/弃权测试。
- iPad App-host 62 项：60 通过，2 个 iPhone 专属测试跳过。实际控制器 22/22，包括两份真实全候选包、旧 M4 视频缓存、准备/计数/恢复及正式训练保存。
- 右臂历史包原先准备锁死的部分会更早恢复，不能再要求准备过程与旧 Bug 逐帧相同；测试改为比较进入原运动阶段后的主体和事件，将两次开始时间对齐到同一原始 PTS 后，逐次比较计数时刻、各阶段时长、离心状态/起止/确认时刻及不确定区间，精度 1e-6 秒。未放宽最终次数，仍为左 7、右 6。
- iPad 定向 UI 5/5；iPhone App-host 62/62、定向 UI 3/3。包含等待后自动开始、取消、丢失后重新就位、侧平举再切弯举、正式训练后台暂停/续组、手机横屏快捷项锁定。iPad 等待/计数截图已检查，主操作可见，无新增覆盖。
- 与 R2 源码归档逐字节比较，计数器、离心估计器、主体选择/运行策略、倒计时核心及两份默认 JSON 均相同；见 `.tmp/vision-m1-frozen-sources.log`。

日志：`.tmp/vision-m1-red.log`、`vision-m1-red-additional.log`、`vision-m1-camera-red.log`、`vision-m1-green-final.log`、`vision-m1-core.log`、`vision-m1-ipad-ui.log`。

## M2

M1 自动验收已通过，开始 M2。已有 `FoxPoseExperimentKit` 和 M4 视频推理缓存可复用；新增范围限于端侧任务组织、实际控制器回放、可追溯报告与校验取回，不迁移正式训练、不建设独立产品。

预先设计的测试：单任务多动作/侧别与生产控制器一致；输入/配置摘要可追溯；缓存不调用 Vision；损坏哈希、路径穿越、重复时间、空片段、未知版本拒绝；取消/退出前台不能生成 completed；重复任务不覆盖成功结果；结果取回时缺文件/篡改/未完成不能接收；原训练与生活记录不变。先实现合成自动测试，再用现有 M4 缓存和真实诊断包验证设备链路，视频路径复用原提取器。

### 已实现与发现的问题

- [动作适配规范](ACTION_ADAPTATION_METHOD_V1.zh-CN.md)与 [iPad 批回放用法/契约](IPAD_REPLAY_BATCH_V1.zh-CN.md)已建立。DEBUG 入口接受 cache、diagnostic、video；同一生产控制器、隔离输出、完整配置快照、逐次节奏和逐帧状态。
- 真机第一轮并未成功：页面前台触发不启动。新增入口 UI 测试先失败，再修为 UIKit 生命周期通知；平板和手机均验证通过。
- 第二个真机问题是 CoreDevice 上传目录归系统用户所有，App 能读却不能在其中创建 `Runs`。用户也观察到“0 帧/无保存权限”。新增只读输入目录测试复现权限拒绝后，把 App 自有输出改为同级 `FoxReplayRuns`，不要求用户手动授权、不修改设备安全设置。
- 增加入口状态回执；30 秒无处理回执即明确失败，不再静默等 10 分钟。处理进行中仍有 10 分钟总上限。
- 接入提取库曾造成 App-host 重复链接核心库警告，测试目标改为从宿主使用已有核心库，不再次直接链接；最终日志已无重复类警告。
- 最终 App-host：iPad 69 项（67 通过，2 手机专属跳过），iPhone 69/69；批回放 7/7。两平台额外入口 UI 各 1/1。核心再次 120/120。`npm run verify` 通过，包含 34 项 workspace 测试和 58 项脚本测试；脚本最后修改后另跑 58 项。
- 最终集成构建再次通过准备走回、计数后丢失/重新就位两个 UI 回归（2/2），见 `.tmp/vision-m1-m2-ui-final.log`。关键三项入口测试提供 `npm run test:vision:flow`，已接入现有 macOS CI 配置；本轮未推送/触发远端 CI，不能把本地通过表述为 GitHub Actions 已通过。
- 上述统一入口本地实际运行 3/3 通过，见 `.tmp/vision-m1-m2-flow-entrypoint.log`。Xcode 的附加模拟器诊断收集仍有 `simctl` 定位警告，测试本身与 xcresult 均成功；未为此修改全局 `xcode-select`。

### 设备缓存链路

设备为 `iPad16,5`，系统 `26.6.2 (23G90)`，Fox `0.6.5/build 20`。任务 `4A1A9D89-00BB-47AD-987A-E2C7BBF0B2E7` 已 completed 并由 Mac 校验接收，`inferencePerformed=false`。

两动作的四个侧别片段为 9、9、4、4 次，换器材和离场两个片段为 0；这些是旧开发素材，不是本次新真人真值。与模拟器同一缓存输出的四个片段逐项比较：1,700 帧完整 trace、所有逐次事件/离心字段和配置 **完全相同**，不是只比较总数。见 `.tmp/vision-m2-host-device-parity.log`。

入口红绿：`.tmp/vision-m2-route-red.log` / `vision-m2-route-green.log`。权限红绿：`vision-m2-permissions-red.log` / `vision-m2-permissions-green.log`。最终手机：`vision-m2-phone-owned-output.log`。设备缓存：`vision-m2-device-cache-owned-output.log`。

### 完整录像与近期诊断包

| 路径 | 任务 UUID | 结果 |
| --- | --- | --- |
| 完整原视频 -> iPad Vision -> 实际控制器 | `7D8591E4-97FD-4696-BC6C-FC5FA872E61B` | 2,004 帧重新推理，`inferencePerformed=true`；六片段 9/9/4/4/0/0，全部校验取回 |
| 上述新缓存 + 导出的配置 -> 同机重放 | `D7FDC9D3-FDE5-48E1-8C94-5615C96815A6` | 不再推理；六片段完整 trace、逐次事件与离心字段完全一致 |
| 最新左臂原始诊断观测 -> 同机重放 | `4FD4BB3B-7B16-46FF-B668-5E66CF394DD1` | 7 次，原 capture PTS，未新增人为重新就位 |
| 最新右臂原始诊断观测 -> 同机重放 | `3F90FD96-157E-4F97-B452-54DC510DBC63` | 6 次，保留原事件中的重新就位命令 |

完整原片 SHA-256 为 `48b5913c45da677819ca2e18791865b624518d351ce5592e2d3a051a6fde7d66`；未剪掉路人/换器材，未使用音轨计数。新推理与旧 M4 缓存的六片段控制器结果也完全一致，见 `vision-m2-fresh-inference-parity.log`；新视频与新缓存复现比较见 `vision-m2-video-cache-parity.log`。四个运动片段 26 个事件都有独立下放区间输出，但这不是 26 个经人工标定的生理离心真值。

私人任务、输入副本与校验后的结果位于 `.data/vision-replay/`，均被 Git 忽略。脚本日志 `vision-m2-device-video.log`、`vision-m2-device-fresh-cache.log`、`vision-m2-device-diagnostic-left.log`、`vision-m2-device-diagnostic-right.log` 位于 `.tmp/`。

## 安装与记录保留

- 已保留数据覆盖安装 Fox 0.6.5/build 20 到 iPad；未卸载，未更新 iPhone/Fox Say，未修改信任或系统安全设置。
- 最后无批任务环境变量启动正常 Fox，CoreDevice 确认成功，运行进程 PID 5920 核对一致。不是把批任务页作为正常首页交付。
- 安装前与全部运行后的训练 JSON、视觉 JSON、Journal SQLite/WAL 逐字节相同，附件目录清单相同；排除易变的 SQLite SHM。保留 13 份视觉报告、2 个训练会话及 3 条组记录。该 iPad 的生活库本来为空；未触碰手机的照片记录。
- 证据：`.tmp/vision-m1-m2-retention.log`、`vision-m1-m2-normal-launch-verified.log`。最终核心源码/配置再次与 R2 归档比较不变：`vision-m1-m2-frozen-sources-final.log`。
- 签名严格检查通过；当前描述文件仍到 **2026-10-30 07:51:41 +07**，不把本次重装说成额外延长了有效期。

## 停点

M1 软件修复与回归、M2 软件/端侧任务和结果取回闭环完成。现在暂停复盘，**不进入 M3/M4**，也不要求用户立即增加一次运动测试。复盘后用户同时提供高位下拉与卷腹录像，再先评估可观察性和机位，确定两个动作的实际推进顺序。

## 剩余边界

自动化与历史录像回放不是新真人训练验收。离心仍是二维可见阶段区间估计，不是肌肉真值或即时动作质量提醒。M3/M4 等本轮复盘后用户补充两份录像。

同日后续：用户已提供高位下拉、卷腹及额外卧推录像，并确认机械打点为回放后补录。原片已校验归档，见 [复盘与新素材接收](VISION_M1_M2_REVIEW_AND_NEW_CORPUS_20261023.zh-CN.md)；这不改变上述设备验证范围，三个新动作尚未做 Vision 可观察性评测或适配。
