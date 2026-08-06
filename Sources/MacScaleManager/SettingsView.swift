import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: ScaleManager
    @State private var custom: ScaleProfile
    @State private var customAppName = ""
    @State private var customBundleID = ""
    @State private var customZoomSteps = 2
    @State private var customLaptopAction: CustomLaptopAction = .reset

    init(manager: ScaleManager) {
        self.manager = manager
        _custom = State(initialValue: manager.preferences.customProfile)
    }

    var body: some View {
        Form {
            Section("Managed targets") {
                Toggle("VS Code", isOn: $manager.preferences.manageVSCode)
                Toggle("Terminal.app 默认字体", isOn: $manager.preferences.manageTerminal)
                Toggle("Google Chrome", isOn: $manager.preferences.manageChrome)
                Toggle("Microsoft Edge", isOn: $manager.preferences.manageEdge)
                Toggle("Dock icon size", isOn: $manager.preferences.manageDock)
                Toggle("Mouse pointer size", isOn: $manager.preferences.manageCursor)
                Toggle("Zotero UI scale", isOn: $manager.preferences.manageZotero)
                Toggle("Notion UI scale（实验性）", isOn: $manager.preferences.manageNotion)
                Toggle("Claude UI scale（实验性）", isOn: $manager.preferences.manageClaude)
                Toggle("Codex UI scale（实验性）", isOn: $manager.preferences.manageCodex)
                Text("关闭正在管理的应用后再切换，避免应用退出时覆盖设置。Safari 与 Finder 不提供可靠的公开缩放接口，因此不会被修改。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("即时模式（会短暂切换前台窗口）") {
                Toggle("启用即时快捷键缩放", isOn: $manager.preferences.immediateMode)
                Toggle("QQ", isOn: $manager.preferences.immediateQQ)
                Toggle("微信", isOn: $manager.preferences.immediateWeChat)
                Toggle("Codex", isOn: $manager.preferences.immediateCodex)
                Toggle("Claude", isOn: $manager.preferences.immediateClaude)
                Toggle("Notion", isOn: $manager.preferences.immediateNotion)
                Toggle("Terminal", isOn: $manager.preferences.immediateTerminal)
                ForEach(ImmediateTarget.allCases) { target in
                    Stepper("\(target.title) Desktop Mode：\(manager.preferences.zoomSteps(for: target)) 次 ⌘+", value: Binding(get: { manager.preferences.zoomSteps(for: target) }, set: { manager.preferences.setZoomSteps($0, for: target) }), in: 1...6)
                }
                Button("请求辅助功能权限") { _ = ImmediateZoomController.requestAccessibilityPermission() }
                Text("Desktop Mode 默认连续发送两次 ⌘+（Codex 三次）；QQ 的 Laptop Mode 连续发送两次 ⌘-，微信及其他目标发送 ⌘0。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义即时应用") {
                TextField("应用名称，例如 Discord", text: $customAppName)
                TextField("Bundle ID，例如 com.hnc.Discord", text: $customBundleID)
                Stepper("Desktop Mode 放大：\(customZoomSteps) 次 ⌘+", value: $customZoomSteps, in: 1...6)
                Picker("Laptop Mode", selection: $customLaptopAction) {
                    ForEach(CustomLaptopAction.allCases) { action in Text(action.title).tag(action) }
                }
                Button("添加自定义应用") {
                    let name = customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let bundleID = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty, !bundleID.isEmpty else { return }
                    manager.preferences.customImmediateApps.append(CustomImmediateApp(name: name, bundleIdentifier: bundleID, desktopZoomSteps: customZoomSteps, laptopAction: customLaptopAction))
                    customAppName = ""
                    customBundleID = ""
                }
                ForEach(manager.preferences.customImmediateApps) { app in
                    HStack { Text("\(app.name) · \(app.bundleIdentifier)").lineLimit(1)
                        Spacer()
                        Button("移除", role: .destructive) { manager.preferences.customImmediateApps.removeAll { $0.id == app.id } }
                    }
                    .font(.caption)
                }
            }
            Section("内置显示器") {
                Button(manager.builtInDisplayStatus.isEnabled ? "关闭内置显示器" : "重新启用内置显示器") {
                    manager.toggleBuiltInDisplay()
                }
                .disabled(manager.builtInDisplayStatus.isEnabled && !manager.builtInDisplayStatus.hasExternalDisplay)
                Button("刷新显示器状态") { manager.refreshDisplayStatus() }
                Text("仅在已连接外接显示器时可关闭内屏。此操作不会更改分辨率、缩放或 HiDPI；重新启用时可在这里或菜单栏完成。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("全局快捷键：⌃⌥I（Control–Option–I）立即启用内置屏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
                        Section("Custom Mode") {
                Stepper("VS Code 编辑器字体：\(Int(custom.editorFontSize)) pt", value: $custom.editorFontSize, in: 10...32, step: 1)
                Stepper("VS Code 终端字体：\(Int(custom.terminalFontSize)) pt", value: $custom.terminalFontSize, in: 10...32, step: 1)
                Stepper("VS Code UI 缩放：\(custom.vscodeZoom)", value: $custom.vscodeZoom, in: -2...5)
                Stepper("浏览器缩放：\(custom.browserZoomPercent)%", value: $custom.browserZoomPercent, in: 80...200, step: 5)
                Stepper("Dock 图标：\(custom.dockSize) px", value: $custom.dockSize, in: 32...96, step: 2)
                Stepper("鼠标指针：\(custom.cursorSize, specifier: "%.2f")×", value: $custom.cursorSize, in: 1...4, step: 0.05)
                Button("Save Custom Profile") { manager.preferences.customProfile = custom }
            }
            if let error = manager.lastError {
                Section { Text(error).foregroundStyle(.red) }
            }
            if let result = manager.lastImmediateResult {
                Section("即时模式结果") { Text(result).font(.caption) }
            }
            if let result = manager.lastDisplayResult {
                Section("显示器操作结果") { Text(result).font(.caption) }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 530, height: 650)
    }
}
