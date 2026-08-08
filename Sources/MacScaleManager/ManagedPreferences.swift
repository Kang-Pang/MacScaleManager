import AppKit
import Foundation
import Combine

struct ExternalAdapterDocument: Codable {
    var adapters: [ExternalJSONAdapter]
    var immediateAdapters: [ExternalImmediateAdapter]?
    var windowLayoutAdapters: [ExternalWindowLayoutAdapter]?
    var managedApplications: [String: Bool]?
    var desktopProfile: ScaleProfile?
    var laptopProfile: ScaleProfile?
}

/// Independent from immediate shortcut rules: this list only controls window
/// size and works for apps that do not support ⌘+/⌘0 zooming.
struct ExternalWindowLayoutAdapter: Codable, Identifiable {
    var enabled: Bool?
    var name: String
    var bundleIdentifier: String
    var windowSizePercent: Double?
    var id: String { bundleIdentifier }
    var isEnabled: Bool { enabled ?? true }
    var sizeFraction: CGFloat { min(max((windowSizePercent ?? 75) / 100, 0.3), 1.0) }
}

struct ExternalImmediateAdapter: Codable, Identifiable {
    var enabled: Bool?
    var name: String
    var bundleIdentifier: String
    var desktopZoomSteps: Int?
    var laptopAction: CustomLaptopAction?
    var applyOnLaunch: Bool?
    var resetBeforeDesktop: Bool?
    var launchDelaySeconds: Double?
    var shortcutIntervalSeconds: Double?
    /// Optional Accessibility window layout. It is deliberately independent
    /// from shortcut scaling, so a rule may resize a window without posting
    /// any keyboard shortcuts.
    var windowLayoutEnabled: Bool?
    var desktopWindowSizePercent: Double?
    var laptopWindowSizePercent: Double?
    var windowLayoutApplyOnLaunch: Bool?
    var id: String { bundleIdentifier }
    var shouldApplyOnLaunch: Bool { applyOnLaunch ?? true }
    var isEnabled: Bool { enabled ?? true }
    var shouldResetBeforeDesktop: Bool { resetBeforeDesktop ?? (bundleIdentifier != "com.tencent.qq") }
    var desktopLaunchDelay: Double { min(max(launchDelaySeconds ?? 2.0, 0.5), 10.0) }
    var shortcutInterval: Double { min(max(shortcutIntervalSeconds ?? (bundleIdentifier == "com.openai.codex" ? 0.28 : 0.25), 0.1), 1.0) }
    var summary: String { "\(desktopZoomSteps ?? 2) 次 ⌘+ · 启动后 \(String(format: "%.1f", desktopLaunchDelay)) 秒同步" }
    var shouldApplyWindowLayout: Bool { windowLayoutEnabled ?? false }
    var shouldApplyWindowLayoutOnLaunch: Bool { windowLayoutApplyOnLaunch ?? true }
    var desktopWindowSizeFraction: CGFloat { min(max((desktopWindowSizePercent ?? 75) / 100, 0.3), 1.0) }
    var laptopWindowSizeFraction: CGFloat { desktopWindowSizeFraction }
    func windowSizeFraction(for mode: ScaleMode) -> CGFloat {
        desktopWindowSizeFraction
    }
    func asImmediateApp() -> CustomImmediateApp {
        CustomImmediateApp(name: name, bundleIdentifier: bundleIdentifier, desktopZoomSteps: min(max(desktopZoomSteps ?? 2, 1), 6), laptopAction: laptopAction ?? .reset, resetBeforeDesktop: shouldResetBeforeDesktop, launchDelaySeconds: desktopLaunchDelay, shortcutIntervalSeconds: shortcutInterval)
    }
}

struct ExternalJSONAdapter: Codable {
    let enabled: Bool?
    let name: String
    let bundleIdentifier: String?
    let relativePath: String
    let requiresQuit: Bool?
    let settings: [ExternalJSONSetting]
    var isEnabled: Bool { enabled ?? true }
    var mustQuit: Bool { requiresQuit ?? true }
    func configurationURL() throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.contains("..") else {
            throw PreferenceError.externalAdapterConfig(name + " 的 relativePath 必须是主目录下的相对路径")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: relativePath)
    }
}

struct ExternalJSONSetting: Codable {
    let path: [String]
    let profileValue: ExternalProfileValue
}

enum ExternalProfileValue: String, Codable {
    case editorFontSize, terminalFontSize, vscodeZoom, browserZoomPercent, chromiumZoomLevel, dockSize, cursorSize
    func resolve(_ profile: ScaleProfile) -> Any {
        switch self {
        case .editorFontSize: return profile.editorFontSize
        case .terminalFontSize: return profile.terminalFontSize
        case .vscodeZoom: return profile.vscodeZoom
        case .browserZoomPercent: return profile.browserZoomPercent
        case .chromiumZoomLevel: return log(Double(profile.browserZoomPercent) / 100.0) / log(1.2)
        case .dockSize: return profile.dockSize
        case .cursorSize: return profile.cursorSize
        }
    }
}

private enum ExternalAdapterConfiguration {
    static let url: URL = {
        let executablePath = CommandLine.arguments[0]
        if executablePath.contains("/MacScaleManager.app/") {
            var releaseDirectory = URL(fileURLWithPath: executablePath)
            for _ in 0..<4 { releaseDirectory.deleteLastPathComponent() }
            return releaseDirectory.appending(path: "config/app-adapters.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications/MacScaleManager/source/config/app-adapters.json")
    }()
    static func save(_ document: ExternalAdapterDocument) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    static func load() throws -> ExternalAdapterDocument {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "{\n  \"adapters\" : []\n}\n".write(to: url, atomically: true, encoding: .utf8)
        }
        do { return try JSONDecoder().decode(ExternalAdapterDocument.self, from: Data(contentsOf: url)) }
        catch { throw PreferenceError.externalAdapterConfig("无法读取 app-adapters.json：" + error.localizedDescription) }
    }
}

enum ConfigurationParameterKind { case vscode, browser, terminal, dock, cursor, none }

struct ConfigurationItem: Identifiable {
    let id: String
    let title: String
    let kind: ConfigurationParameterKind
}

struct BlockingApplication: Identifiable {
    let name: String
    let application: NSRunningApplication
    var id: String { "\(application.processIdentifier)-\(application.bundleIdentifier ?? name)" }
}

private let configurationItemDefinitions: [String: ConfigurationItem] = [
    "vscode": ConfigurationItem(id: "vscode", title: "VS Code", kind: .vscode),
    "terminal": ConfigurationItem(id: "terminal", title: "Terminal.app", kind: .terminal),
    "chrome": ConfigurationItem(id: "chrome", title: "Google Chrome", kind: .browser),
    "edge": ConfigurationItem(id: "edge", title: "Microsoft Edge", kind: .browser),
    "zotero": ConfigurationItem(id: "zotero", title: "Zotero", kind: .browser),
    "notion": ConfigurationItem(id: "notion", title: "Notion", kind: .browser),
    "claude": ConfigurationItem(id: "claude", title: "Claude", kind: .browser),
    "codex": ConfigurationItem(id: "codex", title: "Codex", kind: .browser),
    "dock": ConfigurationItem(id: "dock", title: "Dock", kind: .dock),
    "cursor": ConfigurationItem(id: "cursor", title: "鼠标指针", kind: .cursor)
]

enum PreferenceError: LocalizedError {
    case unreadableFile(URL)
    case invalidJSON(URL)
    case systemCommandFailed(String)
    case applicationRunning(String)
    case externalAdapterConfig(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let url): return "无法读取配置文件：\(url.path)"
        case .invalidJSON(let url): return "配置文件不是有效 JSON：\(url.path)"
        case .systemCommandFailed(let message): return message
        case .externalAdapterConfig(let message): return message
        case .applicationRunning(let name):
            if name == "Microsoft Edge" { return "无法切换：Microsoft Edge 正在运行。请退出 Edge 后重试，或关闭 Edge 的配置文件模式并使用即时模式。" }
            return "无法切换：\(name) 正在运行。请完全退出后重试；运行中的应用可能覆盖其配置文件。"
        }
    }
}

/// Persists backups per managed setting. A missing backup means this app has never owned that key.
@MainActor
final class ManagedPreferences: ObservableObject {
    @Published var manageVSCode: Bool { didSet { store.set(manageVSCode, forKey: "manageVSCode") } }
    @Published var manageTerminal: Bool { didSet { store.set(manageTerminal, forKey: "manageTerminal") } }
    @Published var manageChrome: Bool { didSet { store.set(manageChrome, forKey: "manageChrome") } }
    @Published var manageEdge: Bool { didSet { store.set(manageEdge, forKey: "manageEdge") } }
    @Published var manageDock: Bool { didSet { store.set(manageDock, forKey: "manageDock") } }
    @Published var manageCursor: Bool { didSet { store.set(manageCursor, forKey: "manageCursor") } }
    @Published var manageZotero: Bool { didSet { store.set(manageZotero, forKey: "manageZotero") } }
    @Published var manageNotion: Bool { didSet { store.set(manageNotion, forKey: "manageNotion") } }
    @Published var manageClaude: Bool { didSet { store.set(manageClaude, forKey: "manageClaude") } }
    @Published var manageCodex: Bool { didSet { store.set(manageCodex, forKey: "manageCodex") } }
    @Published var immediateMode: Bool { didSet { store.set(immediateMode, forKey: "immediateMode") } }
    @Published var immediateQQ: Bool { didSet { store.set(immediateQQ, forKey: "immediateQQ") } }
    @Published var immediateWeChat: Bool { didSet { store.set(immediateWeChat, forKey: "immediateWeChat") } }
    @Published var immediateCodex: Bool { didSet { store.set(immediateCodex, forKey: "immediateCodex") } }
    @Published var immediateClaude: Bool { didSet { store.set(immediateClaude, forKey: "immediateClaude") } }
    @Published var immediateNotion: Bool { didSet { store.set(immediateNotion, forKey: "immediateNotion") } }
    @Published var immediateTerminal: Bool { didSet { store.set(immediateTerminal, forKey: "immediateTerminal") } }
    @Published var immediateZoomSteps: [String: Int] { didSet { saveImmediateZoomSteps() } }
    @Published var immediateLaptopActions: [String: String] { didSet { store.set(immediateLaptopActions, forKey: "immediateLaptopActions") } }
    @Published var desktopProfile: ScaleProfile { didSet { saveDesktopProfile() } }
    @Published var laptopProfile: ScaleProfile { didSet { saveLaptopProfile() } }
    @Published var customProfile: ScaleProfile { didSet { saveCustomProfile() } }
    @Published var customImmediateApps: [CustomImmediateApp] { didSet { saveCustomImmediateApps() } }
    @Published private(set) var managedApplicationConfig: [String: Bool] = [:]
    @Published private(set) var configuredImmediateAdapters: [ExternalImmediateAdapter] = []
    @Published private(set) var configuredWindowLayoutAdapters: [ExternalWindowLayoutAdapter] = []
    @Published private(set) var adapterConfigurationError: String?
    @Published private(set) var adapterValidationResult: String?

    private let store = UserDefaults.standard
    private let backupKey = "managedPreferenceBackupsV1"
    private let baselineKey = "hasEstablishedLaptopBaselineV1"
    private var isReloadingAdapterConfiguration = false

    init() {
        manageVSCode = store.object(forKey: "manageVSCode") as? Bool ?? true
        manageTerminal = store.object(forKey: "manageTerminal") as? Bool ?? false
        manageChrome = store.object(forKey: "manageChrome") as? Bool ?? true
        manageEdge = store.object(forKey: "manageEdge") as? Bool ?? false
        manageDock = store.object(forKey: "manageDock") as? Bool ?? false
        manageCursor = store.object(forKey: "manageCursor") as? Bool ?? false
        manageZotero = store.object(forKey: "manageZotero") as? Bool ?? true
        manageNotion = store.object(forKey: "manageNotion") as? Bool ?? false
        manageClaude = store.object(forKey: "manageClaude") as? Bool ?? false
        manageCodex = store.object(forKey: "manageCodex") as? Bool ?? false
        immediateMode = store.object(forKey: "immediateMode") as? Bool ?? false
        immediateQQ = store.object(forKey: "immediateQQ") as? Bool ?? false
        immediateWeChat = store.object(forKey: "immediateWeChat") as? Bool ?? true
        immediateCodex = store.object(forKey: "immediateCodex") as? Bool ?? true
        immediateClaude = store.object(forKey: "immediateClaude") as? Bool ?? true
        immediateNotion = store.object(forKey: "immediateNotion") as? Bool ?? true
        immediateTerminal = store.object(forKey: "immediateTerminal") as? Bool ?? true
        let savedZoomSteps = store.dictionary(forKey: "immediateZoomSteps") as? [String: Int] ?? [:]
        immediateZoomSteps = ["qq": 2, "wechat": 2, "codex": 3, "claude": 2, "notion": 2, "terminal": 2].merging(savedZoomSteps) { _, saved in saved }
        let savedActions = store.dictionary(forKey: "immediateLaptopActions") as? [String: String] ?? [:]
        immediateLaptopActions = ["qq": "zoomOut", "wechat": "reset", "codex": "reset", "claude": "reset", "notion": "reset", "terminal": "reset"].merging(savedActions) { _, saved in saved }
        if let data = store.data(forKey: "desktopProfile"), let profile = try? JSONDecoder().decode(ScaleProfile.self, from: data) {
            desktopProfile = profile
        } else { desktopProfile = .desktop }
        if let data = store.data(forKey: "laptopProfile"), let profile = try? JSONDecoder().decode(ScaleProfile.self, from: data) {
            laptopProfile = profile
        } else { laptopProfile = .laptop }
        customProfile = .desktop
        customImmediateApps = []
        migrateLegacyCustomImmediateApps()
        reloadAdapterConfiguration()
        persistProfilesIfNeeded()
    }

    var configurationItems: [ConfigurationItem] {
        managedApplicationConfig.keys.sorted().map { key in
            configurationItemDefinitions[key] ?? ConfigurationItem(id: key, title: key, kind: .none)
        }
    }

    func isManagedApplicationEnabled(_ key: String) -> Bool { managedApplicationConfig[key] ?? false }

    func setManagedApplicationEnabled(_ enabled: Bool, key: String) {
        updateAdapterConfiguration { document in
            var applications = document.managedApplications ?? [:]
            applications[key] = enabled
            document.managedApplications = applications
        }
    }

    /// Returns only apps that would make a configuration-file profile change unsafe.
    /// Unopened apps and immediate-shortcut targets intentionally do not appear here.
    func blockingApplicationsForProfileChange() -> [BlockingApplication] {
        guard let document = try? ExternalAdapterConfiguration.load() else { return [] }
        let configured = document.managedApplications ?? [:]
        let candidates: [(String, String, Bool)] = [
            ("VS Code", "com.microsoft.VSCode", configured["vscode"] ?? manageVSCode),
            ("Google Chrome", "com.google.Chrome", configured["chrome"] ?? manageChrome),
            ("Microsoft Edge", "com.microsoft.edgemac", configured["edge"] ?? manageEdge),
            ("Zotero", "org.zotero.zotero", configured["zotero"] ?? manageZotero),
            ("Notion", "notion.id", configured["notion"] ?? manageNotion),
            ("Claude", "com.anthropic.claude", configured["claude"] ?? manageClaude),
            ("Codex", "com.openai.codex", configured["codex"] ?? manageCodex)
        ]
        var result: [BlockingApplication] = []
        var seen = Set<String>()
        for (name, bundleID, enabled) in candidates where enabled && seen.insert(bundleID).inserted {
            if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
                result.append(BlockingApplication(name: name, application: app))
            }
        }
        for adapter in document.adapters where adapter.isEnabled && adapter.mustQuit {
            guard let bundleID = adapter.bundleIdentifier, seen.insert(bundleID).inserted,
                  let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { continue }
            result.append(BlockingApplication(name: adapter.name, application: app))
        }
        return result
    }

    func addConfiguredImmediateAdapter(name: String, bundleIdentifier: String) {
        guard !name.isEmpty, !bundleIdentifier.isEmpty else { return }
        updateAdapterConfiguration { document in
            var adapters = document.immediateAdapters ?? []
            guard !adapters.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
            adapters.append(ExternalImmediateAdapter(enabled: true, name: name, bundleIdentifier: bundleIdentifier, desktopZoomSteps: 2, laptopAction: .reset, applyOnLaunch: true, resetBeforeDesktop: true, launchDelaySeconds: 2.0))
            document.immediateAdapters = adapters
        }
    }

    private func migrateLegacyCustomImmediateApps() {
        guard let data = store.data(forKey: "customImmediateApps"), let apps = try? JSONDecoder().decode([CustomImmediateApp].self, from: data) else { return }
        updateAdapterConfiguration { document in
            var adapters = document.immediateAdapters ?? []
            for app in apps where !adapters.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                adapters.append(ExternalImmediateAdapter(enabled: true, name: app.name, bundleIdentifier: app.bundleIdentifier, desktopZoomSteps: app.desktopZoomSteps, laptopAction: app.laptopAction, applyOnLaunch: true, resetBeforeDesktop: app.resetBeforeDesktop, launchDelaySeconds: app.launchDelaySeconds))
            }
            document.immediateAdapters = adapters
        }
        store.removeObject(forKey: "customImmediateApps")
        store.removeObject(forKey: "customProfile")
    }

    func deleteConfiguredImmediateAdapter(bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters?.removeAll { $0.bundleIdentifier == bundleIdentifier }
        }
    }

    func setConfiguredImmediateEnabled(_ enabled: Bool, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.enabled = enabled; return updated
            }
        }
    }

    func setConfiguredImmediateZoomSteps(_ steps: Int, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.desktopZoomSteps = min(max(steps, 1), 6); return updated
            }
        }
    }

    func setConfiguredImmediateApplyOnLaunch(_ enabled: Bool, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.applyOnLaunch = enabled; return updated
            }
        }
    }

    func setConfiguredImmediateShortcutInterval(_ seconds: Double, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.shortcutIntervalSeconds = min(max(seconds, 0.1), 1.0); return updated
            }
        }
    }

    func setConfiguredImmediateLaunchDelay(_ seconds: Double, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.launchDelaySeconds = min(max(seconds, 0.5), 10.0); return updated
            }
        }
    }

    func setConfiguredImmediateResetBeforeDesktop(_ enabled: Bool, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.resetBeforeDesktop = enabled; return updated
            }
        }
    }

    func setConfiguredWindowLayoutEnabled(_ enabled: Bool, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.windowLayoutEnabled = enabled; return updated
            }
        }
    }

    func setConfiguredWindowLayoutSize(_ percent: Double, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.desktopWindowSizePercent = min(max(percent, 30), 100); return updated
            }
        }
    }

    func setConfiguredLaptopWindowLayoutSize(_ percent: Double, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.laptopWindowSizePercent = min(max(percent, 30), 100); return updated
            }
        }
    }

    func setConfiguredWindowLayoutApplyOnLaunch(_ enabled: Bool, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.windowLayoutApplyOnLaunch = enabled; return updated
            }
        }
    }

    func configuredDesktopLaunchApp(bundleIdentifier: String) throws -> CustomImmediateApp? {
        try ExternalAdapterConfiguration.load().immediateAdapters?
            .first { $0.bundleIdentifier == bundleIdentifier && $0.isEnabled && $0.shouldApplyOnLaunch }?
            .asImmediateApp()
    }

    func configuredImmediateApp(bundleIdentifier: String) throws -> CustomImmediateApp? {
        try ExternalAdapterConfiguration.load().immediateAdapters?
            .first { $0.bundleIdentifier == bundleIdentifier && $0.isEnabled }?
            .asImmediateApp()
    }

    func configuredWindowLayout(bundleIdentifier: String) throws -> ExternalWindowLayoutAdapter? {
        try ExternalAdapterConfiguration.load().windowLayoutAdapters?
            .first { $0.bundleIdentifier == bundleIdentifier && $0.isEnabled }
    }

    func addWindowLayoutAdapter(name: String, bundleIdentifier: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBundleID = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedBundleID.isEmpty else { return }
        updateAdapterConfiguration { document in
            var adapters = document.windowLayoutAdapters ?? []
            guard !adapters.contains(where: { $0.bundleIdentifier == trimmedBundleID }) else { return }
            adapters.append(ExternalWindowLayoutAdapter(enabled: true, name: trimmedName, bundleIdentifier: trimmedBundleID, windowSizePercent: 75))
            document.windowLayoutAdapters = adapters
        }
    }

    func deleteWindowLayoutAdapter(bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.windowLayoutAdapters?.removeAll { $0.bundleIdentifier == bundleIdentifier }
        }
    }

    func setWindowLayoutEnabled(_ enabled: Bool, bundleIdentifier: String) {
        updateWindowLayoutAdapter(bundleIdentifier) { $0.enabled = enabled }
    }

    func setWindowLayoutSize(_ percent: Double, bundleIdentifier: String) {
        updateWindowLayoutAdapter(bundleIdentifier) { $0.windowSizePercent = min(max(percent, 30), 100) }
    }

    private func updateWindowLayoutAdapter(_ bundleIdentifier: String, _ mutation: (inout ExternalWindowLayoutAdapter) -> Void) {
        updateAdapterConfiguration { document in
            document.windowLayoutAdapters = document.windowLayoutAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; mutation(&updated); return updated
            }
        }
    }

    func setConfiguredImmediateLaptopAction(_ action: CustomLaptopAction, bundleIdentifier: String) {
        updateAdapterConfiguration { document in
            document.immediateAdapters = document.immediateAdapters?.map { adapter in
                guard adapter.bundleIdentifier == bundleIdentifier else { return adapter }
                var updated = adapter; updated.laptopAction = action; return updated
            }
        }
    }

    func reloadAdapterConfiguration() {
        do {
            var document = try ExternalAdapterConfiguration.load()
            // One-time migration from the former immediateAdapters layout fields.
            let needsMigration = document.windowLayoutAdapters == nil
            if needsMigration {
                document.windowLayoutAdapters = document.immediateAdapters?.filter(\.shouldApplyWindowLayout).map {
                    ExternalWindowLayoutAdapter(enabled: true, name: $0.name, bundleIdentifier: $0.bundleIdentifier, windowSizePercent: $0.desktopWindowSizePercent ?? 75)
                } ?? []
            }
            // Window sizing is now wholly independent from shortcut rules.
            // Remove the legacy duplicated fields once they have been migrated.
            let hadLegacyLayoutFields = document.immediateAdapters?.contains {
                $0.windowLayoutEnabled != nil || $0.desktopWindowSizePercent != nil || $0.laptopWindowSizePercent != nil || $0.windowLayoutApplyOnLaunch != nil
            } ?? false
            if hadLegacyLayoutFields {
                document.immediateAdapters = document.immediateAdapters?.map { adapter in
                    var updated = adapter
                    updated.windowLayoutEnabled = nil
                    updated.desktopWindowSizePercent = nil
                    updated.laptopWindowSizePercent = nil
                    updated.windowLayoutApplyOnLaunch = nil
                    return updated
                }
            }
            if needsMigration || hadLegacyLayoutFields {
                try ExternalAdapterConfiguration.save(document)
            }
            isReloadingAdapterConfiguration = true
            if let profile = document.desktopProfile { desktopProfile = profile }
            if let profile = document.laptopProfile { laptopProfile = profile }
            isReloadingAdapterConfiguration = false
            managedApplicationConfig = document.managedApplications ?? [:]
            configuredImmediateAdapters = document.immediateAdapters ?? []
            configuredWindowLayoutAdapters = document.windowLayoutAdapters ?? []
            adapterConfigurationError = nil
        } catch {
            isReloadingAdapterConfiguration = false
            adapterConfigurationError = error.localizedDescription
        }
    }

    func validateAdapterConfiguration() {
        do {
            let document = try ExternalAdapterConfiguration.load()
            var findings: [String] = ["配置文件有效"]
            for adapter in document.adapters where adapter.isEnabled {
                let url = try adapter.configurationURL()
                findings.append("\(adapter.name)：\(FileManager.default.fileExists(atPath: url.path) ? "配置文件已找到" : "配置文件尚未创建")")
            }
            for adapter in document.immediateAdapters ?? [] where adapter.isEnabled {
                let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == adapter.bundleIdentifier }
                findings.append("\(adapter.name)：\(running ? "正在运行，可测试" : "未运行（切换时会跳过）")")
            }
            adapterValidationResult = findings.joined(separator: "；")
            adapterConfigurationError = nil
        } catch {
            adapterValidationResult = nil
            adapterConfigurationError = "校验失败：\(error.localizedDescription)"
        }
    }

    private func updateAdapterConfiguration(_ mutation: (inout ExternalAdapterDocument) -> Void) {
        do {
            var document = try ExternalAdapterConfiguration.load()
            mutation(&document)
            try ExternalAdapterConfiguration.save(document)
            managedApplicationConfig = document.managedApplications ?? [:]
            configuredImmediateAdapters = document.immediateAdapters ?? []
            configuredWindowLayoutAdapters = document.windowLayoutAdapters ?? []
            adapterConfigurationError = nil
        } catch { adapterConfigurationError = error.localizedDescription }
    }

    func laptopValueSummary(for kind: ConfigurationParameterKind) -> String {
        switch kind {
        case .vscode:
            return "Laptop 参数：编辑器 \(Int(laptopProfile.editorFontSize)) pt · 终端 \(Int(laptopProfile.terminalFontSize)) pt · UI \(laptopProfile.vscodeZoom)"
        case .browser:
            return "Laptop 参数：\(laptopProfile.browserZoomPercent)%"
        case .terminal:
            return "Laptop 参数：\(Int(laptopProfile.terminalFontSize)) pt"
        case .dock:
            return "Laptop 参数：\(laptopProfile.dockSize) px"
        case .cursor:
            return "Laptop 参数：\(String(format: "%.2f", laptopProfile.cursorSize))×"
        case .none:
            return "Laptop 参数：由应用自身配置决定"
        }
    }

    func externalImmediateApps() throws -> [CustomImmediateApp] {
        try ExternalAdapterConfiguration.load().immediateAdapters?.filter { $0.isEnabled }.map { $0.asImmediateApp() } ?? []
    }

    var managesTerminal: Bool {
        (try? ExternalAdapterConfiguration.load().managedApplications?["terminal"]) ?? manageTerminal
    }

    var managesDock: Bool {
        (try? ExternalAdapterConfiguration.load().managedApplications?["dock"]) ?? manageDock
    }

    var immediateTargets: [ImmediateTarget] {
        [immediateQQ ? .qq : nil, immediateWeChat ? .wechat : nil, immediateCodex ? .codex : nil,
         immediateClaude ? .claude : nil, immediateNotion ? .notion : nil, immediateTerminal ? .terminal : nil].compactMap { $0 }
    }

    func zoomSteps(for target: ImmediateTarget) -> Int { max(1, immediateZoomSteps[target.rawValue] ?? (target == .codex ? 3 : 2)) }

    func setZoomSteps(_ count: Int, for target: ImmediateTarget) { immediateZoomSteps[target.rawValue] = min(max(count, 1), 6) }

    func laptopAction(for target: ImmediateTarget) -> CustomLaptopAction { CustomLaptopAction(rawValue: immediateLaptopActions[target.rawValue] ?? "reset") ?? .reset }
    func setLaptopAction(_ action: CustomLaptopAction, for target: ImmediateTarget) { immediateLaptopActions[target.rawValue] = action.rawValue }
    func isImmediateEnabled(_ target: ImmediateTarget) -> Bool { switch target { case .qq: immediateQQ; case .wechat: immediateWeChat; case .codex: immediateCodex; case .claude: immediateClaude; case .notion: immediateNotion; case .terminal: immediateTerminal } }
    func setImmediateEnabled(_ enabled: Bool, for target: ImmediateTarget) { switch target { case .qq: immediateQQ = enabled; case .wechat: immediateWeChat = enabled; case .codex: immediateCodex = enabled; case .claude: immediateClaude = enabled; case .notion: immediateNotion = enabled; case .terminal: immediateTerminal = enabled } }

    private func saveImmediateZoomSteps() { store.set(immediateZoomSteps, forKey: "immediateZoomSteps") }


    func applyTerminalFont(size: Double) throws {
        let key = "terminalOriginalFontSize"
        if store.object(forKey: key) == nil, let current = TerminalController.currentFontSize() { store.set(current, forKey: key) }
        try TerminalController.setDefaultFontSize(size)
    }

    func restoreTerminalFont() throws {
        guard let size = store.object(forKey: "terminalOriginalFontSize") as? Double else { return }
        try TerminalController.setDefaultFontSize(size)
    }

    func apply(profile: ScaleProfile, captureBackups: Bool = true) throws {
        let adapterDocument = try ExternalAdapterConfiguration.load()
        let externalAdapters = adapterDocument.adapters
        let managedApplications = adapterDocument.managedApplications
        let useVSCode = managedApplications?["vscode"] ?? manageVSCode
        let useChrome = managedApplications?["chrome"] ?? manageChrome
        let useEdge = managedApplications?["edge"] ?? manageEdge
        let useDock = managedApplications?["dock"] ?? manageDock
        let useCursor = managedApplications?["cursor"] ?? manageCursor
        let useZotero = managedApplications?["zotero"] ?? manageZotero
        let useNotion = managedApplications?["notion"] ?? manageNotion
        let useClaude = managedApplications?["claude"] ?? manageClaude
        let useCodex = managedApplications?["codex"] ?? manageCodex
        for adapter in externalAdapters where adapter.isEnabled && adapter.mustQuit {
            if let bundleID = adapter.bundleIdentifier { try ensureNotRunning(bundleIdentifier: bundleID, name: adapter.name) }
        }
        // Chromium keeps Preferences in memory and rewrites the file on exit.
        // Writing it while the browser is open makes a successful-looking change
        // disappear, so fail before touching any managed configuration.
        if useChrome { try ensureNotRunning(bundleIdentifier: "com.google.Chrome", name: "Google Chrome") }
        if useEdge { try ensureNotRunning(bundleIdentifier: "com.microsoft.edgemac", name: "Microsoft Edge") }
        if useZotero { try ensureNotRunning(bundleIdentifier: "org.zotero.zotero", name: "Zotero") }
        if useNotion { try ensureNotRunning(bundleIdentifier: "notion.id", name: "Notion") }
        if useClaude { try ensureNotRunning(bundleIdentifier: "com.anthropic.claude", name: "Claude") }
        if useCodex { try ensureNotRunning(bundleIdentifier: "com.openai.codex", name: "Codex") }
        if useVSCode { try updateVSCode(profile, captureBackups: captureBackups) }
        if useChrome { try updateChromium(named: "Google/Chrome", profile: profile, captureBackups: captureBackups) }
        if useEdge { try updateChromium(named: "Microsoft Edge", profile: profile, captureBackups: captureBackups) }
        if useDock { try setDefault(domain: "com.apple.dock", key: "tilesize", value: profile.dockSize, captureBackups: captureBackups) }
        if useCursor { try setDefault(domain: "com.apple.universalaccess", key: "mouseDriverCursorSize", value: profile.cursorSize, captureBackups: captureBackups) }
        if useZotero { try updateZotero(profile, captureBackups: captureBackups) }
        if useNotion { try updateElectron(profile, preferencesURL: home("Library/Application Support/Notion/Preferences"), captureBackups: captureBackups, updateExistingHosts: true) }
        if useClaude { try updateElectron(profile, preferencesURL: home("Library/Application Support/Claude-3p/Preferences"), captureBackups: captureBackups, updateExistingHosts: false) }
        if useCodex { try updateElectron(profile, preferencesURL: home("Library/Application Support/Codex/Default/Preferences"), captureBackups: captureBackups, updateExistingHosts: false) }
        try applyExternalJSONAdapters(externalAdapters, profile: profile, captureBackups: captureBackups)
    }

    private func applyExternalJSONAdapters(_ adapters: [ExternalJSONAdapter], profile: ScaleProfile, captureBackups: Bool) throws {
        for adapter in adapters where adapter.isEnabled {
            let values = try adapter.settings.map { setting -> ([String], Any) in
                guard !setting.path.isEmpty else { throw PreferenceError.externalAdapterConfig("\(adapter.name) 包含空 JSON 路径") }
                return (setting.path, setting.profileValue.resolve(profile))
            }
            guard !values.isEmpty else { continue }
            try updateJSON(url: adapter.configurationURL(), paths: values, captureBackups: captureBackups)
        }
    }

    func restore() throws {
        var backups = loadBackups()
        for key in backups.keys.sorted() {
            guard let entry = backups[key] else { continue }
            try restore(entry)
            backups.removeValue(forKey: key)
        }
        saveBackups(backups)
    }

    func applyLaptopProfile() throws {
        // Laptop Mode is a defined baseline, not a replay of an old backup. Some
        // earlier backups captured a Desktop zoom value, which could otherwise
        // leave Chromium browsers at 125% instead of the Laptop 100% target.
        try apply(profile: laptopProfile, captureBackups: false)
    }

    private func updateVSCode(_ profile: ScaleProfile, captureBackups: Bool) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Code/User/settings.json")
        try updateJSON(url: url, values: [
            "editor.fontSize": profile.editorFontSize,
            "terminal.integrated.fontSize": profile.terminalFontSize,
            "window.zoomLevel": profile.vscodeZoom
        ], captureBackups: captureBackups)
    }

    private func updateChromium(named product: String, profile: ScaleProfile, captureBackups: Bool) throws {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/\(product)")
        guard let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]), !children.isEmpty else { return }
        // Chromium stores each profile separately. 1.2 is the zoom ladder used internally by Chromium.
        let level = log(Double(profile.browserZoomPercent) / 100.0) / log(1.2)
        for directory in children where directory.lastPathComponent == "Default" || directory.lastPathComponent.hasPrefix("Profile ") {
            // Recent Chromium builds use the partition value. The top-level value is
            // retained for older Chrome/Edge profiles that still read it.
            try updateJSON(url: directory.appending(path: "Preferences"), paths: [
                (["default_zoom_level"], level),
                (["partition", "default_zoom_level", "x"], level)
            ], captureBackups: captureBackups)
        }
    }

    private func updateElectron(_ profile: ScaleProfile, preferencesURL: URL, captureBackups: Bool, updateExistingHosts: Bool) throws {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else { return }
        let level = log(Double(profile.browserZoomPercent) / 100.0) / log(1.2)
        var paths: [([String], Any)] = [(["partition", "default_zoom_level", "x"], level)]
        if updateExistingHosts,
           let data = try? Data(contentsOf: preferencesURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let partition = root["partition"] as? [String: Any],
           let allHosts = partition["per_host_zoom_levels"] as? [String: Any] {
            for (partitionID, hosts) in allHosts {
                guard let hostMap = hosts as? [String: Any] else { continue }
                for host in hostMap.keys {
                    paths.append((["partition", "per_host_zoom_levels", partitionID, host, "zoom_level"], level))
                }
            }
        }
        try updateJSON(url: preferencesURL, paths: paths, captureBackups: captureBackups)
    }

    private func updateZotero(_ profile: ScaleProfile, captureBackups: Bool) throws {
        let profilesRoot = home("Library/Application Support/Zotero/Profiles")
        guard let profiles = try? FileManager.default.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: nil) else { return }
        for profileURL in profiles {
            let url = profileURL.appending(path: "prefs.js")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let original = try String(contentsOf: url, encoding: .utf8)
            let pattern = "(?m)^user_pref\\(\\\"layout\\.css\\.devPixelsPerPx\\\",.*?\\);\\s*$"
            let range = NSRange(original.startIndex..., in: original)
            let existingRange = try NSRegularExpression(pattern: pattern).firstMatch(in: original, range: range).flatMap { Range($0.range, in: original) }
            let previous = existingRange.map { String(original[$0]) }
            let backupID = "text|\(url.path)|layout.css.devPixelsPerPx"
            if captureBackups { captureIfNeeded(id: backupID, entry: .text(url: url.path, key: "layout.css.devPixelsPerPx", value: previous)) }
            let factor = profile.browserZoomPercent == 100 ? "-1.0" : String(format: "%.2f", Double(profile.browserZoomPercent) / 100.0)
            let replacement = "user_pref(\"layout.css.devPixelsPerPx\", \"\(factor)\");"
            let updated = existingRange.map { original.replacingCharacters(in: $0, with: replacement) } ?? (original + "\n\(replacement)\n")
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func home(_ path: String) -> URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: path) }

    private func updateJSON(url: URL, values: [String: Any], captureBackups: Bool) throws {
        try updateJSON(url: url, paths: values.map { ([$0.key], $0.value) }, captureBackups: captureBackups)
    }

    private func updateJSON(url: URL, paths: [([String], Any)], captureBackups: Bool) throws {
        let fileManager = FileManager.default
        var json: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PreferenceError.invalidJSON(url) }
            json = decoded
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        for (path, newValue) in paths {
            let encodedPath = path.joined(separator: "\u{1F}")
            let backupID = "json|\(url.path)|\(encodedPath)"
            if captureBackups {
                captureIfNeeded(id: backupID, entry: .json(url: url.path, key: encodedPath, value: JSONValue(value(at: path, in: json))))
            }
            set(newValue, at: path, in: &json)
        }
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func setDefault(domain: String, key: String, value: Any, captureBackups: Bool) throws {
        let backupID = "defaults|\(domain)|\(key)"
        let defaults = UserDefaults(suiteName: domain)
        if captureBackups {
            captureIfNeeded(id: backupID, entry: .defaults(domain: domain, key: key, value: JSONValue(defaults?.object(forKey: key))))
        }
        defaults?.set(value, forKey: key)
        defaults?.synchronize()
        if domain == "com.apple.dock" { try run("/usr/bin/killall", ["Dock"], failureIsFatal: false) }
    }

    private func restore(_ entry: BackupEntry) throws {
        switch entry {
        case let .json(urlPath, key, value):
            let url = URL(fileURLWithPath: urlPath)
            var json: [String: Any] = [:]
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PreferenceError.invalidJSON(url) }
                json = decoded
            }
            let path = key.components(separatedBy: "\u{1F}")
            if let value { set(value.foundationValue, at: path, in: &json) } else { removeValue(at: path, in: &json) }
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
        case let .defaults(domain, key, value):
            let defaults = UserDefaults(suiteName: domain)
            if let value { defaults?.set(value.foundationValue, forKey: key) } else { defaults?.removeObject(forKey: key) }
            defaults?.synchronize()
            if domain == "com.apple.dock" { try run("/usr/bin/killall", ["Dock"], failureIsFatal: false) }
        case let .text(urlPath, key, value):
            let url = URL(fileURLWithPath: urlPath)
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
            if key == "layout.css.devPixelsPerPx" {
                let pattern = "(?m)^user_pref\\(\\\"layout\\.css\\.devPixelsPerPx\\\",.*?\\);\\s*$"
                let regex = try NSRegularExpression(pattern: pattern)
                let nsRange = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, range: nsRange, withTemplate: value ?? "")
                if let value, !text.contains(value) { text += "\n\(value)\n" }
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    private func run(_ executable: String, _ arguments: [String], failureIsFatal: Bool) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        try process.run(); process.waitUntilExit()
        if failureIsFatal && process.terminationStatus != 0 { throw PreferenceError.systemCommandFailed("系统设置命令执行失败") }
    }

    private func ensureNotRunning(bundleIdentifier: String, name: String) throws {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            throw PreferenceError.applicationRunning(name)
        }
    }

    private func value(at path: [String], in object: [String: Any]) -> Any? {
        var current: Any = object
        for part in path {
            guard let dictionary = current as? [String: Any], let next = dictionary[part] else { return nil }
            current = next
        }
        return current
    }

    private func set(_ value: Any, at path: [String], in object: inout [String: Any]) {
        guard let first = path.first else { return }
        guard path.count > 1 else { object[first] = value; return }
        var child = object[first] as? [String: Any] ?? [:]
        set(value, at: Array(path.dropFirst()), in: &child)
        object[first] = child
    }

    private func removeValue(at path: [String], in object: inout [String: Any]) {
        guard let first = path.first else { return }
        guard path.count > 1 else { object.removeValue(forKey: first); return }
        guard var child = object[first] as? [String: Any] else { return }
        removeValue(at: Array(path.dropFirst()), in: &child)
        object[first] = child
    }

    private func captureIfNeeded(id: String, entry: BackupEntry) {
        var backups = loadBackups()
        if backups[id] == nil { backups[id] = entry; saveBackups(backups) }
    }

    private func loadBackups() -> [String: BackupEntry] {
        guard let data = store.data(forKey: backupKey), let result = try? JSONDecoder().decode([String: BackupEntry].self, from: data) else { return [:] }
        return result
    }
    private func saveBackups(_ backups: [String: BackupEntry]) { store.set(try? JSONEncoder().encode(backups), forKey: backupKey) }
    private func saveDesktopProfile() {
        store.set(try? JSONEncoder().encode(desktopProfile), forKey: "desktopProfile") // legacy fallback
        guard !isReloadingAdapterConfiguration else { return }
        updateAdapterConfiguration { $0.desktopProfile = desktopProfile }
    }

    private func saveLaptopProfile() {
        store.set(try? JSONEncoder().encode(laptopProfile), forKey: "laptopProfile") // legacy fallback
        guard !isReloadingAdapterConfiguration else { return }
        updateAdapterConfiguration { $0.laptopProfile = laptopProfile }
    }

    private func persistProfilesIfNeeded() {
        guard let document = try? ExternalAdapterConfiguration.load(), document.desktopProfile == nil || document.laptopProfile == nil else { return }
        updateAdapterConfiguration { document in
            if document.desktopProfile == nil { document.desktopProfile = desktopProfile }
            if document.laptopProfile == nil { document.laptopProfile = laptopProfile }
        }
    }
    private func saveCustomProfile() { store.set(try? JSONEncoder().encode(customProfile), forKey: "customProfile") }
    private func saveCustomImmediateApps() { store.set(try? JSONEncoder().encode(customImmediateApps), forKey: "customImmediateApps") }
}

private enum BackupEntry: Codable {
    case json(url: String, key: String, value: JSONValue?)
    case defaults(domain: String, key: String, value: JSONValue?)
    case text(url: String, key: String, value: String?)
}

private enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null
    init?(_ value: Any?) {
        guard let value else { return nil }
        switch value {
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as [Any]: self = .array(value.compactMap(JSONValue.init))
        case let value as [String: Any]: self = .object(value.compactMapValues(JSONValue.init))
        default: return nil
        }
    }
    var displayValue: String {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(format: "%.2f", value)
        case .bool(let value): return value ? "true" : "false"
        case .array, .object, .null: return "（已保存）"
        }
    }
    var foundationValue: Any {
        switch self {
        case .string(let value): value; case .number(let value): value; case .bool(let value): value
        case .array(let values): values.map(\.foundationValue); case .object(let values): values.mapValues(\.foundationValue); case .null: NSNull()
        }
    }
}
