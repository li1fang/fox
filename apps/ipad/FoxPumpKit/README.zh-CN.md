# FoxPumpKit

自由采集与未来训练共用的PUMP设备能力，不是另一个App。`PumpCore`只依赖Foundation；`FoxPumpApple`拥有唯一CoreBluetooth central/delegate，不引用相机、视觉或训练数据库。独立PUMP Lab冻结不动。

## 消费入口

- `PumpDeviceSession`拥有连接、设备事实、原始日志和配置操作；将`telemetry: PumpTelemetrySource`交给采集消费者，将`control: PumpConfigurationControl`交给显式用户配置流程。
- 扫描后明确选择两个不同UUID；`connectSelected()`可在录像前连接。记忆只含设备身份，不含发送许可或恢复设置。A/B不代表左右手。
- `makeRequest(PumpConfiguration)`冻结设备与参数；用户核对后调用`applyConfiguration`。四模式参数均显式使用Pro范围，不沿用旧实验5kg上限。
- `beginCapture`返回可独立保存的`PumpCaptureContext`并阻止配置；录像/封存完成才`endCapture`。订阅结束不释放共享连接，也不改变阻力。离页/后台由宿主调用`disconnect()`，不代表设备卸力。
- `readiness()`要求连接/可写特征和3秒内有效工作心跳，不要求运动或运动型通知。蓝牙回执只表示写入结果，不是力测量。

部分成功、未知、日志错误按逐台事实保留，无自动补发/回滚。新配置的确认同时核对旧不确定结果；未结束的底层写入账本不能被新请求覆盖，迟到回执只归旧请求。

`isApplying`表示成组调用仍在运行；`hasPendingWrites`表示底层仍有未排空写入。超时可结束前者，但不会清除后者。宿主用两者共同锁定录像，匹配请求的回调或确认断连才释放；可显式重连，不自动补发。普通遥测断连不停止已经开始的录像。

## 格式与归档

设备会话`events.jsonl`使用`fox.pump_control_event.v1`：session/event/request/device身份、host clock及接收单调时间、UTC、请求配置/原报文、原通知和逐台结果分别记录。配置中的kg是每台名义设定，不是实测拉力；通知仍保留未经核实的单位与原始字节。

每段实验额外保存`pump-context.json`（`fox.pump_capture_context.v1`）及`pump-control.jsonl`。外层仍为`fox.lab_capture.v1`，两者作为`events`流声明。准备期配置保留实际时间，即使早于录像；它是上下文，不被平移或计作训练运动样本。封包后不再随设备会话修改，旧实验不迁移、不重写。正式训练记录尚未接入。

每个配置请求及其结果事件都携带冻结的`request_devices`，不能用录像开始时的新设备对解释历史设置。原始连接流沿用`discovering/subscribed_no_data/receiving/failed/disconnected`；每个连接段只关闭一次，重连另起连接段。独立设备会话保留平台原始状态，适配层负责转换，不更改旧读取器的关闭后拒绝规则。

## 验证和假设备

`node scripts/test-pump.mjs`是仓库现有资源准入下的独立入口，测试登记在统一catalogue，也加入原fast/public入口。原41项核心测试和Python编码向量保留；新会话测试使用假传输，无需PUMP、相机或模拟器。

Debug提供`PumpSimulatedTransport`，客户端可用它注入`PumpDeviceSession`。App只有同时设置`FOX_UI_TESTING=1`与`FOX_PUMP_FIXTURE`才选择假设备；其资料使用隔离目录并标为synthetic，不构成真实BLE证据。`FoxAppTests/FreeCapturePumpControlTests`运行“配置→采集→保存→再次配置”示例。

## 来源与保留

控制基础来自2026-10-30冻结的用户自有PUMP Lab 0.3.0(4)：PumpProtocol、PumpGroup、PumpControlApproval、PumpPairPreferences、PumpWriteLedger及其41测试/向量。除PumpMode增加Codable外，既有核心规则保留；不搬WebKit/网页授权、旧Lab界面或其连接管理器。旧PumpGate仅为原核心兼容，Fox新会话不以它的运动通知条件授权。

FoxNative里旧只读adapter/central暂保留给既有回归测试；正式FreeCaptureNativeBackend已不构造它。实际采集只使用注入的PumpCaptureRuntime和一个ApplePumpTransport，不同时启动两套central。下一轮客户端可以基于此接口编排完整训练，无需重新研究BLE协议。
