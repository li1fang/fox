# 系统架构

## 当前架构与下一批边界（2026-10-23）

主应用为原生 iPhone/iPad 客户端。`FoxTrainingCore`、原生视觉协调器、`FoxJournalCore` 和开发侧运行档案/SQLite 索引分别承担训练事实、相机接入、本地生活记录和评测归档；不是重新依赖 Mac 网页或 Linux 在线服务。三动作策略/档案状态见[当前入口](fitness/README.md)。

下一批按[集成路线图的模块边界](planning/NEXT_TRAINING_TRIAL_ROADMAP_V1.zh-CN.md#3-模块化在试用前落实)渐进整理：感知接入、动作分析、训练会话、引导策略、呈现/声音、记录/评测。先在现有 target 内用目录、窄类型和依赖测试隔离职责，提取现有节奏计算/显示；不拆成多个服务、不迁移原训练/生活数据库、不重命名全部历史类型。

语音/叠加/有限问答是本次设计中的新增能力，尚未实现；引导只读事实和用户已确认目标，不能因播完一句话自动计次或推进训练。Fox Say 和远端服务保持独立。下面是早期架构快照，含“尚未实现”的语句仅适用于各自日期，不覆盖最新台账。

## 历史：记录与存储层（2026-10-16）

当前新增独立本地库；Home 已进入 [卡片瀑布流文字设计](design/HOME_CARD_FEED_V0.zh-CN.md)，尚未实现界面：

```text
未来记录调用方（本轮不实现 UI）
  -> FoxJournalCore（文字、照片、时间、来源、修订、查询、删除）
  -> 应用私有目录：journal.sqlite + attachments/ + staging/
  -> 本地完整备份目录（manifest + 原照片，不是设备同步）
```

库兼容 iOS 16 / macOS 13，使用系统 SQLite 和 CryptoKit，不依赖网络、AI、训练核心或 Linux。独立测试和 iOS SDK 编译已通过；尚未加入 App target，不代表已在 iPhone/iPad 提供记录界面。来源字段仅描述数据来历，不建立设备信任或外部服务接入。

已有训练 JSON、视觉报告和 Mac SQLite 保持原样，未迁移或统一写入新库。前端实现、结构化事实/分析、HealthKit、双设备与云端互联分别后置。详细事务、备份与验收契约见 [通用记录与本地存储 v1](journal/RECORD_STORAGE_V1.zh-CN.md)；互联三级与分析的后续边界见 [任务台账](planning/LIFE_LOG_BACKLOG.zh-CN.md)。

## 既有训练架构（2026-10-06）

当前主应用按 [D0–D3 路线](fitness/IPAD_LOCAL_MVP_D0_D3.zh-CN.md) 开发：

```text
Fox 原生 SwiftUI
  -> FoxTrainingCore（Foundation：计划、状态、计时、记录）
  -> iPad Application Support / training-records.v1.json（原子保存）
  -> 系统文件导入 / 分享导出
```

- `com.whipa.fox` 不实例化 WKWebView，不读取服务器 URL，核心流程不发网络请求。
- `com.whipa.foxsay` 仍是独立语音实验应用，保持现有 Mac/Linux 路径。
- 原生记录与 Mac SQLite 分开保存。历史不会被重置；同步和 Entry 去重映射后续单独设计。
- D1 保留独立视觉诊断页；Fox 0.4.0 的 Part 1 候选已把观测接入当前组，实际次数仍由人确认。软件自动化通过，M4 真人相机验收待完成，详见 [执行记录](fitness/REAL_EXERCISE_DAY_1_PART_1_EXECUTION.zh-CN.md)。
- `FoxTrainingCore` 与旧 TypeScript core 当前是独立实现，以单元测试和状态契约约束行为；未宣称全部旧功能已原生迁移。

### D1 本地视觉链路

```text
AVFoundation 视频帧（仅内存）
  -> Apple Vision 二维人体关键点（串行后台队列，上限 12 Hz）
  -> PoseGeometry / CurlTracker（单人、指定手臂、连续性与阈值状态机）
  -> SwiftUI 骨架、次数、阶段时长、人工修正
  -> VisionTrialRepository / vision-trials.v1.json
  -> 用户导出验证报告
```

独立视觉试验报告与正式组记录分开。训练页由 `WorkoutVisionCoordinator` 将经过验证的观察事件绑定到当前 session / set / attempt；用户先启动就位，确定性程序负责倒计时、暂停、保存与推进。视觉不自动改变重量或最终确认次数。

正式组记录内嵌有界的逐次事件、参数快照、观察段和机位标量；人工更正不会覆盖自动原值。诊断报告可保留所选臂的有界数值轨迹，v4 侧平举额外保留使用到的同主体对侧肩/髋，供私有回放；正式组记录不存逐帧骨架。默认不录制或持久化相机图像、音频、人脸或路人全骨架。

Fox 0.3.2 为报告增加可选 `captureContext`：Core Motion 重力导出屏幕倾角和所用镜头俯仰；人体朝向由用户标注；Vision 只提供人体画面尺度，不输出米制距离。计数期间约每秒保留一条标量样本，上限 1800 条，暂停与准备阶段不采样。传感器不可用不阻止计数，缺失值不写成零。摄像头型号、变焦与格式报告视场角一并记录，供比较拍摄条件；格式视场角不是校准后的有效视场角。全部本机运行，不使用罗盘、定位或深度。

Fox 0.3.3 的历史阶段新增用户选定的 `exercise`：弯举使用肘角，正面侧平举使用所选上臂相对同侧躯干的二维夹角，当时尚未接入正式训练。0.4.0 候选保留动作专属循环门控与人工机位标签，侧平举 v4 可使用受约束的同主体新鲜对侧躯干参照；不自动识别动作或朝向，不合计双臂，不用旧坐标补造次数。旧报告仍按原算法快照解释，不改写原始记录。

`vision-live-status.v1.json` 仅记录最近一次运行时间、所选动作、人数、可见点数、耗时、倾角和画面尺度等诊断标量，不能替代保存报告或准确率验收。完整规格见 [D1 本地关键点与双动作验证](fitness/D1_LOCAL_POSE_SPEC.zh-CN.md)。

以下五层架构是此前 Web/API 原型的设计记录，保留为可选后台与 Fox Say 的参考。

## 总体结构

fox 的目标架构分为五层：

1. iPad Pro 客户端
2. 后台 API
3. 后台数据库
4. Linux 4090 算力中心
5. AI 与 ASR/TTS 服务

第一版只需要数据库和 TUI 原型，iPad、ASR/TTS 和姿态识别后置。

## iPad Pro 客户端

iPad 是长期主要交互设备。

未来职责：

- 显示今日训练计划。
- 显示当前动作和倒计时。
- 提供大按钮反馈：完成、没跟上、太轻松、疼痛、跳过。
- 展示训练总结和历史。
- 后续接入麦克风和 TTS。

第一版不实现 iPad App，只确保文档和数据模型支持它。

## 后台 API

后台 API 是客户端、TUI 和算力中心之间的边界。

未来职责：

- 创建和读取 Entry。
- 创建 WorkoutSession。
- 推进训练状态机。
- 接收 FeedbackEvent。
- 保存 TimerEvent 和 CoachMessage。
- 调用 AI 服务生成计划、调整建议和总结。

第一版 TUI 可以直接访问本地服务或本地数据库，但接口概念应保持清晰。

## 后台数据库

数据库保存所有长期状态。

第一阶段重点对象：

- Entry
- WorkoutSession
- WorkoutPlan
- ExerciseBlock
- SetRecord
- FeedbackEvent
- TimerEvent
- CoachMessage

饮食、医疗、记账先保留轻量 Entry 和 payload。

## Linux 4090 算力中心

家中的 Linux 服务器带 4090。

当前定位：

- 作为未来算力中心预留。
- 可承接 ASR/TTS、视频处理或视觉模型。
- 第一版不运行本地大模型。

第一版不要求训练流程依赖 4090，否则会增加部署复杂度。

## AI 服务

AI 的职责是语言和策略建议，不是状态控制。

允许 AI 做：

- 根据用户档案和旧训练记录生成今日计划草稿。
- 根据反馈生成调整建议。
- 生成鼓励话术。
- 生成训练总结草稿。

不允许 AI 做：

- 直接启动或停止计时器。
- 绕过状态机改写训练状态。
- 在疼痛反馈后强行继续训练。
- 生成医疗诊断或用药决策。

## ASR/TTS

ASR/TTS 后置，并且重新设计。

未来职责：

- ASR 把用户语音变成反馈事件。
- TTS 把 CoachMessage 播放出来。

ASR/TTS 是输入输出层，不应污染状态机、数据库或训练策略。
