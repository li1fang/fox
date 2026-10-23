# Home 第一份手机候选

日期：2026-10-17。对应 [N1/N2](HOME_NATIVE_IMPLEMENTATION_V1.zh-CN.md)，不是整个 Home 发布验收。

后续版本：N3 的 0.5.1/build 12 照片、更正/删除和本地备份见 [本地记录闭环实施记录](HOME_LOCAL_CAPTURE_N3.zh-CN.md)。本文的 0.5.0/build 11 能力清单与测试数量按首次手机候选保留，不代替新版状态。

最新续跑状态：用户已开启开发者模式、信任开发者账户并解锁；Fox 0.5.0/build 11 的真机签名构建、安装和启动已通过。系统成功激活 App，后续进程查询确认仍在运行；用户已确认原生首页“记一下”和“训练”两张卡片显示正常。手机真实保存与照片等仍未验收，不等于整个 Home 已完成。iPad 安装不变。下方首次检查记录按历史保留，最新证据见文末“信任与解锁后启动”。

## 范围

- Fox 0.5.0/build 11，Bundle ID 不变，支持 iPhone 和 iPad。Fox Say 不变。
- 默认进入 SwiftUI 原生卡片 Home：iPhone 始终一列；iPad 窄窗口一列、700pt 起两列、1100pt 起三列，无 WKWebView、Mac/LAN/API 前置依赖；无示例个人记录。
- 记录卡先支持纯文字、保存到 `FoxJournalCore`、本机列表、详情、重启读回。显示登记时间，不推断起床/进食时间、费用或营养。
- 失败保留当前输入，未修改的重试沿用同一份 CaptureDraft，写入返回后才清空。避免重复点击与加载/保存并发。
- 训练入口打开原训练模块，不复制状态机；返回首页先成功暂停/保存，再停止相机和关闭。视觉和 Day 1 的显式启动参数保留。
- 测试使用独立 `Fox/UITestJournal`；正式记录为 `Fox/Journal/journal.sqlite`。不迁移或重写 `training-records.v1.json`。

这一步不含照片/相机、记录更正/删除、备份 UI、草稿跨 App 终止恢复、完整搜索/无限分页、训练卡历史投影、AI/分析或同步。当前列表逐页扩展至最多 1000 条，不能据此宣称完整档案浏览。照片和更正属于 N3，不放暂时不可用的拍照按钮。手机上的旧训练内容尚需针对尺寸继续回归；原训练体验不能因入口已接通就标为手机验收。

## 设备门槛（首次检查）

本轮实际识别到 iPhone 13 Pro Max，iOS 27.0.1；Mac 为 Xcode 26.3。CoreDevice 初次报告 unpaired，经明确配对后变为 paired，但 Developer Mode 仍为 disabled。已经向用户请求开启、重启并确认开发者模式。信任电脑不等于开发者模式，Mac 上有有效签名身份也不等于手机 profile/安装/启动成功。

先按实际错误处理开发者模式，之后再验证 Developer Disk Image、设备 OS 与 Xcode 的支持情况，不仅凭版本差推断已兼容或必须升级 Xcode。没有自动更改手机安全设置。

## 定向命令

```sh
npm run iphone:doctor
npm run iphone:build
npm run iphone:install
npm run iphone:open
```

新命令只能选择已配对 iPhone，始终只处理 Fox；多台手机时要求 `FOX_IOS_DEVICE` 精确 ID 或唯一名称，绝不回落到 iPad。独立产物目录为 `.tmp/home-iphone-derived-data`，可用 `FOX_IOS_DERIVED_DATA` 覆盖。build 使用选定手机的 Xcode destination，并允许为该设备生成/更新开发描述文件；安装/启动仍为独立步骤。

既有 `ipad:*` 默认仍选唯一 paired iPad，显式选择其他设备的旧方式保留。`doctor` 读取详情验证 Developer Mode；即使 devicectl 在权限不足时返回退出码 0，也不报告检查通过。doctor 通过不等于签名、安装、启动、相机授权或真实使用验收。

## 检查与证据

- 设备选择脚本测试：4/4 通过；整个 Node 脚本测试：16/16 通过。
- iPhone 17 Pro 模拟器最终 Home 测试 4/4 通过，覆盖实际 SQLite 保存/重启、写失败保留与重试不重复、训练入口返回首页，以及训练中返回/暂停/重新打开；另留横竖屏截图并检查输入边界。这不是 iPhone 13 Pro Max 真机运行。
- iPad Pro 11-inch 模拟器首轮完整套件 26/26 通过（原 23 项 + 最初 3 项 Home）。随后增加的第 4 项 Home 用例已在 iPhone 补验；最终 27 项完整包没有再次全跑，不将两次结果拼成一次 27/27。尚不代表 N4/N5 整体验收完成。
- 训练核心 109/109、记录核心 29/29、Schema 7 个负例及记录核心 iOS SDK 编译检查通过；这不是手机执行或真实视觉验收。
- 原训练测试显式从 `FOX_START_SCREEN=training` 启动，视觉测试仍显式进入 vision。新增 Home 测试使用真正默认入口；不把旧测试绕过首页的结果称为首页覆盖。
- 尚未安装手机候选、尚未触发 App 开发者信任提示、尚未更新 iPad。模拟器结果与真实手机验收分开记录。

定向真机构建曾在选择 destination 时等待并报告 Developer Mode disabled，未形成可安装真机产物。脚本现增加前置检查，未开启时立即给出明确错误，避免 Xcode 长时间等待。开发者模式开启后仍需重新执行签名构建、检查手机现有 Fox，再安装/启动；不能用模拟器产物安装真机。

本次设备详情、构建和 UI 日志在 `.tmp/home-*`，不提交设备标识或个人资料。最后安装前还需检查手机现有 Fox，若已有数据则先保留，不卸载重装。

测试结果包：`.tmp/home-iphone-ui/Logs/Test/Test-Fox-2569.10.17_02-27-51-+0700.xcresult`（iPad 26 项），以及 `Test-Fox-2569.10.17_02-39-05-+0700.xcresult`（iPhone Home 4 项，同目录）。原生截图已从结果包导出到 `.tmp/home-ipad-attachments` / `.tmp/home-iphone-attachments` 并检查；iPad 竖屏两列、手机横竖屏一列，没有把网页预览当作原生截图。三列与大字体、照片等仍需后续 N3/N5 验证。

Xcode 另报模拟器诊断收集子进程找不到 simctl 的警告，但测试进程退出码为 0，xcresult 明确记录通过；本轮没有为该诊断收集问题修改全局 xcode-select。

收尾重新执行 `iphone:doctor`，仍为 paired / Developer Mode disabled / DDI 未就绪；脚本明确非零退出。尚未生成真机签名产物或安装 App，需用户完成开发者模式重启确认后继续。

## 真机安装续跑

2026-10-17，用户开启 Developer Mode 后重新执行：

- `iphone:doctor` 退出 0，详情确认为 enabled；首次开发应用查询成功启用 DDI 服务。Xcode 26.3 没有因这台 iOS 27.0.1 手机而在当前安装链路失败，本轮未升级 Xcode 或修改全局 xcode-select。
- 安装前默认开发应用列表及指定 Bundle ID 查询均未发现旧 Fox，未卸载其他应用、未迁移数据。
- `iphone:build` 成功生成 arm64 真机产物，版本 0.5.0/build 11，UIDeviceFamily 为 1/2，Bundle ID 为 `com.whipa.fox`。
- `codesign --verify --deep --strict` 通过；签名 Team、application-identifier 与描述文件一致，profile 包含目标手机，当前到期时间为 2026-10-24 03:19（Asia/Bangkok）。未将个人设备标识或描述文件写入仓库。
- `iphone:install` 退出 0，安装后设备列表确认正确版本。仅安装 Fox 到 iPhone；未执行任何 iPad 安装命令，也未安装 Fox Say。
- `iphone:open` 首次退出 1：系统返回 Security / RequestDenied，错误枚举签名、entitlement 或 profile 未信任等可能性。这不是已证明 App 崩溃，也不能单凭该通用错误断言必须重新签名。已额外对照 App 与 profile 的关键 entitlement，没有发现不匹配。
- 已请求用户在手机“设置 -> 通用 -> VPN 与设备管理”查看实际开发者 App 状态，未信任时联网信任/验证；已验证或没有条目时反馈现象，不反复卸载或盲目改安全开关。

新日志：`.tmp/home-iphone-enabled-doctor.log`、`.tmp/home-iphone-device-build.log`、`.tmp/home-iphone-install.log`、`.tmp/home-iphone-launch.log`；安装后版本证据为 `.tmp/home-iphone-fox-installed.json`。目前证据仅到“已构建/已安装”，启动、首屏、手机真实保存和照片授权均未通过，N2 启动与 N3/N5 仍未完成。

## 信任与解锁后启动

同日用户确认原先未信任、现在已完成开发者账户信任。重试首先返回 Locked，而不是此前的 Security；经用户解锁后，直接以 `devicectl device process launch` 启动，不传 `--terminate-existing`、测试 fixture 或环境变量，不重新安装。

- 启动命令退出 0，JSON outcome=success，`activatedWhenStarted=true`、`terminateExistingInstances=false`，返回 Fox 进程 839。
- 后续设备进程查询匹配相同 Fox 可执行文件与 PID，确认不是只收到安装成功消息。
- 用户确认能看到“记一下”和“训练”两张卡片且显示正常；这是 iPhone 13 Pro Max 的人工首屏确认，不是用模拟器截图替代。
- 只读列出正式 App 数据目录，确认 `Fox/Journal/journal.sqlite`、WAL/SHM 及附件目录已初始化；该次清单未见 UITestJournal。仅检查文件元数据，没有复制正在写入的数据库或读取用户记录；目录存在不等于真实保存验收通过。
- 不写入测试生活记录，不开始训练，不调用相机，不操作 iPad 或 Fox Say。

启动证据：`.tmp/home-iphone-foreground-launch.json` / `.log`；进程证据：`.tmp/home-iphone-running-processes.json`；目录元数据：`.tmp/home-iphone-journal-files.json`。此前被锁定的结果保存在 `.tmp/home-iphone-trusted-launch.json` / `.log`，不覆盖失败历史。

N1 的手机准备、N2 的 build/install/launch smoke 及 N5 中的手机首屏检查已通过；N3 照片、更正、备份及 N5 真实输入保存、iPad 升级验收仍待后续。不需要继续调整开发者模式或增加其他调试开关。
