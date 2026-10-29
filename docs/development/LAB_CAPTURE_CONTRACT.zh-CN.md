# LAB capture v1：共享封包接口

数据线格式 owner；独立于旧 diagnostic/正式 Training 和 Journal。实现基线 `1a2021c`。本页与 schema 的字段为接口提案 v1；消费者集成变更须由原 owner 更新反例。没有新数据库。文件/原件不得自动清理。

## 文件与值类型

包目录：`manifest.json` + files 清单中的相对文件。建议命名 `video.mp4`、`frames.jsonl`、`poses2d.jsonl`、`poses3d.jsonl`、`pump-A.jsonl`、`events.jsonl`；文件名本身不决定类型。附件不得放入旧诊断 drafts 目录。

唯一共享值类型在 `apps/ipad/FoxTrainingCore/Sources/FoxTrainingCore/LabCapture.swift`：`LabCaptureManifest`、`LabCaptureStream`、`LabCaptureAsset`、`LabCaptureSource`、`LabUTCAnchor`、`LabRationalTime`、`LabFrameRecord`，全部 Foundation Codable/Equatable。Native import FoxTrainingCore，客户端不要另写同名 manifest。使用默认 JSONEncoder/Decoder（不启用 keyEncodingStrategy），显式 CodingKeys 固定 snake_case；可选字段编码时允许省略或 null。Native 录制/持久化、摘要计算与 UI 由客户端实现；本类型不启动相机/推理/BLE。

manifest 必需键：schema、capture_id、mode、host_clock_id、started_host_ns、ended_host_ns、streams、files。action/side/strategy/utc_anchor 可省略或 null，unknown action 用 null；不能写假动作。mode 为 free_capture 或 exercise_evaluation；后者需要非空 action 与 strategy。side 为 left/right/both/not_applicable 或 null。

stream：id、kind、state、reason、record_schema、source。kind 为 video/camera_frames/pose2d/pose3d/pump_raw/pump_parsed/events；state 为 complete/interrupted/failed/unavailable/not_requested。reason 在后三种失败/中断状态必须非空；complete/not_requested 可空。source 有 producer/version/clock_id，以及可空 device_alias/coordinate_system/unit。两台 PUMP 用不同 alias 和流，不暗指左右侧。v1每流最多一个文件（分块顺序尚未定义），complete 流必须有一个文件；not_requested/unavailable 不应有文件。manifest 只描述已封存包，不作为运行中状态存储。

asset：path、bytes、sha256、stream_id。path 必须安全相对 POSIX 路径；无符号链接、重复路径或未列出文件。字节数与 SHA 必须实际一致。files 不包含 manifest 自身；导出回执另算整个 manifest/zip 摘要。合法“完整封包”不等于每条观测成功，保留 stream_states。

时间：顶层 host_clock_id 标识本次接收时钟，所有 source.clock_id 均引用它（不是设备采样时钟）。所有 host_ns 为同一采集进程单调纳秒的十进制字符串，不以 Date 代替曝光时刻；UTC anchor 仅是一条显式主机-UTC 对应及不确定度，无法核实则 null。服务器 received_us 不在这里冒充 BLE 接收时间。重连/设备 tick 重置换连接段，时钟映射另存，未知映射不得填零。

## JSONL 公共时间包络

`fox.lab_frame.v1` 每行必需：schema、seq、pts、origin_pts、video_seconds、host_received_ns、state；reason 可空。pts/origin_pts 各含 value（带符号 Int64 十进制字符串）和 timescale（正 Int32）；保留 CMTime 原值，不先转 Double。video_seconds = pts - origin_pts，允许微秒级浮点舍入，必须非负有限。host_received_ns 不与 PTS 数值直接比较。state 为 observed/dropped，dropped 必须有 reason。丢帧也保留时间行，不能默默压紧视频时间。

2D/3D 行形状由视觉线 owner 提供版本化 record_schema，本数据线不发明关节 schema。外层 manifest 记录来源/坐标/单位；离线消费者只能校验附件字节和已知 schema，不能把未知 row schema 宣布语义验证完成。封包回执列出未解析 stream，不以字节校验替代关节/时钟校验。

PUMP 原始行后续使用独立 schema，原 bytes 与主机接收时间、连接段、通知序号一起保留；具体字段解析等待可复用协议。原始通知没有设备时钟则 device tick 为未知。FFE1 订阅与任何厂商写帧分类分开，默认不提供 FFE2 控制写接口。

## 离线消费者

`python3.12 scripts/lab_capture.py verify <package-dir>` 输出 capture_id、stream_states、unparsed_streams、manifest_sha256；只读。
`... export <package-dir> <new.zip>` 先校验、流式复制到目标旁临时文件、回读校验后无覆盖发布，取消/失败不删源包；大目标由调用者放既有外盘。
`... verify-export <zip>` 不解压到用户路径，拒绝重复条目/路径穿越/过大文件/符号链接/摘要不符，返回同样语义。未知 PUMP/pose schema 字节可保留，但回执必须标为 unparsed。

正式 resistance 导入沿 `TRAINING_DATA_HANDOFF.zh-CN.md`；仅单位/时间已核实时转换，2D/3D 保持归档关联，不扩充既有三类传感器。训练完成、实际次数、运动效果不从本 manifest 推断。

## PUMP 协议接手及只读适配接口

工程交接的 handoff-receipt SHA256 为 `0c0af55e8ad0da5a1ad0575a914b78dcb48c73be584c689d429ec8952e42da50`，列出的10个文件逐项核验。参考上游固定版本 `51dd3e0620993ddf095a8491d789326b62ed61f9`；未见明确许可证，未复制其源码或真实原件到本仓库。本文字节字段依据工程交接，新增代码独立实现，测试只造合成输入。

`PumpTelemetryReading.decode(Data)` 在 FoxTrainingCore，支持已观测总长11字节 type02、21字节type03，检查0x53头/声明长度/sum8；不满足者保留 raw_hex、reason 并隔离；其他类别包括boot保持 unsupported。所有字段按 raw 或 upstream 明示，未输出 position_m/force_n/power_w，不把累计量当采样时钟。

Native 新文件 `PumpReadOnlyAdapter.swift`，不修改既有控制器；客户端提供已经明确选择且已连接的 CBPeripheral，`begin(_:) -> Bool` 接手本次 delegate，`onNotification(PumpNotificationEvent)` / `onState(PumpConnectionEvent)` 接收回调；owner 将事件串行持久化。每次 begin 新segment，stop/外部disconnected后恢复原delegate，不扫描/连接/查询身份。只 discover FFE0 / FFE1 和 setNotifyValue；系统CCCD订阅不是FFE2应用控制。没有阻力/模式/启动命令编码；不承诺未测固件、双设备或BLE独占。

PUMP stream 的 kind=pump_raw，record_schema=fox.lab_pump_events.v1，source.device_alias 必须与行一致，source.clock_id 是iPad主机单调时钟ID。通知行键 schema=fox.lab_pump_notification.v1、capture_id/device_alias/connection_segment_id/host_clock_id/notification_seq/host_received_ns/decoded；device_tick 必须缺失或null。decoded 与原raw_hex重新解析比对。连接行 schema=fox.lab_pump_connection.v1，公共身份/时间加state/reason。状态discovering/subscribed_no_data/receiving/failed/disconnected；failed/disconnected必须reason。同段序号和主机时间递增（主机时间可相等）；断开后的通知拒绝，重连必须新segment。

Python等价纯解析在 scripts/pump_telemetry.py，未调用协议源中的查询编码器。事件和manifest共同校验原字节、设备/连接身份及时间，不推进正式training-store。缺绳长标定、可靠时间映射，真实resistance转换保持未实现；不能通过合成两行示例宣称真实入库。

## Cross-language golden

`tests/fixtures/lab-capture/synthetic-v1` 是完全合成的 Python producer 包；跨语言 XCTest `LabCaptureTests/testPythonExportIsNativeReadableAndNativeWireIsPythonVerified` 运行 scripts/lab_cross_language.py prepare，实际生成/验证 ZIP 后 Native 解码附件及 manifest，再编码新的 manifest/帧/通知，最后调用 verify-native 用独立 Python 校验。测试不读取真实包、不操作设备，只有原生窗口发放后执行；未执行前不能报告跨语言已通过。pose行格式仍待对应owner提供并另加消费者反例。实验封包值类型只负责 wire shape；原生持久化必须另验证状态、摘要与原件保留，不把 Codable roundtrip 当文件完整性通过。

## 本候选执行边界

Python/Node轻量检查已执行：17项LAB/PUMP合成测试及既有training-store/archive共53项通过；接手10组合成向量按保守策略核对通过；Node22仓库契约登记通过。首轮缺实现、macOS临时目录别名夹具失败、PUMP事件未解析以及未定义分块顺序的失败均保留。没有运行Swift/Xcode/模拟器、BLE、服务器写入或真实媒体分析；新值类型、Swift解析器、Native适配器、跨语言golden仍待原生窗口和独立审查。不以Python等价解析通过代替Swift执行。JSON Schema是外层结构，跨字段/时间/摘要约束由离线校验器执行；本机未安装jsonschema，未用其声称完整schema验证。
