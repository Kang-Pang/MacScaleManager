import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: ScaleManager
    @ObservedObject private var preferences: ManagedPreferences
    @State private var editingProfileMode: ScaleMode
    @State private var customAppName = ""
    @State private var customBundleID = ""
    @State private var customZoomSteps = 2
    @State private var customLaptopAction: CustomLaptopAction = .reset
    @State private var installedApplications: [InstalledApplication]
    @State private var selectedInstalledBundleID = ""

    init(manager: ScaleManager) {
        self.manager = manager
        _preferences = ObservedObject(wrappedValue: manager.preferences)
        _editingProfileMode = State(initialValue: manager.currentMode)
        // Keep the menu-bar process lean: enumerate application bundles only while Settings is visible.
        _installedApplications = State(initialValue: [])
    }

    var body: some View {
        Form {
            Section("配置文件模式（需退出目标应用）") {
                VStack(alignment: .leading, spacing: 5) {
                    Label("配置档案", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Text("应用清单、即时规则及 Desktop/Laptop 参数均来自 app-adapters.json；此处的修改会立即写回文件。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text("默认参考：\(defaultProfileSummary)")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button("重新读取") { preferences.reloadAdapterConfiguration() }
                            Button("校验配置") { preferences.validateAdapterConfiguration() }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Picker("正在编辑", selection: $editingProfileMode) {
                    Text("Desktop Mode 参数").tag(ScaleMode.desktop)
                    Text("Laptop Mode 参数").tag(ScaleMode.laptop)
                }
                .pickerStyle(.segmented)
                Text("当前修改：\(editingProfileMode.title)。切换模式时会应用此处保存的参数。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("恢复 \(editingProfileMode.title) 默认参数") {
                    if editingProfileMode == .desktop { preferences.desktopProfile = .desktop }
                    else { preferences.laptopProfile = .laptop }
                }
                if preferences.configurationItems.isEmpty {
                    Text("配置文件中没有 managedApplications 项。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(preferences.configurationItems) { item in
                    DisclosureGroup {
                        configurationProfileControls(for: item.kind)
                        if item.id == "edge" {
                            Text("Edge 运行时会覆盖配置文件；已打开时请在 immediateAdapters 中启用 Edge。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        HStack {
                            Text(item.title)
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { preferences.isManagedApplicationEnabled(item.id) },
                                set: { preferences.setManagedApplicationEnabled($0, key: item.id) }
                            ))
                            .labelsHidden()
                        }
                    }
                }
            }
            Section("即时模式（会短暂切换前台窗口）") {
                VStack(alignment: .leading, spacing: 3) {
                    Label("快捷键缩放", systemImage: "keyboard")
                        .font(.headline)
                    Text("只会操作已打开的应用；每个条目的参数保存在 immediateAdapters。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Toggle("启用即时快捷键缩放", isOn: $manager.preferences.immediateMode)
                Text("应用列表、次数和恢复方式均来自 app-adapters.json 的 immediateAdapters。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("添加已安装应用", selection: $selectedInstalledBundleID) {
                        Text("选择应用").tag("")
                        ForEach(installedApplications) { app in Text(app.name).tag(app.bundleIdentifier) }
                    }
                    Button("添加") {
                        guard let app = installedApplications.first(where: { $0.bundleIdentifier == selectedInstalledBundleID }) else { return }
                        preferences.addConfiguredImmediateAdapter(name: app.name, bundleIdentifier: app.bundleIdentifier)
                        selectedInstalledBundleID = ""
                    }
                    .disabled(selectedInstalledBundleID.isEmpty)
                }
                if preferences.configuredImmediateAdapters.isEmpty {
                    Text("配置文件中没有 immediateAdapters 项。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(preferences.configuredImmediateAdapters) { adapter in
                    DisclosureGroup {
                        Text(adapter.bundleIdentifier).font(.caption).foregroundStyle(.secondary)
                        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: adapter.bundleIdentifier) == nil {
                            Label("未找到此 Bundle ID 对应的应用，可删除此规则。", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(.orange)
                        }
                        Toggle("Desktop Mode 前先按 ⌘0 复位", isOn: Binding(
                            get: { adapter.shouldResetBeforeDesktop },
                            set: { preferences.setConfiguredImmediateResetBeforeDesktop($0, bundleIdentifier: adapter.bundleIdentifier) }
                        ))
                        Toggle("Desktop Mode 打开后自动同步", isOn: Binding(
                            get: { adapter.shouldApplyOnLaunch },
                            set: { preferences.setConfiguredImmediateApplyOnLaunch($0, bundleIdentifier: adapter.bundleIdentifier) }
                        ))
                        Stepper("快捷键间隔：\(adapter.shortcutInterval, specifier: "%.2f") 秒", value: Binding(
                            get: { adapter.shortcutInterval },
                            set: { preferences.setConfiguredImmediateShortcutInterval($0, bundleIdentifier: adapter.bundleIdentifier) }
                        ), in: 0.1...1, step: 0.05)
                        Stepper("启动后等待：\(adapter.desktopLaunchDelay, specifier: "%.1f") 秒", value: Binding(
                            get: { adapter.desktopLaunchDelay },
                            set: { preferences.setConfiguredImmediateLaunchDelay($0, bundleIdentifier: adapter.bundleIdentifier) }
                        ), in: 0.5...10, step: 0.5)
                        Text("同步状态：\(manager.immediateStatus(for: adapter))").font(.caption).foregroundStyle(.secondary)
                        Stepper("Desktop Mode：\(adapter.desktopZoomSteps ?? 2) 次 ⌘+", value: Binding(
                            get: { adapter.desktopZoomSteps ?? 2 },
                            set: { preferences.setConfiguredImmediateZoomSteps($0, bundleIdentifier: adapter.bundleIdentifier) }
                        ), in: 1...6)
                        Picker("Laptop Mode", selection: Binding(
                            get: { adapter.laptopAction ?? .reset },
                            set: { preferences.setConfiguredImmediateLaptopAction($0, bundleIdentifier: adapter.bundleIdentifier) }
                        )) {
                            ForEach(CustomLaptopAction.allCases) { action in Text(action.title).tag(action) }
                        }
                        Button("测试 Desktop 放大") { manager.testImmediateAdapter(adapter) }
                        Button("恢复 Laptop 大小") { manager.restoreImmediateAdapter(adapter) }
                        Button("删除此应用", role: .destructive) {
                            preferences.deleteConfiguredImmediateAdapter(bundleIdentifier: adapter.bundleIdentifier)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(adapter.name)
                                Text(adapter.summary).font(.caption).foregroundStyle(.secondary)
                            }
                            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: adapter.bundleIdentifier) == nil {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { adapter.isEnabled },
                                set: { preferences.setConfiguredImmediateEnabled($0, bundleIdentifier: adapter.bundleIdentifier) }
                            ))
                            .labelsHidden()
                        }
                    }
                }
                Button("请求辅助功能权限") { _ = ImmediateZoomController.requestAccessibilityPermission() }
                Text("Desktop Mode 默认连续发送两次 ⌘+（Codex 三次）；QQ 的 Laptop Mode 连续发送两次 ⌘-，微信及其他目标发送 ⌘0。")
                    .font(.caption).foregroundStyle(.secondary)
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
            if let error = preferences.adapterConfigurationError {
                Section {
                    Text("配置文件错误：\(error)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .systemRed))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            if let result = preferences.adapterValidationResult {
                Section("配置校验") { Text(result).font(.caption) }
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
        .frame(width: 580, height: 720)
        .onAppear {
            preferences.reloadAdapterConfiguration()
            if installedApplications.isEmpty {
                installedApplications = Self.discoverInstalledApplications()
            }
        }
        .onDisappear {
            selectedInstalledBundleID = ""
            installedApplications.removeAll(keepingCapacity: false)
        }
    }

    private var defaultProfileSummary: String {
        if editingProfileMode == .desktop { return "VS Code 16 / 15 pt · 浏览器 125% · Dock 56 px · 指针 1.35×" }
        return "VS Code 14 / 13 pt · 浏览器 100% · Dock 36 px · 指针 1.00×"
    }

    @ViewBuilder
    private func configurationProfileControls(for kind: ConfigurationParameterKind) -> some View {
        switch kind {
        case .vscode:
            Text("默认参考：编辑器 16 pt · 终端 15 pt · UI +1")
                .font(.caption).foregroundStyle(.secondary)
            Text(preferences.laptopValueSummary(for: kind))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Stepper("编辑器字体：\(Int(editingProfile.wrappedValue.editorFontSize)) pt", value: editingProfile.editorFontSize, in: 10...32, step: 1)
            Stepper("终端字体：\(Int(editingProfile.wrappedValue.terminalFontSize)) pt", value: editingProfile.terminalFontSize, in: 10...32, step: 1)
            Stepper("UI 缩放：\(editingProfile.wrappedValue.vscodeZoom)", value: editingProfile.vscodeZoom, in: -2...5)
        case .browser:
            Text("默认参考：Desktop 125%")
                .font(.caption).foregroundStyle(.secondary)
            Text(preferences.laptopValueSummary(for: kind))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Stepper("页面 / UI 缩放：\(editingProfile.wrappedValue.browserZoomPercent)%", value: editingProfile.browserZoomPercent, in: 80...200, step: 5)
        case .terminal:
            Text("默认参考：15 pt；已打开窗口建议使用即时模式")
                .font(.caption).foregroundStyle(.secondary)
            Text(preferences.laptopValueSummary(for: kind))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Stepper("默认字体：\(Int(editingProfile.wrappedValue.terminalFontSize)) pt", value: editingProfile.terminalFontSize, in: 10...32, step: 1)
        case .dock:
            Text("默认参考：Desktop 56 px")
                .font(.caption).foregroundStyle(.secondary)
            Text(preferences.laptopValueSummary(for: kind))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Stepper("图标大小：\(editingProfile.wrappedValue.dockSize) px", value: editingProfile.dockSize, in: 32...96, step: 2)
        case .cursor:
            Text("默认参考：Desktop 1.35×")
                .font(.caption).foregroundStyle(.secondary)
            Text(preferences.laptopValueSummary(for: kind))
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Stepper("指针大小：\(editingProfile.wrappedValue.cursorSize, specifier: "%.2f")×", value: editingProfile.cursorSize, in: 1...4, step: 0.05)
        case .none:
            Text("此配置项没有预定义的参数控件；请直接编辑 JSON。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var editingProfile: Binding<ScaleProfile> {
        Binding(
            get: { editingProfileMode == .desktop ? preferences.desktopProfile : preferences.laptopProfile },
            set: {
                if editingProfileMode == .desktop { preferences.desktopProfile = $0 }
                else { preferences.laptopProfile = $0 }
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
