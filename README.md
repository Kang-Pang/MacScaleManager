# MacScaleManager

一个原生 macOS 菜单栏工具。它不改变显示器分辨率、不模拟 HiDPI，而是按工作场景调整应用配置、界面缩放和字体大小，改善普通 2K/非 Retina 外接显示器上的可读性。

## 模式

- **Desktop Mode**：面向外接显示器，使用适合约 125% 观感的字体、浏览器缩放和 Dock 尺寸。
- **Laptop Mode**：恢复笔记本内置屏的默认配置。
- **Custom Mode**：在设置页保存自定义比例。

## 支持范围

### 持久配置

- VS Code：编辑器字体、集成终端字体、窗口 UI 缩放
- Google Chrome、Microsoft Edge：每个 Chromium Profile 的默认页面缩放
- Zotero、Notion、Claude、Codex：已支持的 Electron 偏好配置（实验性）
- Dock 图标大小、鼠标指针大小（可选）

涉及配置文件的应用应在切换模式前完全退出，避免应用退出时覆盖文件。

### 即时模式

即时模式会将选中的运行中应用置前，并模拟缩放快捷键。支持 QQ、微信、Codex、Claude、Notion，也可在设置中添加自定义应用。

- 每个内置应用可选择 Desktop Mode 发送 `⌘+` 的次数（1–6 次）
- Terminal 使用即时快捷键：Desktop Mode `⌘+`，Laptop Mode `⌘0`；未运行时自动跳过
- 自定义应用可填写名称、Bundle ID、Desktop Mode 放大次数，以及 Laptop Mode 使用 `⌘0` 重置或 `⌘-` 缩小
- 首次使用需要在“系统设置 → 隐私与安全性 → 辅助功能”中授权 MacScaleManager

## 显示器操作

在已连接外接显示器时，可以手动关闭或重新启用内置显示器；全局快捷键 `⌃⌥I` 可立即启用内置屏。此功能不改分辨率或 HiDPI，但依赖 macOS 的非公开显示器控制接口，系统版本升级后可能受影响。

## 构建

要求 macOS 14+ 和 Swift 6 / Xcode。

```sh
swift build -c release
```

开发运行：

```sh
swift run MacScaleManager
```

项目包含 `Resources/Info.plist` 和 LaunchAgent 模板。若将程序打包为 `.app` 并更新了签名，macOS 可能要求重新确认辅助功能权限。

## 设计边界

本项目刻意不实现 HiDPI/Retina 模拟、显示器分辨率或 WindowServer 修改、全局 DPI 替换。目标是以低后台开销提供可切换的应用级工作环境缩放。

## 隐私

所有设置保存在本机。即时模式仅在用户启用并授予辅助功能权限后发送键盘快捷键；项目不收集或上传使用数据。
