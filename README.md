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

**回放通过不等于任意现场可用。** 已安装试用候选与开发分支分开记录，版本与验证边界以[当前状态](docs/development/CURRENT.md)为准。AI 分析、双设备同步、深度与跨平台尚未启动。

## 开发起步

Node 22；本地原生验证另需 macOS、Python 3.12、Xcode 27.1 / 27A9275、XcodeGen 2.45.x 和通用 iOS 27.0 模拟器。Duo 专用 iOS 27.1 不能替代通用运行时；CI 保留显式旧版兼容通道，详见[验证说明](docs/development/VERIFICATION.md)。

```sh
npm run bootstrap
npm run doctor
npm run verify:fast
npm run verify:public
```

Linux 可运行 `npm run verify:public -- --component web`。私人回归与旧 `test:trial` 入口均要求显式输入清单，缺失不会变成绿色跳过。模拟器不需要 Apple 开发者账号。

### Web / Fox Say 的本地边界

`npm run dev:api` 默认仅监听 `127.0.0.1:4177`；日志显示实际绑定地址和端口。
跨设备实验使用现有 `npm run dev:lan` 或 iPad LAN 入口，它们显式设置
`FOX_API_HOST=0.0.0.0`。这仍是无身份认证的可信局域网实验服务，不应暴露到公网或不可信网络。
本包不改变原生 Fox 的离线训练与记录，也不改变 Web 开发服务器自身的监听配置。

API 接受本机地址、显式绑定主机及 LAN 模式下连接的本机地址；自定义 LAN 名称需配置
`FOX_LAN_HOST`。浏览器 Origin 只允许这些主机的 API 端口或 `FOX_WEB_PORT`（默认 5177），
预检保留 `content-type`、`x-fox-say-source`。原生上传、ASR 和 Mac bridge 无 Origin 请求仍兼容；
来源检查不是身份认证，反向代理或其他域名/端口不在默认开放范围。

JSON 请求按实际 UTF-8 字节限制为 1 MiB，超限返回 413；坏 JSON、非对象请求和无效 profile
返回 400。二进制音频保留原 12 MiB 限额。Profile 检查既有字段类型、嵌套结构、枚举和有限数值，
拒绝未知字段；它不是医学合理性判断，不迁移或改写已有数据库记录。

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
