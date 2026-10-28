# Linux 共享资料库 V1

日期：2026-10-28。负责人：产品与交付；存储实现归数据与服务。用户授权使用现有 Linux、已有本地资料复制入库，全部保留、仅人工清理。无第二份独立备份；本轮不删除设备或 Mac 原件。

## 目标与验收

[任务契约](../development/shared-archive.task.json)。本地定向入口 `npm run test:archive`，仓库检查 `npm run verify:repository`；Linux 使用同一 Python 测试文件。无原生构建或全量 UI 回归。

三条工作线通过统一查询、取回入口获得原始资料及证据关联。不改 App、算法、设备、同步、CI；不执行 AI、不提供自动删除或录制。原件字节不变，分析不覆盖原文；同 ID 相同内容幂等、不同内容拒绝；半份传输不可查询；不同事件可引用相同字节。没有授权不启动其他聊天任务。

允许修改：开发档案脚本、合成测试及登记与命令、本契约、CURRENT、原台账、模块地图。私人配置、数据、回执不进 Git。现有产品库和 schema 不修改。目标目录冲突、空间不足、来源不明、SSH 身份失败或并发源码修改时停止对应操作。

| 里程碑 | 验收 | 状态 |
| --- | --- | --- |
| STORE-0 契约与测试 | 往返、重复、冲突、截断、额外字节、篡改、路径、异常退出、派生引用 | 本地通过 |
| STORE-1 Linux 闭环 | 同一测试 Linux 通过；真实视频及图文复制、查询、取回核对 | 已通过，10 条目，非全量归档 |
| STORE-2 工作线入口 | 三条线按角色查询和获取，不必寻找设备目录 | 同账号三类访问通过；未向其他聊天派工，不冒充实际使用反馈 |
| STORE-3 批量归档 | 盘点并逐批核对全量，未接收来源明确列出 | 后置 |
| STORE-4 设备保留上传 | 开发默认录像、发行默认不保留；容量/离线队列/可见状态 | 后置 |
| STORE-5 本地清理 | 未来新资料仅留服务器，或上传核验 N 天后清理源端 | 后置，N 未定 |

## 存储契约

私有根目录下：originals/（按 SHA-256 存储的不可变对象，含原件及派生文件）、metadata/catalog.sqlite、staging/、cache/、tool/。分类由 kind 表达，不靠扩展名猜测。

SQLite user_version=1：items(id 主键, record_id, payload JSON, imported_ms)，record_id 索引。数据库与对象共同构成档案，**仅凭文件目录不能重建全部元数据**。不合并或移动现有 journal.sqlite/视觉索引，不挂载网络活库。

`fox.archive.item.v1` 为闭合契约，运行时 validate() 拒绝多余字段：

| 字段 | 语义 |
| --- | --- |
| id / record_id | 稳定档案标识 / 来源事件关联；不同修订用新 id。来源设备需命名空间隔离，原产品 ID/修订仍保留在原 JSON/SQLite |
| kind | original / derived / evaluation / reference |
| role / source | video、photo、record、manifest、poses、audio 等用途 / 来源说明 |
| sha256 / size / filename | 完整性和原文件名；没有绝对路径依赖 |
| tags / note | 查询标签 / 入库说明，不冒充用户原话 |
| occurred_at | 已知发生时间 UTC Unix 毫秒，未知 null，不用导入时间补造 |
| derived_from | 依赖档案 ID；derived 必须非空，引用必须已存在 |

服务器生成 imported_at。用户文字作为原始记录附件保存；语音仅支持文件归档，不代表录音/转写已实现。AI 结果保存独立文件，其中记录模型、参数、不确定性，关联原件，不生成未经确认的事实。外部导入是内容快照加来源，不只有原位置。原有 EXIF、训练/6DoF 时间轴不因归档自动对齐。

上传先暂存、核验字节、fsync、原子发布后提交 SQLite；文件相同去重但事件不合并。中断可能留下未引用对象/staging，不自动删除、不冒充成功。flock 串行提交；当前 SSH 账号是信任边界，不防同账号恶意修改。传输失败整文件重试，不宣称分块续传。get 只写新路径，核验摘要后发布。

## 三个工作线共用

默认私有配置 `~/.config/fox/archive.json`：host 为既有 pinned SSH 别名，root 为绝对资料目录，script 为部署路径。同一 Mac 三个聊天共用，不含密码，不开监听端口。其他机器需要自己的 SSH 及配置，不宣称已接通。

```sh
python3.12 scripts/archive.py list
python3.12 scripts/archive.py list --tag vision
python3.12 scripts/archive.py list --record <record-id>
python3.12 scripts/archive.py verify <item-id>
python3.12 scripts/archive.py get <item-id> <new-local-path>
python3.12 scripts/archive.py put <file> --id <item-id> --record <record-id> --role video --source <source> --tag vision
python3.12 scripts/run-python-tests.py tests/scripts/test_archive.py
```

客户端查询图文/训练报告，视觉查询录像/关联诊断，数据线维护来源/关联/契约。三者使用同一入口，派生结果另建条目；不要直接编辑 originals 或 SQLite。数据发现不要求新增 Agent 或审批链。

## 保留与未来政策

当前全部保留、仅人工清理，无删除命令、无定期清理。服务器没有独立备份，不保证抗硬盘损坏、误删或主机丢失。用户希望未来源端仅短期缓存；这是后续可选策略，不将备份作为永久前置，但启用时需确认单副本风险、N 天、已核验条件和失败不删。现有原件继续保留。

## 执行记录

先添加 8 项合成测试，首次因实现不存在失败。实现后 macOS 临时目录的系统符号链接触发拒绝，测试改用规范化真实隔离目录，未放宽根路径保护；随后 8 项通过。

后续扩展为 16 项：并发相同上传、磁盘不足/发布失败、未知库版本、CLI 目标防覆盖、低空间幂等重试、UTF-8 协议头预算、假 SSH 不消费 stdin 的全过程超时、对象发布后数据库提交失败恢复。独立审查发现的三个 P2 均先补红测试再修复。超时默认 1800 秒，覆盖整个 SSH 进程而不只是 wait；重复项仍核验既有原件与本次请求字节。

真实闭环导入一个已有视觉诊断包（8 文件）及一份产品备份中的文字记录和关联照片（2 文件）。原诊断 manifest 的哈希逐项核验；原产品库只读 integrity_check；取回分别覆盖图文记录、录像、诊断上下文。再次上传维持 10 条目且返回 already_present。原件未删未改；不代表设备中其余录像已可查询，也未接收 Windows 6DoF。

本地证据目录 `.tmp/verification/shared-archive-20261028/`：ingest-receipt.json、workstream-access.json、local-tests.log、linux-tests.log、review-regressions-red.log。当前没有备份恢复承诺、没有新的真人/相机或 UI 验收；无需为本次工具变更重复训练。

独立复核确认三项 P2 已闭环，无当前范围内阻碍提交项。仍未直接覆盖“下载途中内容错误”与“下载期间目标被其他进程抢先创建”的客户端回归；现有摘要校验及不覆盖硬链接发布提供保护，不宣称这两项已有专项测试。
