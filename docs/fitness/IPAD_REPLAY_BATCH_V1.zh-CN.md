# iPad 端侧视觉批回放 V1

日期：2026-10-23。属于 FIT-M2 开发工具，不是训练入口、云同步或后台服务。使用同一个 Fox 的 Debug 构建，不另装 App；正常启动仍为 Home。

## 输入与计算边界

- `cache`：读取已保存的全候选姿态观测，不运行 Vision。
- `diagnostic`：读取保留诊断包的 `poses.jsonl`，时间单位为原始 capture PTS；重新就位命令需要从同包事件明确提供。
- `video`：读取本地语料 `manifest.json` 和其声明的视频，在 iPad 上复用原有提取器执行 Vision revision 1、10 Hz 采样，再回放。原视频不裁掉干扰人物。

默认 `mode: controller`（旧任务省略 mode 也保持此行为）将三种输入经过生产 `VisionLabController`，不是另写理想化计数器。任务明确动作、侧别、片段及重新就位时刻，不从最终次数反推参数。缓存是二维检测结果，不是人体真值。

0.6.5/build 21 增加 `mode: observations`：仅接受 video/cache、cases 必须为空；不运行控制器，不写训练记录，不输出次数。用于新动作尚无契约时检查原始关节，不能将空 cases 解释为动作 0 次。结果包含 `observationFrameCount`、`controllerVersion: not-run` 及独立证据边界。

## 使用

前置：已配对且可启动开发 App 的 iPad、Fox Debug 0.6.5 或更新候选、Xcode。运行期间设备需保持前台；不需要打开摄像头，不承诺锁屏或后台计算。

```sh
# 现有视频；cache/diagnostic 则将 source 换成 jsonl
npm run vision:batch -- prepare \
  .data/vision-corpus/20261005-fox-fitness-reference/manifest.json \
  --kind video --cases docs/fitness/experiments/reference-controller-cases.v1.json

# 使用上一步返回的 directory，不能在正式训练中强行替换进程
npm run vision:batch -- run .data/vision-replay/jobs/<UUID> --replace-running
npm run vision:batch -- verify .data/vision-replay/results/<UUID> \
  --job .data/vision-replay/jobs/<UUID>

# 设备已完成但取回中断：只取回，不覆盖或重新执行该 UUID
npm run vision:batch -- pull .data/vision-replay/jobs/<UUID>

# 新动作只提取观测，不冒充已支持的弯举/侧平举
npm run vision:batch -- prepare .data/vision-corpus/<corpus>/manifest.json \
  --kind video --mode observations
```

`FOX_IOS_DEVICE` 可选定目标设备。`--settings <json>` 使用导出的完整 `PoseSessionSettings`；省略时以执行构建的标准配置为准，实际使用的完整配置与 SHA-256 必须进入结果。要跨构建精确复现，显式传入之前的 `settings.json`。

## 文件契约

- Mac 私有任务：`.data/vision-replay/jobs/<UUID>`。输入复制为快照，不修改原片。
- iPad 输入：`Documents/FoxReplay/Jobs/<UUID>`；App 自有输出：`Documents/FoxReplayRuns/<UUID>`。CoreDevice 上传目录可能归系统用户所有，不能在其下面创建输出。已存在的运行目录不可覆盖，重试计算须新任务 ID。
- 开发入口回执：`Documents/FoxReplayLaunches/<UUID>.json`，用于区分未进入页面、等待前台和计算未启动；不是成功结果。
- Mac 校验后结果：`.data/vision-replay/results/<UUID>`。
- `job.json`：版本、UUID、输入类型/文件、逐文件字节数及 SHA-256、片段、命令和可选配置。
- `result.json`：输入/任务摘要、实际 App/硬件/系统/算法/控制流程版本、实际配置与摘要、是否重新执行推理、每片段逐帧主体/启动/计数/阶段、逐次离心字段和重置原因。
- `settings.json`：实际配置的可重用快照。
- `vision.jsonl`：仅新视频推理输出；保存采样频率、来源视频摘要、Vision revision、预处理版本及时间基准。
- `status.json`：`validating`、`extracting`、`replaying`、`completed`、`failed`、`cancelled`；只有 completed 且所有输出摘要通过才接收。半成品、取消和校验失败都不是成功。

结果先进入私有暂存目录，完整校验后原子移入结果目录；重复取回相同结果允许，不同内容拒绝覆盖。不自动清理 iPad 原片或历史报告。原视频、姿态、结果均不进入 Git。

## 限制与验收

控制器任务最多 16 个片段、单输入资产 512 MiB、缓存 64 MiB、总时间线 10 分钟；计数仍只支持既有弯举/侧平举。observations 不支持新动作计数，只提取原始观测。退出前台或取消请求中止任务，不自动恢复；视频处理在下一批检查点响应取消。

正式训练、生活记录与视觉历史不作为输出目录。设备取回有哈希保护，但不是 App 间鉴权同步，也没有大文件断点续传。Mac 保留源码、测试和结果副本；iPad 可承担昂贵推理和原始资产存储，不能作为唯一备份。

自动测试及本轮真机证据见 [执行记录](VISION_M1_M2_EXECUTION_20261023.zh-CN.md)。动作扩展遵循 [适配规范](ACTION_ADAPTATION_METHOD_V1.zh-CN.md)，M3/M4 在复盘、新录像之后启动。

三段新录像的 observations 真机验证、关节连续性及后期打点审阅见 [三动作评测结果](experiments/THREE_ACTION_OBSERVABILITY_V1.results.zh-CN.md)。分析入口为 `node scripts/vision-observability.mjs`；审阅图工具 `vision-observability-review.py` / `vision-observability-plot.py` 使用 Python + Pillow，本轮使用 Codex 捆绑运行时，不要求新增服务。

回归入口：`npm run test:native`（核心）、`npm run test:home`（实际控制器与批任务）、`npm run test:vision:flow`（准备/重新就位/任务页面）、`npm run test:scripts`（任务打包与校验）。私有素材缺席时相关测试会明确跳过，不把公开 CI 当作私有视频验收。
