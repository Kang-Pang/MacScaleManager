# MacScaleManager

一个原生 macOS 菜单栏工具：在不改变分辨率、不模拟 HiDPI 的前提下，按使用场景调整应用级缩放与少量可选系统外观设置。

## 功能

- Desktop、Laptop 与 Custom 三种场景模式
- VS Code 的编辑器字体、集成终端字体与 UI 缩放
- Chrome、Edge 各 Profile 的默认页面缩放
- 可选的 Dock 图标大小和鼠标指针大小
- 即时快捷键缩放：对已打开的 QQ、微信、Codex、Claude、Notion 与 Terminal 发送 `⌘+`、`⌘-` 或 `⌘0`
- 每个即时应用可分别设置 Desktop 的放大次数和 Laptop 的恢复方式；自定义应用支持从已安装应用列表选择 Bundle ID
- 内置显示器开关与 `Control–Option–I` 重新启用快捷键
- 仅在打开设置或点击刷新时扫描已安装应用；没有常驻扫描或轮询

## 即时模式

即时模式需要在 macOS「系统设置 → 隐私与安全性 → 辅助功能」中授予 MacScaleManager 权限。它只操作当前已经打开的目标应用，不会为了缩放而启动应用；执行时会短暂切换到对应窗口。

不同应用是否支持这些快捷键取决于应用本身。没有公开设置接口的应用（如微信、QQ）通常只能使用即时模式。

## 构建

需要完整 Xcode：

```sh
swift build -c release
```

可执行文件位于 `.build/release/MacScaleManager`。将其放入标准 `.app` 包后可使用 LaunchAgent 作为登录项启动。

## 说明与限制

Safari、Finder 与系统文字大小没有可靠的受支持按场景 API。本项目不修改显示器分辨率、不模拟 HiDPI，也不修改 WindowServer。

对 Chrome、Edge、VS Code 等配置文件的调整会先保存原始值；恢复默认模式时会写回原有配置。切换这些配置时，建议先退出对应应用，避免应用退出时覆盖文件。
