# 自动化流水线

fox 当前有两条测试流水线：

1. 桌面浏览器训练流程自动化。
2. 本地 iPad 真机安装与启动 smoke test。

## 基础验证

```bash
npm run verify
```

这会依次运行：

- TypeScript typecheck
- 单元与 API 测试
- production build

## Playwright 训练流程

```bash
npm run test:e2e
```

Playwright 使用独立端口和独立 SQLite：

- API: `http://127.0.0.1:4187`
- Web: `http://127.0.0.1:5187`
- DB: `.tmp/playwright.sqlite`

测试会从首页开始，生成计划草稿，接受计划，完成全部训练组，确认总结，并断言进入 confirmed 状态。

## LAN 开发

```bash
npm run dev:lan
```

默认使用本机检测到的局域网 IPv4 地址。也可以手动指定：

```bash
FOX_LAN_HOST=192.168.1.20 npm run dev:lan
```

## iPad 真机链路

第一版 iPad App 是 WKWebView 壳，加载 Mac 局域网中的 fox Web Runtime。

检查环境：

```bash
npm run ipad:doctor
```

生成 Xcode 工程：

```bash
npm run ipad:generate
```

构建、安装、打开：

```bash
npm run ipad:build
npm run ipad:install
npm run ipad:open
```

完整 smoke test：

```bash
npm run ipad:smoke
```

首次安装后，如果 `ipad:open` 报告 development profile 未被信任，需要在 iPad 上打开 Settings > General > VPN & Device Management，信任 Apple Development profile，然后重新运行：

```bash
npm run ipad:open
```

脚本默认选择唯一 paired iPad。若有多台设备，使用：

```bash
FOX_IOS_DEVICE=<device-id-or-name> npm run ipad:smoke
```

脚本不会修改全局 `xcode-select`，而是固定使用：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## CI

GitHub Actions 只运行云端可执行的流水线：

- `npm ci`
- `npm run verify`
- `npx playwright install --with-deps chromium`
- `npm run test:e2e`

iPad 真机安装与启动不进入 GitHub CI，因为云端 runner 无法访问本地 iPad。
