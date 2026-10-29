# 训练资料投递与读取

本轮建立基础，不要求采集方先做数据融合。规范、限制和验收见 [SEN 计划](../planning/TRAINING_SENSOR_STORAGE_V1.zh-CN.md)，交换格式见 [schema](../../schemas/training-sensor.schema.json)。真实设备格式仍待样例验证。

## 采集方现在做什么

在 Fox 维护树使用 Node 22 / Python 3.12；个人连接配置已存在于 `~/.config/fox/training-store.json`。这是 Mac 控制端的配置，Windows 不会自动获得同名 SSH 主机或凭据。

```sh
npm run training:store -- reserve next-capture
```

命令会返回 **Linux 上的绝对目录**，重复执行不覆盖原文件。该目录包含：

```text
capture-draft.json
controller_6dof/
depth/
resistance/
video/
reports/
```

已有视频、CSV/JSON/二进制原格式放到对应目录即可；保持同一次采集在同一 capture 目录，下一次换一个新 ID。不要覆盖同名文件，上传时先用临时文件名，完成摘要核对后再确认就绪。这是人工/现有传输工具投递，不是本包已实现自动上传。

随资料说明：训练开始/结束的实际时间及时区、设备时钟含义/频率、单位、哪个手或测量部位、坐标轴和已知校准。未知就写未知，仍可投递，但不能把草稿当可融合数据。`capture-draft.json` 不是可导入会话；核对时间后创建一个 `schema=fox.training.capture.v1` 的正式清单，原草稿和原件保留。

Mac 临时接收可用 `npm run storage:paths` 输出的 **incoming**；查询取回大文件用输出的 **downloads**，不要继续放 Downloads 或仓库。优先直接传 Linux，Mac 仅作暂存。路径不会自动授予新主机权限。

## 适配方和分析方

```sh
# 生成完全合成的规范示例，目标目录必须不存在
npm run training:store -- example /absolute/external/path/synthetic-example
# 只在核对真实格式和时钟后使用同样契约导入
npm run training:store -- create /absolute/external/path/capture.json
npm run training:store -- ingest /absolute/external/path/controller_6dof.json /absolute/external/path/controller_6dof.ndjson
npm run training:store -- list
npm run training:store -- describe next-capture
npm run training:store -- timeline next-capture --limit 100
```

`reserve` 只创建投递目录，不会创建已接受会话，所以尚未 `create` 时 `describe` 返回未找到是正确行为。`list` 每页最多 100 项，下一页传 `--after <上一页最后的 id>`；`timeline` 返回 `next` 游标时把完整 JSON 作为下一次 `--after`，为 null 时结束。分页期间补入新流会报 changed，必须从头读取，不能继续旧游标。

NDJSON 每行：`{"seq":0,"tick":"123456789","values":{...}}`。规范 descriptor 的 size/sha256 必须匹配整份 NDJSON；它们不是原厂文件摘要，原厂文件应另存投递区并经已有归档流程保留。一个流最多 256 MiB / 100 万行，每行最多 64 KiB；每会话最多 64 流、256 个关联。真实长采集到达后再验证分块/吞吐需求，不以这次小样本承诺生产容量。

深度帧必须先通过 [既有归档入口](../planning/SHARED_ARCHIVE_V1.zh-CN.md)取得经过摘要校验的 asset ID。支持规范化的紧密排列 uint16_le 或 float32_le 帧，size 必须等于宽×高×元素字节数；其他厂商容器先原样投递，本轮不转换。米制比例和内参必须明确。示例 depth-frame ID 只是占位，不是真实帧。

`link` 接收单份 JSON：`id, session_id, archive_id, role, offset_us`，role 为 video/report/reference/calibration。offset_us 定义为“会话开始 UTC + offset = 参考媒体起点 UTC”；未知用 null，不把视频关联误称时间对齐。更正会话、流或关联须新 ID，不原地覆盖。消费者应明确选择某个采集 ID/版本，不把替代流盲目相加。

位置字段单位为米，四元数顺序 xyzw；resistance 字段为 force_n / position_m / velocity_m_s / power_w。真实来源若是 kg、毫米或 tick，不得直接改字段名冒充换算。按键保存原始值，不自动生成顶峰/谷值标签。lost 不携带沿用姿态。

## 工作线边界

- 产品与交付：维护资料位置、存储工具、部署和可用性，保留失败回执。
- 视觉与训练核心：读取 video/report/已接受流，下一轮核对真实时钟、适配与标注；不以 6DoF 手部轨迹替代视觉关节真值。
- 数据与服务：沿已接受会话/关联查询和解释；派生分析独立保存并引用原件，不改原始观测。
- 客户端与体验：后续把采集起止和来源标识接入此契约；本轮没有设备自动录像/上传功能。

普通任务一个负责人闭环，不需四方批准。各工作树需集成本包实现才有新 CLI 和自动外置输出；当前资料库已可通过共享配置访问，不要求等待所有 Agent 停工。

## 存储与验证说明

外置 profile 是这台 Mac 的私有设置，不提交 Git。支持 `FOX_STORAGE_CONFIG` 指定另一份配置，原有 `FOX_BUILD_CACHE_ROOT`、`FOX_NATIVE_LOG_ROOT` 和显式 `--output` 仍优先。没有 profile 的 CI/其他主机保持原默认路径；配置了外盘后，缺盘/标记错误立即失败，不静默落内盘。

本包接入 SwiftPM 缓存、verify/verify:workstream/design:review 输出与 native:run 日志，不接管所有任意脚本。真机签名构建路径保持不变，旧 `.tmp`/`.data`、录像与回执未移动删除。新路径不意味着内盘已有资料已释放，也不意味着已有独立备份。

```sh
npm run test:training-store
npm run verify:workstream -- data
# 明确只向合成会话写数据，保留结果，不使用设备
npm run training:store -- smoke synthetic-storage-check
```

窗口为实际采集 UTC 微秒 `[start_us,end_us)`；上传时间只作 received_us。纯合成通过只能证明存储契约和传输，不能证明真实时钟准确、视觉计数、深度或阻力设备适配和数据融合。
