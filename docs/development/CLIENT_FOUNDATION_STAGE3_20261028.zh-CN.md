# 客户端基础第三阶段：冻结验收、推送与兼容交付

日期：2026-10-28。负责人：客户端与体验。用户已在本聊天授权使用 Sol 继续第三阶段软件验收、保留失败记录并推送；设备更新需要解锁时通知。当前是集成与候选准备记录，完整验收／推送／设备结果分别以本聊天后续精确回执为准。

## 范围与不变量

承接第二阶段 `a2e099d0d6f92e2ee199ffe87aaa698b959f7ec8`，按[任务契约](client-foundation-stage3.task.json)完成公开软件验收和开发分支推送。设备更新必须兼容现有同步版本；保留原记录、Journal v2、Keychain 身份、配对、游标及 outbox，不降级数据库、不重新配对绕过错误。设备原件和详细回执仅在私有忽略目录保存。原生重型任务串行，使用现有租约。

## 首批结果与替代原因

原始证据位于忽略目录 `.tmp/client-foundation-stage3/`，不加入 Git 或公开附件。

- `public-a2e099d-1/suite.json`：原候选完整 public 首批为 **cancelled**。Web 44、脚本 182、浏览器闭环、Core 173、Journal 29、Python 映射 59、wire、双 App 构建和 App-host 129 已通过；平板 UI 未完成、手机 UI 未开始，不能拼成完整通过。
- 该批首个有效 UI 失败是 `testOptionalObservationCorrectionIsSecondaryAndKeepsExplicitSide`：更改观察侧后，设置页不再存在，无法点击完成。根因为整页 identity 包含 attempt，组身份变化丢弃设置页 State，分类 `product`。修复提交 `e8c3a9f` 让呈现跟随 execution generation，完整 session／attempt／generation 写入校验保留；attempt 变化时重启引导并绑定新 token，反馈子页仍按 attempt 隔离。
- 同批还出现内盘空间耗尽，甚至 shell 无法创建 here-document 临时文件；随后只向本任务租约所有者发送 SIGTERM。suite 记录取消，资源生命周期为 released。容量问题与此前 UI 失败分别记录，不把两者混成同一根因。
- 只迁移本工作树的可重建编译缓存到外盘，并保留原路径链接；没有移动／删除备份、原始记录、日志、回执或其他工作线缓存。后续原生运行使用容量监测，低于 2 GiB 只取消已核对身份的自有批次，保留原因。
- `settings-repair-1.log` / `.json` / `.xcresult`：原 UI 断言不变，修复后 UI 1 项、ClientSession 6 项和 GuidanceOutput 7 项共 **14/14** 通过。该直接入口忽略了额外 result-bundle 参数；已在下一次构建前从实际唯一 Xcode 路径完整保留结果包。这是脏树定向证据，不是新冻结提交的完整通过。

## 已安装同步基线的集成门槛

监督工作线通知后，已只读核对维护树源码和[同步内部交付记录](../planning/PERSONAL_SYNC_NATIVE_V1.zh-CN.md#内部体验交付结果)：两台已安装 0.6.13/build 32，构建提交 `182b59a` 的产品实现与 `17d4a8e` 相同；Journal 已为 v2 且已配对。旧客户端候选缺少 FoxSyncCore，并在 LocalJournalRepository 中只接受数据库 user_version 0/1。因此旧客户端候选不能直接覆盖设备；这与本任务 Training 档案 v2 是两种独立格式。

本阶段在隔离树集成同步基线 `0fa4176`，包含 `e778186`、`17d4a8e` 和后续交付文档，不修改服务器或现有协议。唯一源码合并冲突在 FoxHomeView：同时保留同步的初次／前台刷新和入口，以及客户端服务建议提交后才呈现的 dispatcher 路径。同步 UI 测试的旧混合训练 selector 改为明确准备／历史入口，保留 Journal 输入存在的原断言；该静态迁移不冒称已观察到运行失败。

集成后须重新验证 Journal v2 及历史／照片／outbox 恢复、凭据恢复、Keychain 宿主测试、同步与训练入口共存、客户端代际隔离及关键 UI，完成新上下文审查，再冻结新候选运行完整 public。旧候选回执不作为集成候选通过证据。未满足以上条件时，本地交付脚本有显式安装阻止标记。

### 集成定向结果

- `journal-integrated.log`：40/40，包括 v1 到 v2 迁移、配对 outbox、恢复和照片历史；iOS SDK 编译通过。
- `sync-integrated.log`：13/13，包括凭据恢复、双副本／失去回执、冲突、超限隔离和 TLS 反例；iOS SDK 编译通过。
- `integration-focused-1/suite.json`：App-host 29 项及 iPad UI 4 条故事共 33/33，无跳过，运行源码指纹一致。UI 包括设置页原失败、同步入口关闭后训练／Journal 仍可达、双会话跨重启及反馈草稿跨进程恢复。`integration-focused-1-cleanup.json` 确认释放自有租约。
- 新上下文只读审查未发现新的 P1/P2；同步源、Journal、Keychain、outbox 及验证接入相对 `0fa4176` 无意外改动。`e8c3a9f` 逐提交披露检查通过。集成提交仍须在推送前核对完整提交身份及披露边界。

这些结果先于新候选冻结，不冒称完整 public。此前曾请求内盘释放至至少 10 GiB；用户随后授权自行释放熟悉的缓存，以 5 GiB 以上为准。已将已知闲置的 Core／Journal／Sync 和旧模拟器编译缓存整树保存在外盘，保留原路径链接与历史结果包，内盘达到 5.1 GiB 后继续。物理设备签名包、备份、原始资料和源码未删除。后续大体积输出和临时目录放在外盘，内盘不足 2 GiB 时受控取消。

## 冻结候选 5976559 的结果与后续入口修复

`5976559ea1cd85d6d81f382e0a4870fc073c839d` 已经新上下文审查、52 个新增提交／392 个 blob 的机械历史检查后推送到 `origin/codex/fox-client-foundation`，远端 SHA 一致；没有远端合并。该 SHA 的 GitHub Actions 查询当时无运行记录，不记 CI 通过。

第二轮完整 public 记录在私有 `public-5976559-1/suite.json`：Web 44、脚本 182、浏览器、Core 173、Journal 40、SyncCore 13、Python 69、wire、双 App 构建和 App-host 132 通过。iPad 前 24 项通过后，`testHomeSavesToRealLocalRepositoryAndSurvivesRelaunch` 在输入事件后的 idle 等待 10.03→70.06 秒出现动画完成通知超时，执行器按既有规则停止，整体为 **failed**，手机批次未开始。容量保护未触发，最低内盘余量约 2.21 GiB，租约正常释放。失败步骤未生成原有日志摘要，已在失败后另存原日志 SHA／字节数，未补造原 suite 的完整性字段。

只读比对旧同步候选，确认是既有 idle 超时类型、不同停点，根因仍 unknown；负尺寸警告也出现在通过用例，不能据此归因。一次新冷实例的原用例通过，保留原输入、保存、重启和内容断言；这只支持运行条件敏感，不能关闭原完整失败。后续剩余 iPad 批次通过两项首页后，在 Journal 草稿输入再次超时。输入相关受阻组保留，不连续重跑。

独立 Native 组另有可证实的入口缺口：`FOX_START_SCREEN=training` 请求明确训练页，但 FoxApp 未传 initialTab，重启时落在计划页，原“已暂停”断言失败；随后的离线输入还发生 idle 超时，两者分别分类。调用方现对该明确环境值传入 `training`；已有 foreground ID 决定会话，无会话时仍回到计划，普通 Home／plan／vision 不变。原暂停恢复断言保留。重启后历史选择器从旧 `record-confirmed` 路线迁到唯一 UUID 的只读行；即时保存回执、次数、未知次数、视觉观测、中文备注和无 WebView 断言均保留，并增加只读／无执行按钮检查。

该次独立训练故事 6/6 通过。确认入口／历史缺口后，协调器受控取消余下旧候选批次：Unified 记录取消，Vision／Workout 尚未开始；原日志均保留。修复后的 `routing-repair-1/suite.json` 为 **138/138，无跳过**，包括完整 App-host 132、原 Native 暂停恢复、计划编辑、组后失败保全后的只读回看、双会话与反馈恢复、同步入口共 6 项 UI；日志摘要复核和租约清理通过。这些仍是冻结前定向证据，不转写成完整 public，通过身份与后续候选分别记录。

当前已知输入 idle 仍开放；后续按独立类／手机补覆盖并保留缺测清单，不将跨批次或跨提交拼为完整通过。新候选须再次核对审查、提交和推送；设备安装阻止标记保持，包与备份准备不表示已经安装。

## 发布与设备证据

推送前核查每个新增提交和公开权限，推送后核对远端完整 SHA；不自动合并。设备包版本／构建号在安装前重新确定，不复用已安装的 0.6.13/build 32 身份。使用现有有效签名，不自动续期。

设备更新依次核对当前版本及锁定／连接状态、完整备份与清单、SQLite 完整性和全部记录关系／照片摘要、签名与设备覆盖、覆盖安装、稳定启动和安装后比较。同步凭据保存在 Keychain，保留原应用身份及访问组，不通过删除配对或用户库来处理问题；若有后台／前台同步导致合法新增，按操作／记录身份解释并保留前后原件，不以单一数据库文件摘要代替内容核验。

软件、签名、安装、启动、资料保全和真实体验分别报告。当前记录不关闭历史输入动画等待、实际 VoiceOver、听感、真实相机准确性或首次独立使用欠项。
