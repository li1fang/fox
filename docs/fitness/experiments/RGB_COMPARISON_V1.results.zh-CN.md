# RGB 对照实验 V1：旧素材能计数，现场差异仍未定位

日期：2026-10-17。状态：**Mac 离线第一轮已执行；随后 M4 同视频也完成，见 [M4 补充结果](M4_SAME_VIDEO_V1.results.zh-CN.md)。实时相机及新场景验收未完成。** 不宣布视觉可用，不更新训练 App，不更换模型。下文保留 Mac 首轮实验过程，最新定位结论以补充结果为准。

## 1. 视频是否够用

足够比较现有两动作在同一素材下的模型与计数方法，也足够检查启动门禁、主体粗检查点和已有干扰窗口。不足以建立独立准确率，也不足以解释没有录下图像的本次 M4 现场失败。已有动作与标签曾被用于调参，`heldOut=false` 保持不变。

使用归档完整 200.366667 秒视频，原 SHA-256 与 manifest 相同；不是只剪出能成功的部分。已有粗循环标签为左弯举 10、右弯举 9、侧平举左右各 5。后两列是同一组双臂动作的两个观察侧，不作为两个独立运动组或累加成 10 次侧平举。后期击掌不输入模型。

## 2. 实验设计与执行

[事先固定的计划](RGB_COMPARISON_V1.plan.json) 不随本轮计数结果改动。两类 Fox 计数实验使用同一配置和 runtime policy，未修改角度、时长、缺失容差或重绑规则。

- **A**：Vision revision 1 + 现有 Fox 主体选择、启动门禁和计数器。
- **B**：A 选中的姿态 + Apple `HumanBodyActionCounter`；90 帧窗口、stride 5；预设 10/5 Hz 和全身非面部关节/所选臂两类输入，共 16 个输出配置。短缺失导致选择为空时切断序列，不复用旧坐标。
- **C**：MediaPipe Full + 同一 Fox 规则。VIDEO 模式、CPU、最多 4 人，检测/存在/追踪门槛均为 0.5；适配层使用 min(visibility,presence)，不是把它们解释为与 Apple confidence 等价的概率。参数未按本轮输出调优。

Mac 为 macOS 26.5.2 / Build 25F84；MediaPipe 1.1.1、OpenCV 5.0.0。模型 SHA-256 为 `4eaa5eb7a98365221087693fcc286334cf0858e2eb6e15b506aa4a7ecdcec4ad`。版本锁定文件和最终源码校验清单在本地实验目录。

原视频按同一方向变换、最大边 1280、10 Hz 得到 **2004 个全画面样本**，末帧 200.3 秒。每帧经无损 PNG 编码后由 Vision 读取同一 PNG，流式交给 MediaPipe；消费方逐帧核对 PNG SHA-256、尺寸和时间单调性。缓存只保存坐标、像素文件哈希与离线处理耗时，**没有持久化逐帧图片、音频或 base64**。所有原始图像和数值缓存留在被 Git 忽略的私有目录。

这里“同输入”指两模型获得同一 PNG 样本；不同框架内部的预处理和加速器并不相同，不据耗时评判 M4 速度优劣。Vision 最多检测 5 人、MediaPipe 配置上限 4 人；该差异保留，不为结果临时改人数。

## 3. A/C：绕过启动，仅检验计数

匹配原有粗 start/peak/returned 窗口，另检查确认时间和顺序，不只看总数。

| 开发素材 / 观察侧 | 原标签 | A：Vision + Fox | C：MediaPipe + Fox |
|---|---:|---|---|
| A01 侧身弯举 / 左 | 10 | 10；匹配 10、遗漏 0、额外 0 | 10；匹配 10、遗漏 0、额外 0 |
| A02 侧身弯举 / 右 | 9 | 9；匹配 9、遗漏 0、额外 0 | 9；匹配 9、遗漏 0、额外 0 |
| A03 正面侧平举 / 左 | 5 | 5；匹配 5、遗漏 0、额外 0 | 5；匹配 5、遗漏 0、额外 0 |
| A03 正面侧平举 / 右 | 5 | 5；匹配 5、遗漏 0、额外 0 | 5；匹配 5、遗漏 0、额外 0 |

每个目标对应的已有主体粗位置检查点都处于预期区域。该检查不是逐帧身份真值，也不证明每个关节精确；“几何可用”指配置门槛通过，不等于解剖坐标真值。

结论：在这段素材的支持机位，RGB 图像已有足够信息让两条管线完成现有计数目标；**没有观察到替换 MediaPipe 的计数收益**。不能据此证明两模型同等泛化、MediaPipe 不值得用，或 iPad 现场问题已解决。

## 4. 启动门禁启用后的区别

在每段开始处模拟点击准备，使用同一主体选择和 `PoseStartGate`；不是实际 UI 操作，也没有模拟实时相机队列、看门狗或训练存储回调。

| 素材 / 侧 | A 准备完成时刻 | C 准备完成时刻 | A/C 启动后次数 |
|---|---:|---:|---:|
| A01 / 左 | 视频 10.3 s | 10.3 s | 9 / 9 |
| A02 / 右 | 63.7 s | 63.9 s | 9 / 9 |
| A03 / 左 | 123.3 s | 123.3 s | 4 / 4 |
| A03 / 右 | 123.3 s | 123.3 s | 4 / 4 |

A01/A03 的录像在模拟倒计时完成前已经做了第一下，门禁后的结果少一。这不是该动作必然漏一次，也不是从完整现场训练测出的漏计率；视频没有记录新的真实交互准备过程。这恰好说明**旧的旁路计数通过不能替代“实际何时允许开始”验收**。

旧素材里四个目标都能通过准备；无法据此解释本次侧平举始终无法启动。未观察侧的侧身弯举在本素材中未通过准备，不作为已支持能力。

## 5. 干扰与不支持机位

- A02 延伸至 120 秒，保留换器材和路人；两条 Fox 管线在 107–120 秒均未新增计数。主体随后进入 lost，A 约 109.3 秒、C 约 109.4 秒；没有自动接管其他人。这是一个负例窗口，不代表所有路人均能排除。
- 正面弯举探索片段，两条 Fox 管线左右均为 0 次；不将其变成支持机位。它没有完整循环精细标签，不报告“准确率为 0%”。
- 正面探索含关节投影退化和追踪超时；两种关键点来源均未使现有二维规则成功，说明换关键点模型本身没有在本片段解决该机位问题。尚不能据此证明任何 RGB 方法都做不到。
- 正面探索后的 185 秒至结束，两个观察侧、两条 Fox 管线均未新增次数。其他静止与半程负例仍沿用核心测试；不把本录像说成覆盖所有异常动作。

## 6. B：Apple 官方时序计数器

下表均为**原始累计小数估计**，不四舍五入成达标次数，也不与 A/C 的完整端点语义等同。

| 片段 / 所选侧 | 参考完整循环 | 全身非面部 10 Hz | 全身非面部 5 Hz | 所选臂 10 Hz | 所选臂 5 Hz |
|---|---:|---:|---:|---:|---:|
| A01 / 左 | 10 | 0.100 | 10.304 | 0 | 8.301 |
| A02 / 右 | 9 | 0.295 | 9.368 | 0 | 3.730 |
| A03 / 左 | 5 | 0 | 2.171 | 0 | 0 |
| A03 / 右 | 5 | 0 | 2.171 | 0 | 0.033 |

A03 全身输入左右两行是相同身体序列的重复对照，不算两次独立成功。A02 连续选中段稍延伸到器材切换初期，这些估计不是严格按人工完整循环窗口计数。

首次完整窗口在 10 Hz 下需要约 9 秒，在 5 Hz 下约 18 秒；这是样本时间跨度，不是当前 Mac 以离线速度运算所花的等待时间。SDK 在有限序列末尾还会给出较短尾窗的输出，本工具保留其时间范围，没有自行补造帧。全身输入在 5 Hz 对弯举接近参考，但侧平举仍明显不足，所选臂的局部输入也没有稳定效果。说明本轮接口可运行，**不能不加验证就替换 Fox 计数器**；也不宣布此 API 在其他配置或场景不可用。它没有独立给出符合本项目粗端点标签的逐次事件，本轮不为它制造匹配率。

实验适配中发现时间基准错误：初版将输入标识设为 60 kHz 视频 tick，而滑动窗口按样本序号重建范围，导致输出窗口时间不实。旧结果保留但拒绝用于结论；已改为样本 index/hz，重新执行并新增自动拒绝错误时间基准的测试。修复后上表小数数值未变，窗口时刻恢复正确。没有为获得更好次数调整模型参数。

## 7. 结果回答了什么

| 问题 | 当前答案 |
|---|---|
| RGB 图像是否原则上无法支持这两个计数目标？ | 本录像提供反例：支持机位下两管线均做到粗逐次匹配，不能认定 RGB 不行 |
| 能否直接把新模型换进 App？ | 没有证据支持；C 未在本素材增加收益，B 也不是稳健替代 |
| 之前录像校准是否全无作用？ | 不能这样说，A 在本素材保留了改善；但它并未解决现场泛化和使用流程 |
| 本次 M4 失败究竟是模型、机位还是 App？ | 仍未区分：缺少 M4 对同视频的结果，以及现场启动失败的图像/完整诊断 |
| 现在应继续加深度吗？ | 本轮未比较深度，不能证明其必要性或无用；暂不增加复杂度 |

## 8. 下一步建议

续轮更新：下述 M4 同视频任务已执行，逐次匹配及门禁结果与 Mac 一致。当前优先级转为实时采集/控制器链路及失败启动诊断；详见补充结果，不重复把 M4 实验列为未执行。

**优先做 M4 同视频定位，不继续盲调角度。** 同一原视频在 iPad 上经设备原生 Vision 和同一 Fox 核心回放；与 Mac 对照准备、关节可用性、主体绑定和逐次事件，不只是总数。必须与正式训练记录隔离，不自动生成已完成组、不覆盖原报告；部署方式与稳定训练候选的保护另行决定，本轮未安装实验到 iPad。

- 若 M4 同视频也通过，而实时使用失败：优先查实时采集、方向/镜像、画面裁剪、照明、实际机位和交互协调；不是继续针对旧录像优化阈值。
- 若 M4 同视频明显差：先定位平台推理/解码/预处理差异，再评估是否需要 iOS 上的替代姿态模型。
- 同时补从点击开始就能保存的失败诊断，并让已有人工开始/计数路径更明确。视觉失败不能阻挡普通训练。
- 如仍需新证据，只在下一次正常使用中自愿保留短失败片段，不要求现在重录完整素材、增加重量或扭曲姿势。

本轮没有完成新的现场准确率、稳定性或动作质量验收；两个动作仍为实验能力。

## 9. 复现与测试

实验工具不依赖 Web/API/Linux，不把 MediaPipe 加进 iPad App。依赖仅在私有 venv；原视频和旧 v3/v4 结果未覆盖。

```sh
uv venv --python 3.11 .tmp/pose-comparison-20261017/venv
uv pip install --python .tmp/pose-comparison-20261017/venv/bin/python -r scripts/pose-experiment-requirements.txt
# Full 模型从 Google 官方下载；本轮实际文件哈希见上方。
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build --package-path apps/ipad/FoxTrainingCore --scratch-path .tmp/native-core-build --product fox-pose-experiment
node scripts/pose-model-experiment.mjs .data/vision-corpus/20261005-fox-fitness-reference/manifest.json .tmp/pose-comparison-20261017/venv/bin/python .tmp/pose-comparison-20261017/pose_landmarker_full.task .tmp/pose-comparison-20261017/shared-full-frames.jsonl
.tmp/native-core-build/debug/fox-pose-experiment evaluate .data/vision-corpus/20261005-fox-fitness-reference/manifest.json .tmp/pose-comparison-20261017/shared-full-frames.jsonl vision .tmp/pose-comparison-20261017/vision-evaluation-timebase-fixed.json
.tmp/native-core-build/debug/fox-pose-experiment evaluate .data/vision-corpus/20261005-fox-fitness-reference/manifest.json .tmp/pose-comparison-20261017/shared-full-frames.jsonl mediapipe .tmp/pose-comparison-20261017/mediapipe-evaluation.json
node scripts/pose-experiment-report.mjs docs/fitness/experiments/RGB_COMPARISON_V1.plan.json .data/vision-corpus/20261005-fox-fitness-reference/cycles-part1-coarse.v1.json .tmp/pose-comparison-20261017/summary-accepted.json .tmp/pose-comparison-20261017/vision-evaluation-timebase-fixed.json .tmp/pose-comparison-20261017/mediapipe-evaluation.json
```

重新运行须选新输出目录/文件，不覆盖旧证据。已有 venv 可跳过创建；模型下载链接为 Google `mediapipe-models/pose_landmarker/pose_landmarker_full/float16/latest/pose_landmarker_full.task`，将来 latest 可能变化，重现实验先核验哈希，不能只按文件名认定同模型。

- Python 映射 7 项通过：上下原点、解剖侧、置信度适配、越界点、非有限值、派生点及拓扑。
- 汇总脚本新增 9 项通过：总数相同但事件错位、启动与旁路分离、未知与零分开、原始小数不冒充整次、像素来源/参数不一致拒绝、缺失目标/重复后端拒绝、窗口时间基准错误拒绝。
- 训练核心 109 项通过，未改计数核心或参数；完整脚本测试 28 项通过（包含新增 9 项）。未跑原生 UI、真机相机或云 CI，因为本轮不改 UI 或部署 App。
- MediaPipe 的 feedback tensor 与 NORM_RECT 警告留在 `inference.log`，未被当作成功消息或抹掉；运行完成并得到 2004 帧，但这些日志也不是姿态精度保证。

私有证据目录：`.tmp/pose-comparison-20261017/`。正式采用 `shared-full-frames.jsonl`、`vision-evaluation-timebase-fixed.json`、`mediapipe-evaluation.json`、`summary-accepted.json`；旧 `vision-evaluation.json` 与 `summary.json` 的原生计数时间基准有误，**不采用**，`timebase-rejection.log` 记录自动拒绝。
