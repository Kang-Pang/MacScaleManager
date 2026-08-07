import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: ScaleManager
    @ObservedObject private var preferences: ManagedPreferences
    @State private var editingProfileMode: ScaleMode = .desktop
    @State private var customAppName = ""
    @State private var customBundleID = ""
    @State private var customZoomSteps = 2
    @State private var customLaptopAction: CustomLaptopAction = .reset
    @State private var installedApplications: [InstalledApplication]
    @State private var selectedInstalledBundleID = ""

    init(manager: ScaleManager) {
        self.manager = manager
        _preferences = ObservedObject(wrappedValue: manager.preferences)
        _installedApplications = State(initialValue: SettingsView.discoverInstalledApplications())
    }

    var body: some View {
        Form {
            Section("配置文件模式（需退出目标应用）") {
                Picker("正在编辑", selection: $editingProfileMode) {
                    Text("Desktop Mode 参数").tag(ScaleMode.desktop)
                    Text("Custom Mode 参数").tag(ScaleMode.custom)
                }
                Text("当前修改：\(editingProfileMode.title)。Laptop Mode 会恢复切换前保存的默认值，不覆盖它。")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("VS Code") {
                    Toggle("启用 settings.json 缩放", isOn: $preferences.manageVSCode)
                    Stepper("编辑器字体：\(Int(editingProfile.wrappedValue.editorFontSize)) pt", value: editingProfile.editorFontSize, in: 10...32, step: 1)
                    Stepper("终端字体：\(Int(editingProfile.wrappedValue.terminalFontSize)) pt", value: editingProfile.terminalFontSize, in: 10...32, step: 1)
                    Stepper("UI 缩放：\(editingProfile.wrappedValue.vscodeZoom)", value: editingProfile.vscodeZoom, in: -2...5)
                }
                DisclosureGroup("Google Chrome") {
                    Toggle("启用 Profile 默认页面缩放", isOn: $preferences.manageChrome)
                    Stepper("页面缩放：\(editingProfile.wrappedValue.browserZoomPercent)%", value: editingProfile.browserZoomPercent, in: 80...200, step: 5)
                    Text("Chrome 必须完全退出后再切换。") .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Microsoft Edge") {
                    Toggle("启用 Profile 默认页面缩放", isOn: $preferences.manageEdge)
                    Stepper("页面缩放：\(editingProfile.wrappedValue.browserZoomPercent)%", value: editingProfile.browserZoomPercent, in: 80...200, step: 5)
                    Text("Edge 运行时请关闭此项，改用自定义即时应用。") .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Zotero") {
                    Toggle("启用 UI 缩放（实验性）", isOn: $preferences.manageZotero)
                    Stepper("UI 缩放：\(editingProfile.wrappedValue.browserZoomPercent)%", value: editingProfile.browserZoomPercent, in: 80...200, step: 5)
                }
                DisclosureGroup("Notion") {
                    Toggle("启用 UI 缩放（实验性）", isOn: $preferences.manageNotion)
                    Stepper("UI 缩放：\(editingProfile.wrappedValue.browserZoomPercent)%", value: editingProfile.browserZoomPercent, in: 80...200, step: 5)
                }
                DisclosureGroup("Claude") {
                    Toggle("启用 UI 缩放（实验性）", isOn: $preferences.manageClaude)
                    Stepper("UI 缩放：\(editingProfile.wrappedValue.browserZoomPercent)%", value: editingProfile.browserZoomPercent, in: 80...200, step: 5)
                }
                DisclosureGroup("Codex") {
                    Toggle("启用 UI 缩放（实验性）", isOn: $preferences.manageCodex)
                    Stepper("UI 缩放：\(editingProfile.wrappedValue.browserZoomPercent)%", value: editingProfile.browserZoomPercent, in: 80...200, step: 5)
                }
                DisclosureGroup("Terminal.app") {
                    Toggle("修改默认字体（实验性）", isOn: $preferences.manageTerminal)
                    Stepper("默认字体：\(Int(editingProfile.wrappedValue.terminalFontSize)) pt", value: editingProfile.terminalFontSize, in: 10...32, step: 1)
                }
            }
            Section("系统外观") {
                DisclosureGroup("Dock") {
                    Toggle("调整 Dock 图标大小", isOn: $preferences.manageDock)
                    Stepper("图标大小：\(editingProfile.wrappedValue.dockSize) px", value: editingProfile.dockSize, in: 32...96, step: 2)
                }
                DisclosureGroup("鼠标指针") {
                    Toggle("调整鼠标指针大小", isOn: $preferences.manageCursor)
                    Stepper("指针大小：\(editingProfile.wrappedValue.cursorSize, specifier: "%.2f")×", value: editingProfile.cursorSize, in: 1...4, step: 0.05)
                }
            }
            Section("即时模式（会短暂切换前台窗口）") {
                Toggle("启用即时快捷键缩放", isOn: $manager.preferences.immediateMode)
                ForEach(ImmediateTarget.allCases) { target in
                    DisclosureGroup(target.title) {
                        Toggle("启用即时缩放", isOn: Binding(get: { manager.preferences.isImmediateEnabled(target) }, set: { enabled in manager.preferences.setImmediateEnabled(enabled, for: target) }))
                        Stepper("Desktop Mode：\(manager.preferences.zoomSteps(for: target)) 次 ⌘+", value: Binding(get: { manager.preferences.zoomSteps(for: target) }, set: { count in manager.preferences.setZoomSteps(count, for: target) }), in: 1...6)
                        Picker("Laptop Mode", selection: Binding(get: { manager.preferences.laptopAction(for: target) }, set: { action in manager.preferences.setLaptopAction(action, for: target) })) {
                            ForEach(CustomLaptopAction.allCases) { action in Text(action.title).tag(action) }
                        }
                    }
                }
                Button("请求辅助功能权限") { _ = ImmediateZoomController.requestAccessibilityPermission() }
                Text("Desktop Mode 默认连续发送两次 ⌘+（Codex 三次）；QQ 的 Laptop Mode 连续发送两次 ⌘-，微信及其他目标发送 ⌘0。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义即时应用") {
                DisclosureGroup("添加自定义应用") {
                    Picker("已安装应用", selection: $selectedInstalledBundleID) {
                        Text("选择应用").tag("")
                        ForEach(installedApplications) { app in
                            Text("\(app.name) · \(app.bundleIdentifier)").tag(app.bundleIdentifier)
                        }
                    }
                    .onChange(of: selectedInstalledBundleID) { _, bundleID in
                        guard let app = installedApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return }
                        customAppName = app.name
                        customBundleID = app.bundleIdentifier
                    }
                    Button("刷新已安装应用列表") {
                        installedApplications = SettingsView.discoverInstalledApplications()
                    }
                    TextField("应用名称", text: $customAppName)
                    TextField("Bundle ID", text: $customBundleID)
                    Stepper("Desktop Mode 放大：\(customZoomSteps) 次 ⌘+", value: $customZoomSteps, in: 1...6)
                    Picker("Laptop Mode", selection: $customLaptopAction) {
                        ForEach(CustomLaptopAction.allCases) { action in Text(action.title).tag(action) }
                    }
                    Button("添加自定义应用") {
                        let name = customAppName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let bundleID = customBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty, !bundleID.isEmpty else { return }
                        guard !preferences.customImmediateApps.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
                        preferences.customImmediateApps.append(CustomImmediateApp(name: name, bundleIdentifier: bundleID, desktopZoomSteps: customZoomSteps, laptopAction: customLaptopAction))
                        customAppName = ""
                        customBundleID = ""
                        selectedInstalledBundleID = ""
                    }
                }
                ForEach($preferences.customImmediateApps) { $app in
                    DisclosureGroup(app.name) {
                        Text(app.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        Stepper("Desktop Mode：\(app.desktopZoomSteps) 次 ⌘+", value: $app.desktopZoomSteps, in: 1...6)
                        Picker("Laptop Mode", selection: $app.laptopAction) {
                            ForEach(CustomLaptopAction.allCases) { action in Text(action.title).tag(action) }
                        }
                        Button("移除", role: .destructive) {
                            preferences.customImmediateApps.removeAll { $0.id == app.id }
                        }
                    }
                }
            }
            Section("内置显示器") {
                Button(manager.builtInDisplayStatus.isEnabled ? "关闭内置显示器" : "重新启用内置显示器") {
                    manager.toggleBuiltInDisplay()
                }
                Button("刷新显示器状态") { manager.refreshDisplayStatus() }
                Text("仅在已连接外接显示器时可关闭内屏。此操作不会更改分辨率、缩放或 HiDPI；重新启用时可在这里或菜单栏完成。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("全局快捷键：⌃⌥I（Control–Option–I）立即启用内置屏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = manager.lastError {
                Section {
                    Text(error)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .systemRed))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
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

    private var editingProfile: Binding<ScaleProfile> {
        Binding(
            get: { editingProfileMode == .desktop ? preferences.desktopProfile : preferences.customProfile },
            set: { profile in
                if editingProfileMode == .desktop { preferences.desktopProfile = profile }
                else { preferences.customProfile = profile }
            }
        )
    }

    private static func discoverInstalledApplications() -> [InstalledApplication] {
        let locations = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
        let applications = locations.flatMap { location in
            (try? FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        }
        var seen = Set<String>()
        return applications.compactMap { url in
            guard url.pathExtension == "app", let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier, seen.insert(bundleID).inserted else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return InstalledApplication(name: name, bundleIdentifier: bundleID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

private struct InstalledApplication: Identifiable {
    let name: String
    let bundleIdentifier: String
    var id: String { bundleIdentifier }
}
