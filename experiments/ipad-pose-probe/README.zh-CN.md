# M4 同视频诊断 App

这是独立的 `com.whipa.foxposelab` 临时 App，不是 Fox 的新版本。只读取开发通道传入的本地视频，不请求相机、麦克风、相册或网络权限，不访问 Fox / Fox Say 容器，不保存正式训练组。

## 固定范围

- 同一归档完整 MOV，先校验 manifest 的视频 SHA-256，保留路人、换器材与退出画面。无音频输入。
- 与 Mac 共享 `FoxPoseExperimentKit`：10 Hz、精确取帧、原方向变换、最大边 1280、PNG 编解码后 Vision revision 1。逐帧图片不归档，只保留坐标、时间与 PNG 哈希。
- 在 iPad 上调用同一 `FoxTrainingCore` 的主体选择、准备门禁、旁路计数和门禁后计数。默认配置不调参，不运行 MediaPipe 或 Apple 官方时序计数器。
- 设备缓存取回后，在 Mac 上再执行同一核心；要求同一姿态输入下所有片段的逐次事件、门禁和诊断一致，不只要求总数相同。
- 跨系统的 PNG 哈希可能不同。视频、样本时间和尺寸一致不自动等于解码像素完全一致；平台差异包含解码/预处理/推理，不能仅归因芯片。
- 这是设备离线回放，不经过实时采集、主 App 控制器、相机方向处理和实时看门狗；通过也不是实时相机验收。

## 运行

在仓库根目录运行；Xcode、签名及设备 ID 沿用本机配置，不能在其他机器盲用。不会修改全局 `xcode-select`。

```sh
xcodegen generate --spec experiments/ipad-pose-probe/project.yml
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project experiments/ipad-pose-probe/FoxPoseLab.xcodeproj -scheme FoxPoseLab -configuration Debug -destination 'id=00008132-000A70103EF9001C' -derivedDataPath .tmp/ipad-pose-probe-derived -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device install app --device EB14AB10-92D9-5F65-8F79-88F1B059B151 .tmp/ipad-pose-probe-derived/Build/Products/Debug-iphoneos/FoxPoseLab.app
```

首次普通启动只创建 `Documents/Input` 和 `Documents/Runs`，不自动跑实验。用 `devicectl device copy to --domain-type appDataContainer --domain-identifier com.whipa.foxposelab` 把原 MOV 和 manifest 复制到 `Documents/Input`。不要打包视频进 App，不要拷进正式 Fox。

运行时显式传入环境变量 `FOX_POSE_RUN_ID`，每次使用新的字母/数字/连字符 ID。自动启动只终止这个诊断 App 的旧实例，不能终止 Fox 正式训练。

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl device process launch --device EB14AB10-92D9-5F65-8F79-88F1B059B151 --terminate-existing --environment-variables '{"FOX_POSE_RUN_ID":"m4-reference-NEW-RUN"}' com.whipa.foxposelab
```

必须在前台处理，运行中禁用自动锁屏；切到后台/锁屏被检测到时拒绝该次结果。结束后恢复自动锁屏。开发安装与启动可能仍需要用户解锁或信任，不把有线/无线连通当作绕过系统安全条件。

取回 `Documents/Runs/<runID>`，只接受 `status.json` 的 `phase=completed`、无 error，并且完整缓存校验及评价通过的运行。`.partial.jsonl`、进程启动成功或只显示进度均不算完成。

## 证据

输出包括 `vision.jsonl`、`evaluation.json`、`status.json`。源视频、坐标和设备回执只能存放 `.data` / `.tmp`，不进 Git；这些文件含健康活动/身份敏感信息。现有实验素材已用于调参，不是独立准确率样本。

Mac 验证使用 `fox-pose-experiment evaluate-core`，不运行官方时序计数器；跨设备校验与逐次标签匹配用 `scripts/pose-device-comparison.mjs`。本次结果另记于 `docs/fitness/experiments/M4_SAME_VIDEO_V1.results.zh-CN.md`。
