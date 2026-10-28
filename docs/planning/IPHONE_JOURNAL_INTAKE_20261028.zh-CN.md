# iPhone 当前记录接收与 Linux 交接

日期：2026-10-28。负责人：产品与交付；消费入口：数据与服务。关联 [共享资料库](SHARED_ARCHIVE_V1.zh-CN.md)与 [STORE-3 批量归档](ARCHIVE_BULK_20261028.zh-CN.md)。

## 目标与边界

只读取当前 Fox Journal，核对文字、照片及修订关联，经现有归档工具交给 Linux。保留设备和 Mac 原件，不重新安装、不启动或修改训练、不读取系统照片库、不改产品或 CI。设备锁定、来源变化、数据库/附件不一致、远端校验失败时，不发布新指针。

先设计合成测试，再采集。用户解锁后通过已有设备连接完成两次独立复制；未要求额外接线。复制前后读取文件清单，逐文件比较大小和 SHA-256，包括 SQLite 的 WAL/SHM。在临时副本上进行数据库完整性、外键、修订、照片关系及附件路径/大小/摘要检查，不对原件执行数据库写入。

## 结果

- 采集窗口：2026-10-28 14:30:09–14:30:11（Asia/Bangkok，UTC+7）。
- 8 条当前记录、9 个修订、5 张照片，8 个原始文件。
- 两次复制文件逐字节摘要一致，数据库逻辑内容一致；采集前后文件清单一致。
- 所有修订中的照片关联与照片描述符一致，当前修订存在，照片大小与摘要全部相符。
- 原件与完整修订表已归档；Linux 上逐对象核验，索引及全部 5 张照片已重新下载校验。
- 当前目录指针在上述核验后更新，旧索引继续保留。

这证明安静采集窗口内的稳定双副本一致性，不是与持续并发写入事务协调的在线备份。不是自动同步、全部手机内容或独立灾备，也不代表数据工作线已经完成 AI 分析。

## 数据与服务如何读取

沿用 `~/.config/fox/archive.json`，从 `~/.config/fox/archive-current.json` 读取 `iphone_journal_snapshot_id`，再用现有入口取回到一个新文件名：

```sh
python3.12 scripts/archive.py get <iphone_journal_snapshot_id> <new-local-index.json>
python3.12 scripts/archive.py get <photo-archive_id> <new-local-photo-path>
```

新索引格式为 `fox.journal.current_snapshot.v1`：

| 字段 | 用途 |
| --- | --- |
| `capture_window` | 原始 UTC 采集窗口与来源，不把归档时间当事件时间 |
| `records` | 当前修订原 payload，保留文字、原 ID、时间与照片描述符 |
| `revision_count` / `all_revision_tables` | 修订数量与原数据库逻辑表，保留历史，不覆盖旧事件 |
| `photos` | `original` 为原照片描述符；`archive_id` 获取原始图片 |
| `original_files` | 相对路径到归档对象的映射，可重建原始数据库及附件副本 |

按记录内照片 ID 关联 `photos[].original.id`，随后取 `archive_id`；不要依赖数组顺序或文件名猜关系。SQL 存储键使用小写 UUID，原 JSON UUID 可以大写，关联时规范大小写，不改原 payload。JSON 中 SQL 行由元组序列化为数组，比较时统一 JSON 表示，不因此修改源数据。索引与照片包含私有记录，只放私有目录，不能提交 Git/CI。

## 验证与失败保留

9 项私有合成测试覆盖有效记录、UUID 大小写、JSON 行往返及变更检测、缺图、摘要错误、关系断裂、缺修订、文字变化和路径越界。真实数据验收另外验证双复制、完整关联、远端核验与全部照片回读。

首次校验器错误把 SQL 小写 UUID 与 JSON 大写 UUID 当作数据错误；按源码约定修正并补测试。随后 JSON 元组/数组比较误报，修正比较表示并补往返测试；原始副本、工作副本与上传回执保留，没有放宽内容断言。已有上传不重复执行，收尾重新核对本地副本及远端对象后才发布。

私有证据：`.tmp/verification/iphone-current-snapshot-20261028/`，最终回执 `attempt-1/accepted.json`。运行脚本仅为本次受控接收，不宣称产品已实现自动同步。后续变化需新快照；iPad 新增录像、系统相册和 Windows 6DoF 仍按原台账待取得。
