# Fox

**Record daily life. Train with guidance. Review what actually happened.**

Fox is a local-first iPhone and iPad app for personal records and guided exercise. It brings text, photos, workout plans and review into a native SwiftUI experience, while keeping what the camera observed separate from what the user confirms.

[See an activity, start to finish](docs/showcase/README.md) · [Engineering decisions](#engineering-decisions) · [中文说明](#中文说明)

<p align="center">
  <a href="docs/showcase/assets/activity-result.png"><img src="docs/showcase/assets/activity-result.png" width="360" alt="Actual Fox iPad simulator result page: automatic observation unknown, actual repetitions unconfirmed, retained video available, optional feedback, and analysis not yet requested."></a>
</p>

*Retained video, an optional reference count, notes and analysis status in one activity result. Real native UI with synthetic input; November 9, 2026 development snapshot (`789e99c`), separate from public main. [Explore the screens and their source](docs/showcase/README.md).*

## One activity, one review

Workout data is rarely perfect. A camera can lose a joint; a set can end early; a user can add context afterward. Fox keeps those facts together without turning missing evidence into a successful repetition.

1. **Start from an activity.** Choose the exercise and camera viewpoint.
2. **Capture and save.** End the segment and retain the associated recording.
3. **Review the result.** Open the video, add an optional reference count or note, and see whether analysis has been requested.

Follow the [illustrated walkthrough](docs/showcase/README.md) from the activity card to the saved result.

## Engineering decisions

- **Native UI, separate domain logic.** SwiftUI presents the activity; [training logic](apps/ipad/FoxTrainingCore) and [journal storage](apps/ipad/FoxJournalCore) have independently testable boundaries.
- **Preserve observations.** Automatic counts, user corrections and unobservable return phases have different meanings. See the [motion strategy and evidence design](docs/fitness/VISION_STRATEGY_AND_EVIDENCE_V1.zh-CN.md).
- **Test the journey as well as the units.** The public source includes [save-and-relaunch journal tests](apps/ipad/FoxUITests/FoxJournalUITests.swift) and a [training-confirmation persistence story](apps/ipad/FoxUITests/FoxNativeUITests.swift).
- **Design for investigation.** Exercise-specific replay and preserved recordings support diagnosis when real-world tracking fails, rather than hiding the failure behind a corrected total.

Created by Yifang Li with AI coding agents. Yifang leads product direction, interface iteration, storage-contract design, verification and device-delivery coordination. Fox is an actively developed prototype.

## Explore the work

- **Product workflows:** local records, photos, correction and backup; editable training plans, timers and feedback.
- **Implementation:** [native interfaces](apps/ipad/FoxNative), [training core](apps/ipad/FoxTrainingCore), [record storage](apps/ipad/FoxJournalCore).
- **Engineering decisions:** [UI design](docs/design/UI_INTENT_AND_REVIEW.zh-CN.md), [storage design](docs/journal/RECORD_STORAGE_V1.zh-CN.md), [architecture](docs/architecture.md).
- **Build and verify:** [verification guide](docs/development/VERIFICATION.md). Native builds require macOS and Xcode; public web checks have a separate Linux path.

For source versions, experimental vision support and test results, see [evidence and verification status](docs/showcase/README.md#evidence-and-provenance). Private records and media remain outside the repository.

[中文说明与开发入口](#中文说明) · [MIT License](LICENSE)

---

## 中文说明


**把日常留下，把训练做好。**

本地优先的个人生活助手。原生 iPhone / iPad 记录文字与照片，也主持训练、计数、节奏引导与事后核对。私人资料留在设备和本地目录，公开仓库提供源码、契约与合成测试。

## 先看这里

| 你想做什么 | 入口 |
| --- | --- |
| 了解现在真正做到了什么 | [当前状态与证据边界](docs/development/CURRENT.md) |
| 开发或让 Agent 接手 | [AGENTS](AGENTS.md) · [模块地图](docs/development/MODULES.md) |
| 重建、测试、准备交付 | [验证指南](docs/development/VERIFICATION.md) |
| 了解产品下一步 | [任务台账](docs/planning/LIFE_LOG_BACKLOG.zh-CN.md) |

## 当前能力

- **记录**：文字、相机和照片导入，近期记录、详情、更正与本地完整备份。
- **训练**：可编辑草稿、组次、倒计时、反馈、人工核对和确认记录。
- **视觉**：侧身弯举、正面侧平举与背面高位下拉的有限适配。准备、计数、恢复和返回阶段分开处理，不填补不可观察的时长。
- **引导**：确定性语音/视觉节奏策略；延迟、取消和过期提示有测试。真实运动听感仍需自然试用。
- **Fox Say**：独立语音实验入口，Web/API 与人工确认草稿。不是 Fox 主应用的联网依赖。

**回放通过不等于任意现场可用。** 以下开发入口描述公开 main 的历史基线，不代表最新装机状态。后续试用已推进到 iPad 48；本次仅发布展示文档，不同步产品分支、不更新设备，也不把后续试用能力写成 main 已具备。上方截图为 11 月 9 日的原生合成演示，来源与限制见[展示说明](docs/showcase/README.md)。

## 开发起步

Node 22；原生验证另需 macOS、Python 3.12、Xcode 26.3 / 17C529、XcodeGen 2.45.x 和 iOS 模拟器。

```sh
npm run bootstrap
npm run doctor
npm run verify:fast
npm run verify:public
```

Linux 可运行 `npm run verify:public -- --component web`。私人回归与旧 `test:trial` 入口均要求显式输入清单，缺失不会变成绿色跳过。模拟器不需要 Apple 开发者账号。

## 仓库结构

```text
apps/ipad/           原生 Fox、Fox Say、训练/记录核心、原生测试
apps/api/            Web 与语音实验 API
apps/web-runtime/    Web 训练与 Fox Say 实验界面
packages/            Web 领域逻辑和 schema 导出
schemas/             记录、备份、运动策略与证据契约
scripts/             现有构建、实验和分层验收工具
tests/               浏览器、脚本与测试分类
docs/                当前入口、设计、历史实验和任务台账
```

## 设计依据

[训练策略与运行档案](docs/fitness/VISION_STRATEGY_AND_EVIDENCE_V1.zh-CN.md) · [记录存储](docs/journal/RECORD_STORAGE_V1.zh-CN.md) · [原生 UI 约束](docs/design/UI_INTENT_AND_REVIEW.zh-CN.md) · [系统架构](docs/architecture.md)

项目代码使用 [MIT License](LICENSE)。私人媒体、个人档案、设备回执与未获再分发授权的第三方原稿不属于公开仓库内容。
