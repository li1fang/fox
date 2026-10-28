# 首页路由、会话与服务卡片消费者契约草稿

日期：2026-10-28。关联 [第一阶段交付](CLIENT_FOUNDATION_STAGE1_20261028.zh-CN.md)。**设计草稿，尚未实现，也不是服务已接受的正式协议。** 本轮仅为已明确的产品决定提出兼容方案，不决定新用户第一眼优先内容，不开发语音、营养/医疗分析或推荐算法。

后续状态：数据与服务已接受下述约束作为 CLIENT-FOUNDATION-01 第二阶段消费者基线，并授权第一阶段达标后直接实施。下文保留设计时态以区分提案与实现；当前实现和运行证据以 [第二阶段记录](CLIENT_FOUNDATION_STAGE2_20261028.zh-CN.md) 为准，不据此宣称生产服务已接通。

## 已确定的产品行为与所有权

- 首页移除“计划与记录”混合入口；历史查看和手动更正/拒绝建议仍保留。训练不要求用户预先手工编排计划。
- 单张建议直接说明具体动作，例如“试练一组哑铃弯举”。去掉该卡片的固定动作清单不删除能力目录，也不称体能测评。
- 仅打开准备页不显示“继续训练”；保留准备内容。已开始未结束的训练精确恢复；已有未完成训练可以保留并另开一项。
- 多个未完成会话可保留，前台执行上下文唯一；切换先成功保全/暂停原会话。原会话不自动结束。
- 数据与服务决定问题/建议、展示时机、业务顺序、有效期和后续安排；其他来源只能提供事实/候选意图。客户端渲染、收集回答并执行允许动作，不能自行把沉默转为用户事实。
- 当前动作、暂停、结束等训练控制由固定规则约束，不接受普通推荐抢占。问题默认不打断、不强制回答。

## 明确路由：查看与执行分开

以下是语义草案，不是当前可调用 API。每个执行入口都携带稳定目标和命令身份，不读取“最后未完成”来代替目标。

| 路由 | 目标 | 打开时的副作用 / 要求 |
| --- | --- | --- |
| `viewHistory` / `viewSession(sessionID)` | 历史列表 / 指定档案 | 只读投影；不构造有恢复写入副作用的 TrainingStore；找不到显示目标不可用 |
| `preparePractice(activityID, side?, requestID)` | 明确动作，可来自建议或手动选择 | 幂等创建准备内容，不记实际开始；有前台会话时先进入受控切换 |
| `openPreparation(sessionID)` | 已保存且未实际开始的准备 | 恢复该准备；不把它升级为已开始 |
| `resumeSession(sessionID)` | 有实际开始证据、未结束且可恢复的会话 | 选择该 ID，按原状态恢复；用户再开始才计时，不因点击卡片直接计数 |
| `reviewSession(sessionID, attemptID?)` | 待核对组或整场 | 恢复反馈/总结草稿；不自动确认、不重新执行运动 |
| `editSuggestion(cardID, revision)` / `declineSuggestion(...)` | 指定建议版本 | 更正或拒绝建议，不修改原训练事实或结束其他会话 |

阶段二需拆分当前复用的 `home-try-training`。建议语义标识为 `home-resume-{sessionID}`、`home-preparation-{sessionID}`、`home-history`、`home-card-{cardID}-action-{actionID}`；具体格式由消费者测试冻结。稳定 ID 不以位置、标题或翻译文本生成。

## 状态：准备与实际开始不能混同

当前 [Training.swift](../../apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore/Training.swift) 的 `startedAt` 在创建会话时写入；`currentVisualEvidence` 可能只是准备帧；`canReplaceQuickPractice` 是能否替换准备的判断，均不能单独证明实际运动开始。

建议新增显式 `actualStartedAt`（可空）及开始证据来源，保留原 `startedAt` 的历史值/含义。人工开始表示用户启动了训练计时，视觉开始表示现有准备门槛进入 active；两者都不是“已经完成一次动作”的证明。

| 情况 | 首页语义 / 恢复行为 | 事实边界 |
| --- | --- | --- |
| 仅准备，未开始 | “准备中的训练” / 打开准备 | 不显示继续，不以准备时长补造运动用时 |
| active | 显示可恢复目标；切出先保全暂停 | 计时仅到成功的暂停截点；重启离线间隔不累计 |
| paused 且有开始证据 | 继续训练 / 回到暂停状态 | 用户继续后才计时/重新绑定观测 |
| paused 但只有准备中断 | 返回准备 | 不因 paused 标签推断已经运动 |
| rest | 恢复组间状态 | 休息期限与运动计时分别处理，不自动开始下一组 |
| feedback / summary | “待核对” / 恢复原组或整场核对 | 保存失败、未知次数继续未知，不跳到新组 |
| confirmed | 只读回顾 | 点击不得解除确认或隐式建立新训练 |

旧版导入保守分类：先看已保存的 setStartedAt、非跳过 record.startedAt 及已开始观察段等可靠时间证据；单独 active 标签、全跳过记录、创建时间、准备帧、目标节奏都不能补 actualStartedAt。证据不足保留 unknown，提供打开原状态的中性入口而非假称续练。每种旧状态需要合成夹具；不得重算旧次数/离心测量。

## 多会话持久化和前台执行

现状不仅是 validate 的数量限制：`currentSession`、`updateCurrent`、仓库初始化恢复、TrainingStore.startTrial/confirmSummary、计时/视觉/引导、反馈输入都依赖单会话。仅放宽数量会把写入导向错误对象。

建议新档案版本增加 `foregroundSessionID` 与档案修订，显式 `get/update(sessionID, expectedRevision)`；校验前台 ID 必须存在且未确认、所有 session/attempt ID 唯一、非前台会话不可处于运行计时或活跃观察状态。准备、paused、rest、feedback、summary 可作为非前台保留状态。确认 A 并开始建议 B 必须针对 A 的显式身份，不能查最后未完成者。

一次切换命令包含 requestID、fromSessionID、toSessionID 或创建目标、expectedArchiveRevision。建议时序：

1. 串行命令协调器锁住当前前台身份，冻结接受新的运动事件；排完本代已接受的事件，记录单一时间截点。先验证动作/目标仍有效。
2. 构造档案副本：按原状态保全 A（active 转 paused；准备释放观测；feedback/summary 保留；rest 保留独立期限），保存 A 的输入草稿及相关侧别/模式；创建或选择 B，更新 foregroundSessionID 与幂等命令记录。
3. 一次原子写入提交档案变更；失败时不发布 B、不更改前台身份、不结束 A，保留草稿和失败回执。安全暂停/硬件失败状态应准确呈现，不能伪称相机与磁盘共同回滚。
4. 写入成功后撤销 A 的相机/引导执行权，发布 B，建立新的执行 generation；B 相机失败则留在 B 的准备/暂停页，提供既有手工路径，不恢复写入 A。

磁盘事务不能覆盖相机硬件。实现时需对“冻结事件、停止硬件、提交失败”的恢复路径做故障注入：失败后 A 仍为选定上下文，禁止补算切换期间的未知运动；恢复观测需新 generation/必要重绑。不得在失败提示后让后台计时或旧回调继续悄悄增长。

所有回调与动作核对 `sessionID + attemptID + observationID + executionGeneration`；切回 A 也必须新代，防止第一次 A 的迟到回调在 A→B→A 时重新生效。计时器、语音、相机、写入完成响应及反馈按钮都适用；后台响应不能仅按当前 View 位置落地。

`manualSessionID` 现在是全库单值，需改成按 session 保存的用户视觉选择；`nextPractice` 按来源 session 绑定；训练侧别/模式/反馈表单按 session+attempt，summaryNote 按 session 保存。自由留言继续按 Journal 稳定关联，不能用它自动替换次数更正原因。

重启时只恢复已选前台的执行中断为暂停；不启动其他保留会话的相机/计时器。若前台指针无效，不猜最后一场；明确提示选择/损坏状态并保留原档案。合法的无前台状态可以显示多个待继续项。

应用保留单一训练写入者；多个缓存仓库实例不能互相覆盖，写入前须检测档案版本变化。新建 B 使用新 session ID；`replaceQuickPractice` 仅表示编辑同一次准备，不用于新建会话。休息沿用绝对截止时间，离开期间继续流逝，归零不自动开始下一组。

## 旧档案兼容

- 提议明确升级训练档案版本（当前 v1 不应偷偷接受多会话语义）；新代码读 v1/v2，旧代码必须拒绝 v2。保留可追溯的迁移前原件；禁止旧程序覆盖新档案。
- v1 只读展示无需迁移写回。首次明确的写入/迁移命令在独占写入下校验旧档案、生成 v2 候选、原子发布；失败保留 v1。一个旧未完成会话可映射到 foregroundSessionID，但实际开始分类独立判断。
- 旧计划、已确认记录、UUID、时间与来源、视觉测量和手工修订原样保留；新增字段缺失不以 0/当前时间补齐。未知版本、重复 ID、无效前台引用等拒绝写入，不自动清空。
- 不仅测试新代码能读取旧档案，还要验证旧解码器拒绝新档案、新版旧字段往返、迁移失败/重复迁移和旧版应用回退的限制。版本细节与备份策略在数据线正式契约核对后冻结。

## 服务卡片最小输入契约（草稿）

展示模型仅保存服务意图和必要的事实引用，禁止动态脚本、任意路由 URL 或以展示文案作命令。建议内容渲染与真实动作执行各有类型校验。

| 层 | 最小字段 / 含义 |
| --- | --- |
| Feed | schemaVersion、providerID、feedRevision、generatedAt、按服务顺序排列的 cards；revision 在 provider 流内单调；一个快照不得重复 cardID |
| Card | cardID、revision、kind（question / practiceSuggestion / resume / history 等已支持白名单）、title/body、事实引用、visibility、visibleFrom/expiresAt、actions |
| Target | 训练动作必须有 activityID 或精确 sessionID/attemptID；问题有 questionID 和 answerSpec；关联缺失不回退默认动作 |
| Action | actionID、允许类型（answer / skip / decline / edit / prepare / resume / view）、类型化载荷约束；本地状态仍有权拒绝不安全执行 |
| Submission | submissionID、providerID、cardID、cardRevision、questionID/actionID、原始回答或显式跳过、目标身份；未改载荷重试复用同 ID |
| Result | 相同关联身份、accepted / rejected（stale/expired/invalid/conflict/unavailable）/ retryableFailure，及 receiptID；可附新 feedRevision，不把网络超时判定为拒绝 |

数据服务负责判断答案及后续问题。客户端只显示提交中的临时状态，依据服务回执显示已接收；accepted 不是分析结论。静默、显式跳过、到期、拒绝建议是不同事件；没有回答就不生成回答事实。

超时或响应丢失：保留原 submissionID 和载荷，通过幂等重试/状态查询对账。相同 ID 不同载荷必须冲突。重排/删除后返回的回执仍更新原提交记录，不写到占据同一屏幕位置的新卡片。提交先被服务接受、后卡片到期时，应展示已接受结果；到期本身不能抹掉已受理的答案。

输入/阅读中更新：以 cardID+revision 保存焦点与草稿，缓存新 feed 快照，在退出编辑/安全边界或用户选择刷新后应用布局顺序。过期或撤回立即关闭旧版本的新提交能力，但可保留草稿容器供查看/复制；不私自延长有效期、不把旧答案套入新版问题。服务端以自身时钟复核有效期；客户端离线判断只作暂态提示。

业务排序忠实于服务给出的序列，不按 kind 私自重排。当前 Masonry 列缓存只保证输入增长不跨列，不能保证全局视觉先后；阶段二推荐服务业务区使用明确按行/单列排序的布局，并观测服务序列、可见行列与 AX 查询顺序。正在编辑时延迟布局更新要有可观察的 applied/pending feed revision；真实 VoiceOver 顺序另验。本契约不决定首页第一眼内容优先级。

固定训练控制与卡片业务区分离：卡片重排、到期或服务推送不能自动暂停、换会话、开启相机、结束训练或提交原事实。用户明确点击动作后才进入本地命令校验。

## 后续合成联调与开放问题

第二阶段注入最小提供方接口：读取 feed、提交 action、查询 submission；注入时钟，fixture 供应固定有序卡片与确定性回执，可控制乱序、延迟、失败、到期和重复。fixture 显式标为合成，不连接真实同步服务，不写用户原始事实，不声称具备智能决策能力。不要把真实决策规则写进客户端以填补接口空缺。

阶段二开工前由数据与服务核对：信封/回执版本、会话开始证据与迁移保全方式、卡片撤回/编辑中的更新规则。以上是建议方案，当前没有发现必须改变已给产品语义的阻碍；若迁移无法保全或执行中的相机归属不能安全交接，停止相关实现并报告具体证据。普通实现选择由主负责人完成，无需四方审批。

完整验收故事和现有测试对应关系见 [阶段一矩阵](CLIENT_FOUNDATION_STAGE1_20261028.zh-CN.md#已知基线问题与后续验收矩阵)。阶段三必须核对精确提交、环境、输入、覆盖和失败回执；模型切换与静态源码分析均不是运行通过。
