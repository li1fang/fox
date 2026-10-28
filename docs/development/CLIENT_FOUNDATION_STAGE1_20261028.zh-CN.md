# 客户端第一阶段：界面地图与后续契约

日期：2026-10-28。任务标识：CLIENT-FOUNDATION-01（本交付定位，不另建任务台账）。负责人：客户端与体验。阶段：检查与基础优化。本页是本轮交付与设计草稿，不替代 [CURRENT](CURRENT.md)。后续派发已授权在第一阶段实际收口后继续第二阶段；第三阶段仍单独派发。

## 范围、基线和证据

- 起点：`c41da6ed5283c6a3ab1c1b0b8777be715c7c09a2`。独立受管 worktree，分支 `codex/fox-client-foundation`；实际绝对目录见本聊天回执和本地证据。没有复制维护区未提交的 SYNC-3 改动，维护区台账由原写者维护。
- 用户授权本阶段的盘点、必要基础整理、后续路由/会话/卡片契约及局部验证；[任务契约](client-foundation-stage1.task.json)在编辑前建立。早前 CAPTURE-01 仍只作调查，不扩为全部采集实施。
- 当前报告是源码、已有测试定义和本次脚本测试证据。未访问真实图文记录、设备或相册，未真机复现用户报告。默认目录、Git 根与项目归属分别核对；本阶段后续命令显式使用独立 worktree。
- 模型请求：Astra / Ultra / 默认速度。当前运行模型标识为 GPT-6 Astra；Ultra 和速度未取得独立设置回执，不声称已核验。第三阶段 Sol / Fast 只是后续安排，换模型不代替新上下文审查。
- 本阶段业务行为保持不变：混合入口、准备即创建会话、单会话限制和四动作禁用仍是阶段二待修问题。

## 现有界面与副作用地图

主要入口：[FoxHomeView](../../apps/ipad/FoxNative/FoxHomeView.swift)、[HomeTrainingStore](../../apps/ipad/FoxNative/HomeTrainingStore.swift)、[FoxRootView](../../apps/ipad/FoxNative/FoxRootView.swift)。以下顺序是当前源代码拼接顺序，尚无服务排序输入。

| 元素 / 当前标识 | 出现与可操作条件 | 点击目标与数据副作用 | 所有者 / 测试映射 |
| --- | --- | --- | --- |
| 记一下：`journal-note/save/camera` | 始终存在；busy 禁输入；空内容、busy、照片读取中禁保存 | Journal 写入成功才清空；失败留原文/照片，未改变草稿重试复用 ID | 客户端呈现；Journal 持久化；FoxHomeUITests、FoxJournalUITests、JournalApplicationTests |
| 继续训练：`home-try-training` | `snapshot.current != nil`，包含从未实际开始的准备会话；受 Journal busy/照片加载限制 | `.trial(.curl)` → Root；并无指定 session ID。TrainingStore 发现已有 current 时不新建，Root 强制显示它 | 客户端路由/训练存储；现有首页返回续练测试只覆盖单会话 |
| 固定四动作：`home-try-*` | 始终列举；有任意 current 时禁用所有具体动作 | `.trial(activity)`；无 current 时创建并保存准备会话；尚非服务生成的建议 | 能力目录/客户端；FoxActivityEntryUITests 只覆盖无会话直接发现等已有故事 |
| 计划与记录：`home-training` | 始终存在，受训练卡整体 busy 限制 | `.plan` → Root；Root onAppear 有会话时改选 training，因此不是可靠历史入口 | 客户端；多条旧 UI 测试借此进入，不可只删 View 而遗漏测试路径 |
| 本机计划投影：`home-training-projection-plan` | snapshot.plan 存在 | sheet 读取计划快照；不创建或恢复训练 | 客户端只读适配；HomeTrainingTests、投影设计测试 |
| 未结束投影：`home-training-projection-current` | snapshot.current 存在 | sheet 显示快照，和“继续训练”不是同一操作 | 客户端；testReadOnlyTrainingCardCanOpenAndClose |
| 已确认投影：`home-training-projection-{id}` | 当前最多最新两场已确认训练 | sheet 回顾；状态/日期来自真实档案，不复制为 Journal 记录 | 训练存储提供事实；HomeTrainingTests 的日期/状态/字节不变测试 |
| Journal 历史：`journal-record-{id}` | records 中存在 | 详情只读；更正/删除通过明确动作，修订冲突不覆盖 | Journal 与客户端；FoxJournalUITests、JournalApplicationTests |
| 训练读取失败：`home-training-retry` | trainingArchive.error 非空 | 重新读取；损坏档案不重建。loaded 尚未用于锁定入口，初次空快照不是已确认无会话 | HomeTrainingStore；testLoadingDistinguishesPendingEmptyAndUnreadableWithoutWriting |
| notice / 读取失败 / 加载 / 空态 / 较早记录 | 对应 Journal 状态；分页 UI 禁 loading，Store 还拒绝 busy | 关闭提示、重读或翻页；不表示同步或分析成功 | 本轮补 `journal-dismiss-notice/retry-load/load-more`；现有 Journal 测试 |
| Question / 服务建议卡 | 尚不存在 | 没有提供方、回答提交、有效期或排序消费实现 | 下一阶段由数据服务生成，客户端消费；见契约草稿 |

“首页卡片可见”不等于“打开时无写入”：HomeTrainingSnapshot 是只读；创建 TrainingStore 会创建/恢复训练存储，二者不能互换。首页 snapshot 还有异步加载时效问题，未来执行动作必须重新校验目标版本，不能把读到的卡片当写入授权。

## 第一阶段实际基础改动

1. 保留所有原入口文案、条件、路由及旧选择器；给错误重试、提示关闭和分页添加稳定 AX 标识。没有通过重命名 `home-try-training` 假称续练修复。
2. 在路由、Masonry 及 Root 自动跳转旁补意图注释，说明隐含单会话假设和列缓存的边界。
3. 扩充现有 [设计采集](../../apps/ipad/FoxUITests/FoxDesignReviewUITests.swift)：记录 `home-try-training`、全部实际存在的 `home-try-*` 及新增状态动作；保留 enabled/hittable/frame/label；追加 `axQueryIndex`。
4. `elements` 仍按请求目标排列，`axQueryIndex` 仅是匹配目标查询的枚举序号，**不是 VoiceOver 阅读顺序**。保留原 `app.debugDescription` 全文；未知项明确列出实际 VoiceOver 顺序。
5. [design-review 收集器](../../scripts/design-review.mjs)按测试方法与完整场景名关联已有 accessibility 附件，写入 `report.json` 的 `accessibilityTree` 并在原 HTML 报告链接。缺失为 null/显式缺失；重复拒绝。没有新观测服务或新测试入口。

`fox.design_observation.v1` 和 `fox.design_review.v1` 仅增加可选诊断字段。旧结果缺少 AX 序号/文本时保持未知，不能补造或被重解释成新版执行结果。截图和几何仍不能证明业务正确或真人可用性。

## 已知基线问题与后续验收矩阵

下表在正式行为实现之前定义。现有测试是可复用起点，不代表新故事已通过；第二阶段须先建立对应失败回归并登记新增方法，第三阶段验证冻结提交。

| 故事 / 失败案例 | 必须观察的结果 | 现有起点 / 尚缺 |
| --- | --- | --- |
| S1 打开试练准备后退出、重启 | 保留准备内容；不显示“继续训练”；actualStartedAt 未知；不生成运动事实 | 当前会创建 current。testTrainingCanReturnHomeWithoutStartingAWorkout 走混合入口，不能覆盖此故事 |
| S2 A 已开始 → 保全暂停 A → 新建 B → 返回 A → 重启 | A/B 的 session/attempt、次数、时间、侧别、反馈、观察段各自一致；只有一个前台；A 不结束 | 现有首页暂停续练/WorkoutVisionFlowTests 是单会话；缺多会话往返、恢复与逐字段断言 |
| S3 切换保存失败、重复点击、迟到帧/反馈/语音回调 | 失败停在原上下文，不创建 B；重试同命令不重建；旧 generation/ID 不得写新会话 | 既有本地仓库失败与 stale binding 测试需扩到跨会话、切换后再回 A |
| S4 有活动训练时查看历史/更正建议 | 历史不被劫持、查看及渲染不写训练字节；拒绝建议不结束训练 | HomeTrainingTests、只读投影可复用；Root 混合路由待替换 |
| S5 问题回答/跳过/过期/重复/失败及响应丢失 | 原 submission ID 幂等；未答保持未知；失败保留草稿；过期不自动提交；服务已受理但响应迟到能正确对账 | 当前无 Question 实现。需消费者契约＋注入时钟/故障的合成联调 |
| S6 服务重排，多列/大字号/输入与阅读中更新 | 服务序列、视觉行序与 AX 观测可比较；不丢输入、焦点或突然跳位；过期停止新提交但保留草稿 | testColumnAffinitySurvivesComposerGrowth 仅保证原列 x，不证明排序。实际 VoiceOver 另验 |
| S7 旧档案、损坏/未知版、未知指标和人工更正 | 原件保留；未知不填 0；旧版拒绝新格式；人工更正不改视觉原证据；自由留言独立于 correctionReason | TrainingTests、WorkoutVisionFlowTests、Journal 测试；需旧版矩阵与多会话兼容夹具 |
| S8 无视觉凯格尔 | 不启动相机/录像；节奏仍是计划；不能把引导次数当真实次数 | FoxActivityEntryUITests 及能力/事实测试；须经过服务建议入口复验 |
| S9 仅准备中断、全跳过、部分完成及待核对 | 准备/实际开始/需核对分别呈现；未知开始证据不伪造；待核对恢复到原反馈/总结 | 新分类与恢复场景未实现，需 host 与手机/平板场景 |
| S10 卡片无效目标、旧版本、乱序 feed、重复 ID、目标缺失 | 明确 stale/unavailable；不回退到最后会话或默认弯举；坏 feed 不替换可用快照 | 后续消费者反例；当前没有服务卡片 |

已有源码不一致：`testTrainingProjectionScenarios` 的 `projection-missing` 等待“本机暂无训练档案”，但当前首页没有该文案分支。本轮静态发现、未运行复现；没有删除断言救绿。第二阶段需按新的空态契约修正产品或测试并保留本次发现。

## 验证与交接

本阶段局部验证及原始失败输出保存在忽略目录 `.tmp/client-foundation-stage1/`。脚本测试仅合成输入；未运行模拟器、App-host 或全量 public/private。原生实际捕获及新增 AX 标识的运行表现仍待验证，Swift parse 不能替代编译或 UI 执行。

已复核原始输出，未重复无变化的测试：

| 验证 | 结果 / 原始输出 |
| --- | --- |
| 定向回归 | `design-review-regression-red.tap`：12 通过、3 项新增断言失败；补齐附件关联后 `design-review-green.tap`：15/15，无跳过 |
| 原脚本组 | Node 22.23.2，`script-tests.tap`：181/181，无失败、取消或跳过 |
| 仓库契约 | `repository-check.txt`：410 文件、444 已分类测试；任务 JSON 的既有 checkTask 通过 |
| Swift 语法 | Xcode 27.1 / 27A9275，三份改动 Swift 文件 `swiftc -frontend -parse` 退出 0；`swift-parse.txt` 无诊断。这不是类型检查或 App 编译 |
| 差异检查 | `git diff --check` 通过；新上下文审查结果在收口条目记录 |

新上下文审查发现零尺寸目标会被 `observe` 丢弃非几何字段。先增加回归，`review-regression-red.tap` 为 15 通过、1 失败，再保留原始 AX 字段而将几何结论保持 unknown。修复后原脚本组 `script-tests-reviewed.tap` 为 182/182，无跳过/取消；仓库契约复核仍为 410 文件、444 分类测试。这次重跑由新修复触发，前两轮日志继续保留。

独立审查：新上下文 reviewer 复核上述修复、失败输出、182/182 结果及更新后的交付/契约，无剩余阶段一阻塞。审查没有运行测试，不把静态复核算作另一轮执行。

失败：`design-review-before.tap` 首轮夹具还没有注入执行器，真实只读 xcresulttool 因合成路径不存在失败；分类 `test_fixture`，先补执行器接缝。第二轮三项失败明确落在缺失的附件关联/null/重复拒绝行为，保留红到绿证据；未运行原生构建或模拟器。

未覆盖：新增 AX 标识在真实 UI 的可达性、实际 accessibility 树捕获、VoiceOver、原生类型检查与 App-host/UI 执行、完整 public/private 和设备体验。本阶段只承诺诊断基础及后续契约，不以脚本通过关闭这些事项。

交接由数据与服务读取本聊天和 [消费者契约草稿](CLIENT_HOME_SESSION_CONTRACT_DRAFT_20261028.zh-CN.md)，协调者在既有台账记录负责人/基线/范围/回执/风险。本任务不写共享台账，不向其他聊天发消息。最新派发接受契约草稿，并授权第一阶段验证和新上下文审查达标后直接进入第二阶段；第二阶段冻结后停止，等待第三阶段派发。精确本地提交以聊天回执和 Git 对象为准，避免在同一提交内写自引用哈希。
