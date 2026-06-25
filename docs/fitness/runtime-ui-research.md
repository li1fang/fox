# 训练运行界面调研

## 问题

fox 的健身第一版需要一个训练运行界面。

它必须满足：

- 美观。
- 容易由 AI 辅助开发。
- 支持点击或触控。
- 支持节奏动画。
- 支持可视化倒计时。
- 支持当前动作、当前组、今日主训练进度。
- 未来能平滑迁移到 iPad。

这说明它不是传统意义上的命令行工具，而是训练中的实时操作面。

## 候选方案

### 传统终端 TUI

可选技术：

- Textual
- Bubble Tea
- Ink

优点：

- 启动快。
- 适合本地原型。
- 与终端开发体验贴近。
- Textual、Bubble Tea 和 Ink 都有成熟生态。

缺点：

- 点击和触控不是核心体验。
- 动画能力受终端限制。
- 圆环、节奏方块、视觉反馈会被限制。
- 未来迁移到 iPad 需要重写界面。

结论：适合调试和开发者工具，不适合作为 fox 第一训练运行界面。

### 本地 Web Runtime UI

可选技术：

- Vite
- React
- TypeScript
- CSS animation / Web Animations API
- requestAnimationFrame
- 本地 API 或 WebSocket

优点：

- 美观上限高。
- 触控和点击天然支持。
- 圆环、进度条、节奏方块、震动效果容易实现。
- 可直接在 iPad Safari 或 PWA 中验证体验。
- AI 辅助开发 React/TypeScript 组件更顺。
- 后续迁移到 iPad App 或 WebView 成本低。

缺点：

- 比终端 TUI 多一层前端工程。
- 需要处理屏幕常亮、后台计时和可见性变化。
- 需要避免把 UI 状态和训练状态机搅在一起。

结论：最符合当前需求。

### 原生 iPad App

可选技术：

- SwiftUI
- React Native / Expo

优点：

- 原生体验最好。
- 触控、音频、传感器、后台能力更完整。

缺点：

- 第一阶段开发成本高。
- 会提前进入移动端工程细节。
- 不适合快速验证训练主持流程。

结论：后续阶段再做。

## 当前决策

第一版采用 **本地 Web Runtime UI**。

它不是普通网站，而是本地运行的训练控制台：

- 浏览器打开。
- 后台服务提供训练状态和事件接口。
- UI 只发送用户动作事件。
- 训练状态机仍在核心程序中。

## 技术原则

### 计时器不依赖动画帧

倒计时显示可以用 `requestAnimationFrame` 平滑刷新，但剩余时间必须根据真实时间戳计算。

这样即使页面掉帧，倒计时仍然准确。

### 训练中请求屏幕常亮

Web 版本应尝试使用 Screen Wake Lock。

如果浏览器不支持或用户拒绝，则显示提示，让用户手动保持屏幕常亮。

### 处理页面可见性变化

浏览器后台页面可能被节流或挂起。

页面重新可见时，UI 必须向后台状态机重新同步当前训练状态，而不是相信本地动画状态。

### 可访问进度

进度环和进度条应同时提供文本和 ARIA progressbar 信息。

## 参考资料

- Vite: https://vite.dev/guide/
- Textual: https://textual.textualize.io/
- Bubble Tea: https://github.com/charmbracelet/bubbletea
- Ink: https://github.com/vadimdemedes/ink
- MDN requestAnimationFrame: https://developer.mozilla.org/en-US/docs/Web/API/Window/requestAnimationFrame
- MDN Web Animations API: https://developer.mozilla.org/en-US/docs/Web/API/Web_Animations_API
- MDN Screen Wake Lock API: https://developer.mozilla.org/en-US/docs/Web/API/Screen_Wake_Lock_API
- MDN Page Visibility API: https://developer.mozilla.org/en-US/docs/Web/API/Page_Visibility_API
- MDN ARIA progressbar: https://developer.mozilla.org/en-US/docs/Web/Accessibility/ARIA/Reference/Roles/progressbar_role
- Apple Human Interface Guidelines: https://developer.apple.com/design/human-interface-guidelines

