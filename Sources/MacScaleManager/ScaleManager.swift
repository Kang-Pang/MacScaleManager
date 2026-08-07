import AppKit
import Foundation

enum ScaleMode: String, CaseIterable, Identifiable {
    case laptop, desktop
    var id: String { rawValue }
    var title: String { switch self { case .laptop: "Laptop Mode"; case .desktop: "Desktop Mode" } }
    var symbolName: String { switch self { case .laptop: "laptopcomputer"; case .desktop: "display" } }
}

struct ScaleProfile: Codable, Equatable {
    var editorFontSize: Double
    var terminalFontSize: Double
    var vscodeZoom: Int
    var browserZoomPercent: Int
    var dockSize: Int
    var cursorSize: Double

    static let desktop = ScaleProfile(editorFontSize: 16, terminalFontSize: 15, vscodeZoom: 1, browserZoomPercent: 125, dockSize: 56, cursorSize: 1.35)
    static let laptop = ScaleProfile(editorFontSize: 14, terminalFontSize: 13, vscodeZoom: 0, browserZoomPercent: 100, dockSize: 36, cursorSize: 1.0)
}

@MainActor
final class ScaleManager: ObservableObject {
    @Published private(set) var currentMode: ScaleMode
    @Published private(set) var lastError: String?
    @Published private(set) var lastFailureGuidance: String?
    @Published private(set) var lastImmediateResult: String?
    @Published private(set) var builtInDisplayStatus: BuiltInDisplayStatus
    @Published private(set) var lastDisplayResult: String?
    @Published private(set) var launchSyncStatus: [String: String] = [:]
    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var preflightProgress: String?
    private var hotKeyController: GlobalHotKeyController?
    private var applicationLaunchObserver: NSObjectProtocol?
    private var applicationTerminationObserver: NSObjectProtocol?
    private var recentDesktopSyncs: [String: Date] = [:]
    private var desktopSyncedBundleIdentifiers: Set<String> = []
    private var settingsWindowController: SettingsWindowController?
    var preferences = ManagedPreferences()

    init() {
        currentMode = ScaleMode(rawValue: UserDefaults.standard.string(forKey: "currentMode") ?? "laptop") ?? .laptop
        lastError = nil
        lastFailureGuidance = nil
        lastImmediateResult = nil
        let initialDisplayStatus = DisplayController.currentStatus()
        builtInDisplayStatus = initialDisplayStatus
        lastDisplayResult = nil
        launchSyncStatus = [:]
        accessibilityTrusted = AXIsProcessTrusted()
        preflightProgress = nil
        hotKeyController = nil
        applicationLaunchObserver = nil
        applicationTerminationObserver = nil
        // Persisting the selected mode also makes a launch after an app update or
        // restart restore the intended workspace configuration.
        do {
            if currentMode == .laptop {
                try preferences.applyLaptopProfile()
                if preferences.managesTerminal { try? preferences.applyTerminalFont(size: profile(for: .laptop).terminalFontSize) }
            } else {
                let blockers = preferences.blockingApplicationsForProfileChange()
                if blockers.isEmpty {
                    try preferences.apply(profile: profile(for: currentMode))
                    if preferences.managesTerminal { try? preferences.applyTerminalFont(size: profile(for: currentMode).terminalFontSize) }
                } else {
                    preflightProgress = "启动预检：\(blockers.map(\.name).joined(separator: "、")) 正在运行；请在菜单中重新选择 Desktop Mode。"
                }
            }
        } catch { lastError = error.localizedDescription }
        hotKeyController = GlobalHotKeyController { [weak self] in
            self?.enableBuiltInDisplay()
        }
        applicationLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.syncDesktopModeAfterLaunch(application) }
        }
        applicationTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = application.bundleIdentifier else { return }
            Task { @MainActor in self?.clearDesktopSyncState(bundleIdentifier: bundleID) }
        }
    }

    func openSettings() {
        if let controller = settingsWindowController {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = SettingsWindowController(manager: self) { [weak self] in
            self?.settingsWindowController = nil
        }
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func syncDesktopModeAfterLaunch(_ application: NSRunningApplication) {
        guard currentMode == .desktop, preferences.immediateMode, let bundleID = application.bundleIdentifier else { return }
        guard let target = try? preferences.configuredDesktopLaunchApp(bundleIdentifier: bundleID) else { return }
        guard !desktopSyncedBundleIdentifiers.contains(bundleID) else {
            launchSyncStatus[bundleID] = "本轮 Desktop Mode 已同步"
            return
        }
        if let lastSync = recentDesktopSyncs[bundleID], Date().timeIntervalSince(lastSync) < 3 { return }
        launchSyncStatus[bundleID] = "等待 \(String(format: "%.1f", target.desktopLaunchDelay)) 秒后同步"
        scheduleDesktopLaunchSync(target: target, bundleID: bundleID, attempt: 0, delay: target.desktopLaunchDelay)
    }

    // Retry only if the app could not be brought forward; repeating a successful shortcut
    // would compound the zoom level.
    private func scheduleDesktopLaunchSync(target: CustomImmediateApp, bundleID: String, attempt: Int, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.currentMode == .desktop else { return }
            self.recentDesktopSyncs[bundleID] = Date()
            self.launchSyncStatus[bundleID] = "正在同步"
            let result = ImmediateZoomController.applyWithResult(mode: self.currentMode, targets: [], customTargets: [target])
            self.lastImmediateResult = "启动后同步：" + result.summary
            if result.changedBundleIdentifiers.contains(bundleID) {
                self.desktopSyncedBundleIdentifiers.insert(bundleID)
                self.launchSyncStatus[bundleID] = "本轮 Desktop Mode 已同步"
            } else {
                self.launchSyncStatus[bundleID] = "同步失败：\(result.summary)"
            }
            if attempt < 2 && result.unavailableNames.contains(where: { $0.contains("无法置前") }) {
                self.scheduleDesktopLaunchSync(target: target, bundleID: bundleID, attempt: attempt + 1, delay: 1.5)
            }
        }
    }

    private func clearDesktopSyncState(bundleIdentifier: String) {
        desktopSyncedBundleIdentifiers.remove(bundleIdentifier)
        recentDesktopSyncs.removeValue(forKey: bundleIdentifier)
        launchSyncStatus.removeValue(forKey: bundleIdentifier)
    }

    func profile(for mode: ScaleMode) -> ScaleProfile {
        return mode == .desktop ? preferences.desktopProfile : preferences.laptopProfile
    }

    func preflightSummary(for mode: ScaleMode) -> String {
        let blockers = preferences.blockingApplicationsForProfileChange()
        return blockers.isEmpty
            ? "\(mode.title) 预检：可直接切换"
            : "\(mode.title) 预检：\(blockers.count) 个应用需先退出"
    }

    func requestApply(_ mode: ScaleMode) {
        let blockers = preferences.blockingApplicationsForProfileChange()
        guard !blockers.isEmpty else {
            apply(mode)
            return
        }
        presentPreflight(mode: mode, blockers: blockers)
    }

    private func presentPreflight(mode: ScaleMode, blockers: [BlockingApplication]) {
        let alert = NSAlert()
        alert.messageText = "\(mode.title) 需要先退出应用"
        alert.informativeText = "以下正在运行的应用会覆盖配置文件：\n\n\(blockers.map(\.name).joined(separator: "、"))\n\n选择“关闭并切换”后，MacScaleManager 会请求它们正常退出；如有未保存内容，应用仍会自行询问是否保存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "关闭并切换")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        alert.window.makeKeyAndOrderFront(nil)
        let response = alert.runModal()
        alert.window.level = .normal
        guard response == .alertFirstButtonReturn else { return }
        close(blockers: blockers, thenApply: mode)
    }

    private func close(blockers: [BlockingApplication], thenApply mode: ScaleMode) {
        blockers.forEach { _ = $0.application.terminate() }
        preflightProgress = "正在等待 \(blockers.map(\.name).joined(separator: "、")) 退出…"
        waitForBlockersToClose(thenApply: mode, deadline: Date().addingTimeInterval(60))
    }

    private func waitForBlockersToClose(thenApply mode: ScaleMode, deadline: Date) {
        let remaining = preferences.blockingApplicationsForProfileChange()
        guard !remaining.isEmpty else {
            preflightProgress = "阻塞应用已退出，正在切换 \(mode.title)…"
            apply(mode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.preflightProgress = nil }
            return
        }
        guard Date() < deadline else {
            preflightProgress = "未切换：\(remaining.map(\.name).joined(separator: "、")) 仍在运行。"
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.waitForBlockersToClose(thenApply: mode, deadline: deadline)
        }
    }

    func apply(_ mode: ScaleMode) {
        do {
            // Laptop Mode is deliberately a restore operation: users' original values
            // are more trustworthy than a guessed macOS/IDE "default".
            if mode == .laptop {
                try preferences.applyLaptopProfile()
                if preferences.managesTerminal { try? preferences.applyTerminalFont(size: profile(for: .laptop).terminalFontSize) }
            } else {
                try preferences.apply(profile: profile(for: mode))
                if preferences.managesTerminal { try? preferences.applyTerminalFont(size: profile(for: mode).terminalFontSize) }
            }
            if preferences.immediateMode && !(mode == .desktop && currentMode == .desktop) {
                let configuredImmediateApps = try preferences.externalImmediateApps()
                let usesManifest = !configuredImmediateApps.isEmpty
                let result = ImmediateZoomController.applyWithResult(
                    mode: mode,
                    targets: usesManifest ? [] : preferences.immediateTargets,
                    customTargets: configuredImmediateApps,
                    zoomSteps: preferences.immediateZoomSteps,
                    laptopActions: preferences.immediateLaptopActions
                )
                lastImmediateResult = result.summary
                if mode == .desktop {
                    desktopSyncedBundleIdentifiers.formUnion(result.changedBundleIdentifiers)
                }
            }
            if preferences.immediateMode && mode == .desktop && currentMode == .desktop {
                lastImmediateResult = "Desktop Mode 已启用：已跳过即时快捷键，避免重复放大。"
            }
            currentMode = mode
            if mode == .laptop {
                desktopSyncedBundleIdentifiers.removeAll()
                recentDesktopSyncs.removeAll()
                launchSyncStatus.removeAll()
            }
            UserDefaults.standard.set(mode.rawValue, forKey: "currentMode")
            lastError = nil
            lastFailureGuidance = nil
        } catch { presentModeFailure(error.localizedDescription, requestedMode: mode) }
    }

    func syncFrontmostImmediateApp() {
        guard preferences.immediateMode else {
            lastImmediateResult = "即时模式未启用。"
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication, let bundleID = app.bundleIdentifier else {
            lastImmediateResult = "无法识别当前前台应用。"
            return
        }
        if currentMode == .desktop && desktopSyncedBundleIdentifiers.contains(bundleID) {
            lastImmediateResult = "\(app.localizedName ?? bundleID) 本轮 Desktop Mode 已同步；已跳过，避免重复放大。"
            return
        }
        do {
            guard let target = try preferences.configuredImmediateApp(bundleIdentifier: bundleID) else {
                lastImmediateResult = "当前前台应用未配置即时缩放。"
                return
            }
            let result = ImmediateZoomController.applyWithResult(mode: currentMode, targets: [], customTargets: [target])
            lastImmediateResult = "前台同步（\(currentMode.title)）：" + result.summary
            if result.changedBundleIdentifiers.contains(bundleID) {
                if currentMode == .desktop {
                    desktopSyncedBundleIdentifiers.insert(bundleID)
                    launchSyncStatus[bundleID] = "本轮 Desktop Mode 已同步"
                } else {
                    clearDesktopSyncState(bundleIdentifier: bundleID)
                }
            } else {
                launchSyncStatus[bundleID] = "同步失败"
            }
        } catch { lastImmediateResult = "前台同步失败：\(error.localizedDescription)" }
    }

    func immediateStatus(for adapter: ExternalImmediateAdapter) -> String {
        guard currentMode == .desktop else { return "等待 Desktop Mode" }
        guard adapter.isEnabled && adapter.shouldApplyOnLaunch else { return "未启用启动同步" }
        if let value = launchSyncStatus[adapter.bundleIdentifier] { return value }
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == adapter.bundleIdentifier }
        return running ? "已运行，等待同步" : "等待启动"
    }

    func restoreImmediateAdapter(_ adapter: ExternalImmediateAdapter) {
        lastImmediateResult = "单应用恢复：" + ImmediateZoomController.apply(mode: .laptop, targets: [], customTargets: [adapter.asImmediateApp()])
    }

    func testImmediateAdapter(_ adapter: ExternalImmediateAdapter) {
        guard adapter.isEnabled else {
            lastImmediateResult = "测试未执行：请先在配置中启用 \(adapter.name)。"
            return
        }
        lastImmediateResult = "测试 Desktop 放大：" + ImmediateZoomController.apply(mode: .desktop, targets: [], customTargets: [adapter.asImmediateApp()])
    }

    func restoreDefaults() {
        do {
            try preferences.applyLaptopProfile()
            if preferences.managesTerminal { try? preferences.applyTerminalFont(size: profile(for: .laptop).terminalFontSize) }
            currentMode = .laptop
            UserDefaults.standard.set(ScaleMode.laptop.rawValue, forKey: "currentMode")
            lastError = nil
            lastFailureGuidance = nil
        } catch { presentModeFailure(error.localizedDescription, requestedMode: .laptop) }
    }

    private func presentModeFailure(_ message: String, requestedMode: ScaleMode) {
        lastError = message
        lastFailureGuidance = failureGuidance(for: message)
        preflightProgress = "未切换：\(message)"
    }

    private func failureGuidance(for message: String) -> String {
        if message.contains("Microsoft Edge") {
            return "完全退出 Edge 后重试；或在 Settings 中关闭 Edge 的配置文件模式，改用即时快捷键缩放。"
        }
        if message.contains("正在运行") {
            return "完全退出提示中的目标应用后重试；运行中的应用可能会覆盖配置文件。"
        }
        if message.contains("辅助功能") {
            return "前往“系统设置 → 隐私与安全性 → 辅助功能”，授予 MacScaleManager 权限后重试。"
        }
        if message.contains("app-adapters.json") || message.contains("JSON") {
            return "打开 Settings，使用“校验配置”检查 app-adapters.json 后重新切换。"
        }
        return "打开 Settings 检查应用开关与配置；修正后重新选择目标模式。"
    }

    func enableBuiltInDisplay() {
        switch DisplayController.setBuiltInDisplay(enabled: true) {
        case .success(let message):
            lastDisplayResult = message
            lastError = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.builtInDisplayStatus = DisplayController.currentStatus()
            }
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func toggleBuiltInDisplay() {
        let enable = !builtInDisplayStatus.isEnabled
        switch DisplayController.setBuiltInDisplay(enabled: enable) {
        case .success(let message):
            lastDisplayResult = message
            lastError = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.builtInDisplayStatus = DisplayController.currentStatus()
            }
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func refreshDisplayStatus() {
        accessibilityTrusted = AXIsProcessTrusted()
        builtInDisplayStatus = DisplayController.currentStatus()
    }
}
