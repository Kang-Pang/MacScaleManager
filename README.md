# MacScaleManager

一个原生 macOS 菜单栏工具：在不改变分辨率、不模拟 HiDPI 的前提下，按使用场景调整应用级缩放与少量可选系统外观设置。

## 功能

- Desktop、Laptop 两种场景模式
- VS Code 的编辑器字体、集成终端字体与 UI 缩放
- Chrome、Edge 各 Profile 的默认页面缩放
- 可选的 Dock 图标大小和鼠标指针大小
- 即时快捷键缩放：对已打开的 QQ、微信、Codex、Claude、Notion 与 Terminal 发送 `⌘+`、`⌘-` 或 `⌘0`
- 每个即时应用可分别设置 Desktop 的放大次数和 Laptop 的恢复方式；自定义应用支持从已安装应用列表选择 Bundle ID
- 内置显示器开关与 `Control–Option–I` 重新启用快捷键
- 按应用窗口和 Dock 所在屏幕自动缩放，可分别关闭
- 仅在打开设置时扫描已安装应用；屏幕跟随启用时使用一个低频计时器，关闭后停止

## 双屏自动缩放

Settings 顶部的「按屏幕自动缩放」提供两个独立开关。配置保存在 `app-adapters.json`：

```json
"automaticScreenScaling": {
  "applications": true,
  "dock": true,
  "restartConfigurationApplications": true
}
```

- 内置屏使用 `laptopProfile`，外屏使用 `desktopProfile`。Dock 同样使用两份配置中的 `dockSize`（默认 36/56），并遵守 Dock 原有启用开关。
- 根据窗口与屏幕的最大相交面积判断归属；窗口横跨边界无法确认时不调整。鼠标按下不调整，松开并停稳至少 0.5 秒后执行。其他系统设置仍按手动模式，自动跟随不改变窗口大小。
- 即时规则仅对前台应用执行，不激活后台应用；后台/其他空间的窗口等激活可见后处理。新启动应用保留规则中的启动等待时间。支持 `⌘0` 的规则先复位，重复轮询不重复缩放。
- QQ 等不支持复位的规则记录每个进程实际发送的次数，回到内屏发送相同次数的反向快捷键。首次遇到已运行且基准未知的相对规则，不自动叠加；先恢复默认并手动同步一次，或重启目标应用。若中途焦点改变则停止；相对规则被打断后需重启目标应用。
- 配置规则只在所在屏幕模式/参数变化时写入。开启「换屏时允许配置文件应用正常重启」后，需退出的前台应用先在窗口所在屏幕弹出确认框，选择「重启并调整缩放」后才请求正常退出，确认退出再写配置并重新打开。选择「暂不调整」或关闭提示后不修改、不重复弹窗；换到另一模式屏幕后或使用「只调整当前应用字体/缩放」可重试。按回车默认取消，避免提示出现时误确认。确认时会重新检查屏幕和规则；拔掉显示器或移动窗口后不会沿用过时的退出请求。取消退出或 45 秒超时则不写入、不强制退出，也不连续重试。后台应用激活后再处理。关闭该选项后只显示等待。已有即时规则优先，避免配置与快捷键同时作用。
- Chrome/Edge 默认走配置与重启，不使用页面快捷键；已有配置符合目标值时不重启。写入各 Profile 的全局默认缩放及已有站点缩放记录，使缩放不局限于当前标签页。网站自身布局及浏览器工具栏 UI 并不是 macOS DPI 缩放。
- 重开后尝试恢复原屏幕上的窗口位置，不额外改变窗口大小；原生全屏仍由应用自己恢复。应用是否恢复所有标签页、登录和窗口取决于它的退出/启动设置；请按需启用浏览器的恢复会话选项。
- Dock 按自身的可见交互窗口识别宿主屏幕，不按鼠标位置猜测。实时大小依赖动态加载的私有 CoreDock 接口；系统升级后需要复测。位置不明确或接口失效时保持原大小，不反复重启 Dock。
- 关闭两个开关后回到原来的手动模式。启用时每 0.5 秒采样一次（允许系统合并唤醒），只有屏幕/参数变化才写配置或发快捷键，不扫描应用安装目录、不持续写日志。

## 窗口布局与台前调度

在 Settings → 窗口布局中展开应用，选择「填满屏幕，左侧留空」。默认留出该屏幕宽度的 10%，比例可在 0–40% 之间修改；窗口填满剩余可用区域，保留菜单栏和 Dock。选择「按比例居中」可使用原来的窗口大小设置。

规则保存在 `config/app-adapters.json` 的 `windowLayoutAdapters` 中：

```json
{
  "bundleIdentifier": "com.example.app",
  "enabled": true,
  "name": "Example",
  "windowSizePercent": 75,
  "layoutStyle": "fillWithLeftGap",
  "leftGapPercent": 10
}
```

旧规则缺少 `layoutStyle` 时使用 `centered`，缺少 `leftGapPercent` 时使用 10%。模式切换会同步已运行应用；新启动应用不自动调整。批量同步保留原生全屏；「测试窗口布局」或「只调整当前应用窗口」可退出原生全屏后应用布局。普通填充屏幕窗口可直接切换到左侧留空布局。

菜单中的前台操作已拆分：

- 「只调整当前应用窗口」只应用窗口比例或左侧留空规则，无规则时使用 75% 居中，不发送缩放快捷键、不写字体配置。
- 「只调整当前应用字体/缩放」只应用即时或配置文件缩放规则，不触发窗口布局、也不主动退出原生全屏。自动跟随开启时按所在屏幕选择参数，关闭时按手动模式。配置文件规则不依赖即时模式开关；需要重启的规则仍先弹出确认窗，重开时仅尝试恢复原窗口位置。

运行 `./scripts/regression-check.sh` 可检查配置、构建源码并验证多显示器窗口布局计算。

## 即时模式

即时模式需要在 macOS「系统设置 → 隐私与安全性 → 辅助功能」中授予 MacScaleManager 权限。它只操作当前已经打开的目标应用，不会为了缩放而启动应用；执行时会短暂切换到对应窗口。

不同应用是否支持这些快捷键取决于应用本身。没有公开设置接口的应用（如微信、QQ）通常只能使用即时模式。

## 配置写入前是否退出应用

在配置文件模式下展开应用，可设置「切换时自动退出应用」。开启时，运行中的应用会出现在切换预检中；选择「关闭并切换」后请求正常退出，确认退出再写入。关闭时直接写入配置。VS Code 默认关闭，字体和 UI 设置可在运行中更新；Chrome、Edge 等默认开启，以免内存中的配置覆盖文件。手动关闭浏览器的退出检查后，更改可能需要重启才生效或被覆盖。

设置保存在 `app-adapters.json` 的 `managedApplicationRequiresQuit` 中，使用与 `managedApplications` 相同的应用键，例如 `"vscode": false`、`"edge": true`。扩展 JSON 应用使用各自规则中的 `requiresQuit` 字段，也可在设置中修改。

## 构建

需要完整 Xcode：

```sh
swift build -c release \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
  -Xlinker "$PWD/Resources/Info.plist"
mkdir -p outputs/MacScaleManager.app/Contents/MacOS outputs/config
cp .build/release/MacScaleManager outputs/MacScaleManager.app/Contents/MacOS/
cp Resources/Info.plist outputs/MacScaleManager.app/Contents/
cp config/app-adapters.json outputs/config/
codesign --force --sign - --identifier MacScaleManager outputs/MacScaleManager.app
codesign --verify --deep --strict outputs/MacScaleManager.app
```

生成的 App 和旁边的 `config` 目录需一起移动到正式运行目录；App 从自身所在目录读取 `config/app-adapters.json`，不依赖源代码目录。更新已有安装时保留正式目录的配置，不要用构建示例覆盖自己的规则。源码运行使用 `~/Applications/MacScaleManager/source/config/app-adapters.json`，两份配置独立。

可使用 `Resources/com.natsume.macscalemanager.plist` 作为 LaunchAgent 模板，安装前按实际位置修改其中的绝对路径。开发与正式运行应只启动一个实例，避免重复快捷键和缩放。当前为本地临时签名，跨电脑分发可能需要在系统设置中批准打开并重新授予辅助功能权限。

## 说明与限制

Safari、Finder 与系统文字大小没有可靠的受支持按场景 API。本项目不修改显示器分辨率、不模拟 HiDPI，也不修改 WindowServer。

对 Chrome、Edge、VS Code 等配置文件的调整会先保存原始值；Laptop Mode 使用配置文件中保存的 Laptop 参数。需要退出的应用会先确认退出，避免应用退出时覆盖刚写入的文件。
