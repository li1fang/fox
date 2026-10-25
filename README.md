# fox

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

**回放通过不等于任意现场可用。** 已安装的 0.6.8/build 25 试用候选与本次开发分支分开记录；本轮不更新设备。AI 分析、双设备同步、深度与跨平台尚未启动。

## 开发起步

Node 22；本地原生验证另需 macOS、Python 3.12、Xcode 27.1 / 27A9275、XcodeGen 2.45.x 和通用 iOS 27.0 模拟器。Duo 专用 iOS 27.1 不能替代通用运行时；CI 保留显式旧版兼容通道，详见[验证说明](docs/development/VERIFICATION.md)。

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
