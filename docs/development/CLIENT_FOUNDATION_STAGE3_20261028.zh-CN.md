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

这些结果先于新候选冻结，不冒称完整 public。当前内盘余量仍不足稳定运行全量；已请求释放至至少 10 GiB。后续完整运行的大体积输出和临时目录放在外盘，继续监测内盘并在不足 2 GiB 时受控取消；不通过清除既有模拟器、私人原件或他人缓存来取得空间。

## 发布与设备证据

推送前核查每个新增提交和公开权限，推送后核对远端完整 SHA；不自动合并。设备包版本／构建号在安装前重新确定，不复用已安装的 0.6.13/build 32 身份。使用现有有效签名，不自动续期。

设备更新依次核对当前版本及锁定／连接状态、完整备份与清单、SQLite 完整性和全部记录关系／照片摘要、签名与设备覆盖、覆盖安装、稳定启动和安装后比较。同步凭据保存在 Keychain，保留原应用身份及访问组，不通过删除配对或用户库来处理问题；若有后台／前台同步导致合法新增，按操作／记录身份解释并保留前后原件，不以单一数据库文件摘要代替内容核验。

软件、签名、安装、启动、资料保全和真实体验分别报告。当前记录不关闭历史输入动画等待、实际 VoiceOver、听感、真实相机准确性或首次独立使用欠项。
