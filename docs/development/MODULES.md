# 模块地图

不为模块化重写业务。通过目录、依赖约束、输入输出契约和测试把现有责任说清楚。

| 模块 | 所有者目录 | 输入与输出 | 禁止越界 |
| --- | --- | --- | --- |
| 运动事实 | `FoxTrainingCore` | 关键点/时间 -> 准备、计数、恢复、阶段和报告 | 不导入 UI、相机、音频或网络；不从播报反推动作 |
| 引导策略 | `FoxTrainingCore/Guidance` | 已提交事实/目标节奏 -> 有效期受限的提示 | 不控制计数、数据库或相机；不补缺失测量 |
| 平台适配 | `FoxNative` | Apple Vision/相机/屏幕/音频 -> 核心输入；核心状态 -> UI/语音 | 不用 UI 操作重写运动事实；平台能力不能冒充核心准确性 |
| 记录与附件 | `FoxJournalCore` | 本地记录、照片、完整备份 -> SQLite/私有文件 | 不依赖训练或远端服务；不静默迁移现有训练 JSON |
| Web 与语音实验 | `apps/api`, `apps/web-runtime`, `packages` | API、人工确认草稿、持久化 | 不依赖真实 Linux 才能测试；不自动更改 workout state |
| Fox Say 原生壳 | `apps/ipad/FoxPad` | 独立 App 的 Web 入口、原生麦克风桥、录音上传 | 不代替 FoxNative；录音/上传/识别/入库是不同的成功条件 |
| 实验与开发证据 | `scripts`, `experiments`, 测试专用 `FoxTestSupport` | 固定输入 -> 可追溯报告/索引 | 不进产品依赖；SQLite 索引可重建，不能替代原始证据 |

完整仓库路径前缀：Swift 模块均在 `apps/ipad/`，引导策略在 `apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore/Guidance/`。

## 文件放置

- `schemas/`：持久化与交换契约。策略参数跟随 Core 的 `Resources/`。
- `tests/verification/catalogue.json`：测试分类，新增/移动/删除测试必须显式审核。
- `docs/development/`：当前开发入口。`docs/fitness/`、`docs/design/` 保留设计与有日期的结果，不再不断往 README 累积状态。
- `.data/`：私人输入、设备记录、实验档案和可重建索引；禁止提交。
- `.tmp/`：构建和运行回执。失败也保留，清理前确认不是唯一证据。不同运行目录不覆盖。
- `.venv/`、`node_modules/`：可重建依赖，不复制到恢复提交。

跨模块改动需写明契约影响，并增加消费者测试。无需建立跨平台抽象层；当前仍采用 Apple Vision，未来平台扩展先复用数据与验证契约。
