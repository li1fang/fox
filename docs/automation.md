# 自动化流水线

fox 当前有以下测试流水线：

1. 桌面浏览器训练流程自动化。
2. 本地 iPad 真机安装与启动 smoke test。
3. 原生 Swift 训练核心测试与 iPad 模拟器 XCTest UI 流程。
4. 独立通用记录存储核心、真实进程终止恢复、备份契约与 iOS SDK 编译检查。
5. 正式 SwiftUI View 的隔离设计场景、截图 / AX / 几何采集与本地审查报告，见 [UI 审查入口](design/LOCAL_UI_REVIEW.zh-CN.md)。此项不代替功能回归或真实相机验收。

## 下次训练候选的集成验收

`test:trial` 连续执行核心、存储、Schema 反例、逐事件历史回放、原生 App-host、iPad UI、iPhone 布局、真实语速系统 TTS、Web 验证与 Playwright。它不安装真机，不修改个人记录，不将软件通过自动升级成 `trial_ready`。

```bash
python3 -m venv .tmp/schema-venv
.tmp/schema-venv/bin/python -m pip install -r scripts/journal-schema-requirements.txt
FOX_JOURNAL_PYTHON="$PWD/.tmp/schema-venv/bin/python" npm run test:trial -- .data/trial-readiness/<fresh-run-name>
```

可用 `FOX_TRIAL_IPAD_SIMULATOR` / `FOX_TRIAL_IPHONE_SIMULATOR` 显式指定现有模拟器。目录必须是新运行目录；已有回执不覆盖。A0 私有输入及参考结果缺失/摘要不符即失败，不能用跳过声称完整回归。源码在运行前后、每步之间检查；测试期间不要同时改代码。文档整理不会改变候选代码指纹。

每步保存命令、退出码、日志摘要、原生通过/跳过列表；不允许零测试或非预期跳过。iPad 批次中的 iPhone 专属布局跳过由独立 iPhone 批次覆盖。失败终止后续步骤，回执保留失败；修复后新建运行目录重跑。当前范围与必需真机门槛见[三阶段路线图](planning/NEXT_TRAINING_TRIAL_ROADMAP_V1.zh-CN.md)。

## 原生 Home 手机候选（2026-10-17）

新增 `iphone:doctor` / `iphone:build` / `iphone:install` / `iphone:open`，只选已配对 iPhone、只处理 Fox、使用独立 `.tmp/home-iphone-derived-data`。不会默认落到 iPad 或顺便安装 Fox Say。doctor 与定向 build 都检查实际 Developer Mode，不把配对成功当作手机可运行。

Home 使用 `FoxJournalCore` 的独立测试目录，新增默认入口的 `FoxHomeUITests`，与显式启动训练/视觉的旧测试分开。测试范围包含真实 SQLite 保存、重启读回、写失败重试、训练入口与暂停返回；当前执行结果见 [候选记录](planning/HOME_IPHONE_CANDIDATE_V1.zh-CN.md)。

```bash
FOX_IOS_SIMULATOR=<iPhone-simulator-id> FOX_IOS_UI_TEST=FoxUITests/FoxHomeUITests npm run test:ipad:ui
```

这个旧命名测试入口可以通过显式 ID 使用手机模拟器，默认仍选择 iPad。测试 runner 只安装到模拟器，不操作手机或 iPad 真机；模拟器屏幕尺寸通过不等于 iPhone 13 Pro Max 的安装、授权和使用验收。本轮不自动升级 iPad。

### N3 记录闭环

```bash
npm run test:home
FOX_IOS_SIMULATOR=<iPhone-simulator-id> FOX_IOS_UI_TEST=FoxAppTests,FoxUITests/FoxHomeUITests,FoxUITests/FoxJournalUITests npm run test:ipad:ui
FOX_IOS_SIMULATOR=<iPad-simulator-id> FOX_IOS_UI_TEST=FoxAppTests,FoxUITests npm run test:ipad:ui
```

`test:home` 运行 14 项 App 层测试：真实临时 SQLite、照片字节/方向、加载和保存失败、并发保存、修订冲突、删除、超过 1000 条分页、备份往返/损坏/冲突与取消清理。UI 新增 `FoxJournalUITests`，覆盖照片经验证后保存、失败保留、更正重开、拒绝权限、系统文件选择器取消和删除确认。结果与真机门槛见 [N3 实施记录](planning/HOME_LOCAL_CAPTURE_N3.zh-CN.md)。合成照片不代表真实相机，目录往返不代表某个系统文件提供器已完成保存。

普通 `iphone:open` / `ipad:open:fox` 只激活应用，不再默认终止已有进程，避免丢弃正在输入的内容。显式启动参数（如视觉入口）或 `FOX_IOS_RELAUNCH=1` 才请求重启；此时必须先处理未保存输入。本轮未实现跨强制退出的输入草稿恢复。

### 无线连接与解锁边界

2026-10-17 首次更新时，iPhone 为 `wired`；0.5.1/build 12 安装成功，锁屏时启动被 `Locked` 拒绝，用户解锁后启动成功。后续无线专项已通过：安装前后均为 `transportType=localNetwork`、TCP tunnel connected，重复安装同一 build 12、启动、应用版本与 PID 928 查询成功，进程属于本次安装容器。此为一次无线 build 12 安装/启动 smoke，不是长时间、锁屏或网络中断可靠性保证。

证据：`.tmp/n3-phone-wireless-before.json` / `n3-phone-wireless-after.json`、`.tmp/n3-phone-wireless-install.log` / `n3-phone-wireless-launch.log`、`.tmp/n3-phone-wireless-app.json` / `n3-phone-wireless-processes.json`。原始设备信息留在被忽略的 `.tmp`，不提交公开仓库。iPad 仅做局域网设备/文件目录只读查询，没有更新或启动相机。

| 工作 | 是否需要真机连线 / 解锁 |
|---|---|
| 代码、普通构建、核心测试、模拟器 UI、数值回放 | 不需要两台真机参与；签名更新和设备注册仍可能涉及账号或设备准备 |
| 真机发现、安装、读取可访问资料 | 已配对且无线通道可达时可不插线；锁屏/休眠/重启后状态可能限制服务，不承诺永远无人值守 |
| 真机前台启动、调试、UI 操作 | 网络不能绕过系统锁屏；通常需用户先解锁，再保持测试期间可用 |
| 拍照、真实人体关键点/训练验收 | 需要相机权限、前台可用和真实场景，不能用模拟器或远程安装替代 |

可采用“Mac 自动开发/回归 -> 合格候选 -> 用户短暂解锁 -> 无线安装/启动/实测”的流程，不要求开发全程连接数据线或保持屏幕亮着，也不为自动化取消密码/Face ID。当前测试输入经用户授权可在更新时打断，不必每次再询问草稿价值；这不表示可默认批量删除数据。生产版后的备份、迁移和发布门槛另定。

无线需要配对、Developer Mode 和实际可达的开发通道，不是只要同一个 Wi-Fi 名称就足够；设备休眠、网络隔离或 VPN/防火墙都可能影响连接。Mac 接有线、设备接同一可互通局域网的 Wi-Fi 也可使用网络发现。iPhone 的无线部署已完成上述一次验证，后续每次仍检查实际通道与系统状态。无线开发通道不等于 Fox 两设备记录已同步。

参考：[Apple 无线运行说明](https://help.apple.com/xcode/mac/current/en.lproj/dev3e2f4ee6d.html)、[Apple 开发工具工程师关于锁屏启动的说明](https://developer.apple.com/forums/thread/732481)、[Apple TN3158 网络连接排障](https://developer.apple.com/documentation/technotes/tn3158-resolving-xcode-15-device-connection-issues)。具体行为以本机命令和系统错误为准，不照搬其他 Xcode 版本的设置菜单。

### 开发签名续期

2026-10-23 已对 iPad Fox 0.6.3/build 18 完成一次保留记录的续期：备份设备数据和原 App，只暂存匹配 Fox bundle/team 的旧本地 profile，运行 `node scripts/ipad.mjs build fox`。Xcode 自动签名实际生成新描述文件，到期时间变为 2026-10-30 07:51:41 +07。之后显式选定 iPad 执行 `install fox`、`open fox`，核对进程、记录、诊断文件、数据库和偏好设置。详见 [续期与简单体验清单](fitness/LIVE_RELIABILITY_R1_EXECUTION_20261023.zh-CN.md#6-同版签名续期与覆盖安装)。

此操作不卸载 App、不撤销共享证书、不批量清空 profiles，也不自动更新其他设备或 App。构建可能复用旧签名，所以必须解码候选包内 `embedded.mobileprovision`，比较实际到期时间、bundle/team 及目标设备，签名校验通过后才覆盖安装。申请失败时保留原可用 App 和旧描述文件备份，不把失败候选安装到设备。本轮没有建立自动续期计划任务。

## 通用记录与存储（2026-10-16）

```bash
npm run test:journal
npm run test:native:all
```

前者运行 `FoxJournalCore` 的 29 项测试、实际合成备份的 JSON Schema 校验与 7 类格式反例、iOS 16 arm64 库编译；后者先运行旧训练核心再运行同一存储入口。需要 macOS、完整 Xcode、Node.js 和 Python `jsonschema`，依赖安装方式见 [存储规格](journal/RECORD_STORAGE_V1.zh-CN.md)。可用 `FOX_JOURNAL_PYTHON` 指定 Python 路径。

本地 `test:native:all` 与 `verify` 均通过；GitHub Actions 的 macOS 任务已加入存储测试，但不宣称已在远端执行。夹具只使用合成数据和临时目录，进程退出测试不触碰个人档案。该流水线不测试前端、不安装 App；iOS SDK 编译不是 M4 或 iPhone 运行验收，进程终止恢复也不是断电验收。新库尚未连接训练 JSON 或 Mac API。

## 原生 Fox（D0 / D1 / Part 1）

2026-10-06：Part 1 候选的 Swift 核心 109 项、build 10 完整原生 UI 23 项通过；build 9 工作区与浏览器 16 项结果按原日志保留，本轮未改 Web/API。完整原生包包含连续四组/换手/人工更正/重启、竖屏暂停恢复、相机拒绝、新鲜对侧躯干参照及提前结束写失败重试用例。模拟器输入不是 M4 相机验收，详见 [执行记录](fitness/REAL_EXERCISE_DAY_1_PART_1_EXECUTION.zh-CN.md)。以下旧版本测试数量按历史保留。

```bash
npm run test:native
npm run test:ipad:ui
npm run ipad:run
```

`ipad:run` 和默认 `ipad:smoke` 对 Fox 只构建、安装和启动，不启动任何 Web/API 服务。Fox 启动不读取 `FOX_WEB_URL`。

UI 测试使用单独的 `ui-test-records.json`，覆盖断开旧 URL 的原生闭环、历史重开和未完成组恢复；测试不触碰真机训练记录。可用 `FOX_IOS_SIMULATOR=<simulator-udid>` 选择模拟器。

入口显式选择整个 `FoxUITests` 测试包。0.3.4 的完整包应执行 17 项，包含参数配置/锁定、闪烁侧平举与原 15 项回归；不能只看到旧测试绿色就算通过。测试包发现/选择问题与应用运行失败分别诊断。

入口会启动模拟器并重装模拟器的测试 runner，不卸载 Fox、不清理应用数据，不操作真机。遇到执行内容与源码不一致时可以指定独立构建目录；开发时可单独选择测试，但完整验收仍运行默认的整个包：

```bash
FOX_IOS_UI_DERIVED_DATA="$PWD/.tmp/ipad-reliability-cold" npm run test:ipad:ui
FOX_IOS_UI_TEST=FoxUITests/FoxVisionUITests/testParametersApplyPersistResetAndLockDuringTrial npm run test:ipad:ui
```

本轮曾观测到当前构建文件已更新、运行日志仍执行旧断言；隔离构建目录并移除模拟器旧 runner 后，参数专项执行了新的代次标记并通过。不能仅凭构建成功认定执行的是当前测试。

视觉参数的默认 JSON 在 `apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore/Resources/pose-counter-defaults.json`。iPad 视觉页的参数按钮可以编辑/导入/导出，准备和记录期间锁定。本地覆盖文件坏了保留证据；显式应用新参数时备份坏文件再替换。

数值诊断可回放，不保存或上传影像：

```bash
npm run vision:replay -- /absolute/path/report.json
npm run vision:replay -- /absolute/path/report.json /absolute/path/candidate-configuration.json
```

仅 v2 且启用数值诊断、无截断的报告可完整回放。工具先要求原参数重现原次数及阶段记录，再比较候选参数；不改原报告。旧报告/关闭诊断/达到容量上限会明确失败，不将部分记录冒充完整验收。

D1 核心测试覆盖角度/投影、左右臂隔离、完整循环、静止/半程、遮挡/多人/低置信度、断帧/换目标、暂停、原始计数与人工修正、报告重载和写入失败。

`LateralRaiseTests` 覆盖躯干参考角、像素比例和旋转、所选左右臂循环、静止/半程/瞬跳、髋/腕缺失、遮挡/多人/断帧/暂停/换目标、超时、腕部弯举不误计上臂抬起、采样质量随动作切换及定时抖动。新增 UI 流程验证「侧平举计数 → 正面标签/参考保存 → 重开 → 弯举仍可独立计数」，以及髋缺失不启动、右臂竖屏控件/保存。测试数据不要求正好卡在 0.20 秒运动阶段边界，避免将系统定时抖动误当成算法回归；真实算法门槛不因此放宽。

`VisionCaptureContextTests` 另覆盖屏幕 0°/90°/180°、前后镜头俯仰符号、横竖摆放、异常重力、画面尺度、无人/多人/低置信度缺失值、1 Hz 限流、1800 条上限、旧报告兼容与 fixture 来源隔离。角度公式测试不是传感器实物精度校准。

视觉 UI 测试仅在 `FOX_UI_TESTING=1` 时读取 `FOX_POSE_FIXTURE`，显式显示「测试数据」，使用独立 `ui-test-vision-trials.json`。覆盖计数/更正/保存/重开/导出入口、相机权限拒绝、无人/多人/低置信度及横竖屏主要控件。启动回归额外模拟「先点击，再走入镜头且仅所选臂可见」，以及取消倒计时和离开视觉页取消准备；倒计时失去关键点、断帧和取消后重新准备由 `PoseStartGateTests` 验证。模拟器不提供真实人体推理和准确率证据。

机位回归覆盖「开始前标注侧面 → 保存时改成混合机位 → 重开仍保留」，并检查报告有机位样本。`motion_unavailable` 模拟无传感器，必须显示「未测得」且仍可计数、保存。其他传感器 fixture 明确为测试来源，不可冒充 M4 实测。真机升级前后另比对既有报告，不能为补字段而改写旧记录。

打开已安装 Fox 的真实视觉入口：

```bash
npm run ipad:vision:open
```

该入口只传入 `FOX_START_SCREEN=vision`，不传入测试数据，不启动服务器。相机权限由用户在 iPad 系统提示中授权。真机测试与参考次数要求见 [D1 规格](fitness/D1_LOCAL_POSE_SPEC.zh-CN.md)。

## 基础验证

```bash
npm run verify
```

这会依次运行：

- TypeScript typecheck
- 单元与 API 测试
- production build

## Playwright 训练流程

```bash
npm run test:e2e
```

Playwright 使用独立端口和独立 SQLite：

- API: `http://127.0.0.1:4187`
- Web: `http://127.0.0.1:5187`
- DB: `.tmp/playwright.sqlite`

测试会从首页开始，生成计划草稿，接受计划，完成全部训练组，确认总结，并断言进入 confirmed 状态。

## LAN 开发

```bash
npm run dev:lan
```

默认使用本机检测到的局域网 IPv4 地址。也可以手动指定：

```bash
FOX_LAN_HOST=192.168.1.20 npm run dev:lan
```

## iPad 真机链路

目前是两个独立应用：

- `Fox`：原生本地训练应用，Bundle ID `com.whipa.fox`。
- `Fox Say`：语音实验应用，Bundle ID `com.whipa.foxsay`，默认打开 `/?mode=say`。

检查环境：

```bash
npm run ipad:doctor
```

生成 Xcode 工程：

```bash
npm run ipad:generate
```

构建、安装、打开：

```bash
npm run ipad:build
npm run ipad:install
npm run ipad:open
```

默认 `ipad:build` 和 `ipad:install` 会处理两个 App。只处理某一个 App 时使用：

```bash
npm run ipad:build:fox
npm run ipad:build:say
npm run ipad:install:fox
npm run ipad:install:say
```

分别打开两个 App：

```bash
npm run ipad:open:fox
npm run ipad:open:say
```

Fox Say 的局域网运行入口：

```bash
npm run say:ipad-run
```

完整 smoke test：

```bash
npm run ipad:smoke
```

首次安装后，如果 `ipad:open` 报告 development profile 未被信任，需要在 iPad 上打开 Settings > General > VPN & Device Management，信任 Apple Development profile，然后重新运行：

```bash
npm run ipad:open
```

脚本默认选择唯一 paired iPad。若有多台设备，使用：

```bash
FOX_IOS_DEVICE=<device-id-or-name> npm run ipad:smoke
```

如果使用 Apple 免费开发者 profile，iPad 同一时间通常只能保留 3 个由该 profile 安装的开发 App。若安装 `Fox Say` 时提示已达到上限，需要先在 iPad 上删除一个旧开发 App，或改用付费 Apple Developer 账号，然后重新运行：

```bash
npm run ipad:install
```

脚本不会修改全局 `xcode-select`，而是固定使用：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## CI

GitHub Actions 只运行云端可执行的流水线：

- `npm ci`
- `npm run verify`
- `npx playwright install --with-deps chromium`
- `npm run test:e2e`
- macOS runner 上的 `swift test --package-path apps/ipad/FoxTrainingCore`
- macOS runner 上的 `npm run test:journal` 和 `npm run test:home`（安装 XcodeGen 后）

CI 配置已有这些入口，本轮未推送或触发远端任务，不宣称云端已经执行通过。iPad 真机安装与启动不进入 GitHub CI，因为云端 runner 无法访问本地 iPad。

## 视觉诊断取回（2026-10-17 补充）

`npm run vision:pull` 在 Mac 通过已配对开发通道取回 Fox 最近已保留的诊断目录，不取临时缓存，支持 `-- --id <UUID>`；`-- --fixtures` 仅用于明确的合成样本自测。无需 Web/API/Linux runtime，不在后台自动上传视频。首版断线后重新拉取，没有断点续传。

`npm run vision:import -- <folder>` 接收手工从系统「文件」导出的目录。两种入口均校验路径、文件尺寸/SHA-256、来源及实际视频流/时间轴，再落到被 Git 忽略的 `.data/vision-diagnostics/inbox/<UUID>`；同 ID 不同内容拒绝，设备原件不删除。需要本机 `ffprobe` 检查完整视频，无视频的失败诊断可仅接收元数据。完整契约与验收边界见 [视觉诊断录像 V1](fitness/VISION_DIAGNOSTIC_CAPTURE_V1.zh-CN.md)。

核对后保留/丢弃的回归入口：

```sh
FOX_IOS_UI_TEST=FoxAppTests,FoxUITests/FoxDiagnosticUITests,FoxUITests/FoxVisionUITests,FoxUITests/FoxWorkoutVisionUITests npm run test:ipad:ui
```

交互测试使用合成帧；验证准备失败也能事后保留、丢弃不改训练报告及取消导出不丢原件，不代替真人相机测试。

## 训练候选物理设备视听验收

规格和停止条件见 [真机视听并行验收](planning/TRIAL_DEVICE_INTEGRATION_TEST_V1.zh-CN.md)。`DeviceIntegrationTests` 不出现在模拟器测试清单中，不能用模拟器成功替代设备关卡。

执行前备份记录与附件，检查签名，并确认目标设备已用 USB 连接、解锁、相机已授权且固定机位。本轮按用户 2026-10-23 决定保持联网，不再要求断网或反复验证开发者。只在设备准备好后运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TEST_RUNNER_FOX_DEVICE_INTEGRATION=1 TEST_RUNNER_FOX_REAL_SPEECH=1 \
xcodebuild -project apps/ipad/FoxPad.xcodeproj -scheme Fox -configuration Debug \
  -destination 'platform=iOS,id=<paired-device-udid>' -derivedDataPath .tmp/trial-device-build \
  -only-testing:FoxAppTests/DeviceIntegrationTests \
  -only-testing:FoxAppTests/NativeSpeechTests/testProductionSessionNotificationsDoNotCancelItsOwnSpeech \
  -allowProvisioningUpdates test
```

此命令会覆盖安装测试候选，不卸载 Fox。结果保存在 App 自有 `Documents/FoxTrialDeviceRuns/<UUID>`，业务记录使用隔离目录，不写用户训练仓库。取回整个目录并核对诊断清单；`run.json` 仅在各轮完成后追加，六轮缺任一轮不能通过：

```sh
node scripts/trial-device-metrics.mjs <exported-run-directory> <scene-review.json>
```

场景审阅文件须列 `sameScene`、全部六个 `reviewedRoundIDs`、检查图像的 `evidence` 路径及限定范围 `scope`。先检查原片/截图再填写；没有审阅只输出 `scene_review_pending`。每一对的帧间隔和掉帧变化单独判定，真实语音回调与网络状态分开统计。声音好不好听仍留给真实试用。

分析命令的退出状态只判定并行性能；`offlineSpeechVerified` 保持独立事实。本轮 readiness v2 明确将离线语音列为未评估，不能因并行通过就宣称离线通过。将来另行安排离线专项时才使用 `TEST_RUNNER_FOX_DEVICE_OFFLINE_REQUIRED=1`，不要在当前批次恢复这项操作。
