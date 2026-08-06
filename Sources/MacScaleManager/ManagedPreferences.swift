import AppKit
import Foundation
import Combine

enum PreferenceError: LocalizedError {
    case unreadableFile(URL)
    case invalidJSON(URL)
    case systemCommandFailed(String)
    case applicationRunning(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let url): "无法读取配置文件：\(url.path)"
        case .invalidJSON(let url): "配置文件不是有效 JSON：\(url.path)"
        case .systemCommandFailed(let message): message
        case .applicationRunning(let name): "请先完全退出 \(name) 后再切换模式；运行中的浏览器会覆盖其配置文件。"
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
     var immediateTerminal: Bool { didSet { store.set(immediateTerminal, forKey: "immediateTerminal") } }
     var immediateZoomSteps: [String: Int] { didSet { saveImmediateZoomSteps() } }
    @Published var customProfile: ScaleProfile { didSet { saveCustomProfile() } }
    @Published var customImmediateApps: [CustomImmediateApp] { didSet { saveCustomImmediateApps() } }

    private let store = UserDefaults.standard
    private let backupKey = "managedPreferenceBackupsV1"
    private let baselineKey = "hasEstablishedLaptopBaselineV1"

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
        if let data = store.data(forKey: "customProfile"), let profile = try? JSONDecoder().decode(ScaleProfile.self, from: data) {
            customProfile = profile
        } else { customProfile = .desktop }
        if let data = store.data(forKey: "customImmediateApps"), let apps = try? JSONDecoder().decode([CustomImmediateApp].self, from: data) {
            customImmediateApps = apps
        } else { customImmediateApps = [] }
    }

    var immediateTargets: [ImmediateTarget] {
        [immediateQQ ? .qq : nil, immediateWeChat ? .wechat : nil, immediateCodex ? .codex : nil,
         immediateClaude ? .claude : nil, immediateNotion ? .notion : nil, immediateTerminal ? .terminal : nil].compactMap { $0 }
    }

    func zoomSteps(for target: ImmediateTarget) -> Int { max(1, immediateZoomSteps[target.rawValue] ?? (target == .codex ? 3 : 2)) }

    func setZoomSteps(_ count: Int, for target: ImmediateTarget) { immediateZoomSteps[target.rawValue] = min(max(count, 1), 6) }

    private func saveImmediateZoomSteps() { store.set(immediateZoomSteps, forKey: "immediateZoomSteps") }

    private func saveCustomImmediateApps() {
        guard let data = try? JSONEncoder().encode(customImmediateApps) else { return }
        store.set(data, forKey: "customImmediateApps")
    }

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
        // Chromium keeps Preferences in memory and rewrites the file on exit.
        // Writing it while the browser is open makes a successful-looking change
        // disappear, so fail before touching any managed configuration.
        if manageChrome { try ensureNotRunning(bundleIdentifier: "com.google.Chrome", name: "Google Chrome") }
        if manageEdge { try ensureNotRunning(bundleIdentifier: "com.microsoft.edgemac", name: "Microsoft Edge") }
        if manageZotero { try ensureNotRunning(bundleIdentifier: "org.zotero.zotero", name: "Zotero") }
        if manageNotion { try ensureNotRunning(bundleIdentifier: "notion.id", name: "Notion") }
        if manageClaude { try ensureNotRunning(bundleIdentifier: "com.anthropic.claude", name: "Claude") }
        if manageCodex { try ensureNotRunning(bundleIdentifier: "com.openai.codex", name: "Codex") }
        if manageVSCode { try updateVSCode(profile, captureBackups: captureBackups) }
        if manageChrome { try updateChromium(named: "Google/Chrome", profile: profile, captureBackups: captureBackups) }
        if manageEdge { try updateChromium(named: "Microsoft Edge", profile: profile, captureBackups: captureBackups) }
        if manageDock { try setDefault(domain: "com.apple.dock", key: "tilesize", value: profile.dockSize, captureBackups: captureBackups) }
        if manageCursor { try setDefault(domain: "com.apple.universalaccess", key: "mouseDriverCursorSize", value: profile.cursorSize, captureBackups: captureBackups) }
        if manageZotero { try updateZotero(profile, captureBackups: captureBackups) }
        if manageNotion { try updateElectron(profile, preferencesURL: home("Library/Application Support/Notion/Preferences"), captureBackups: captureBackups, updateExistingHosts: true) }
        if manageClaude { try updateElectron(profile, preferencesURL: home("Library/Application Support/Claude-3p/Preferences"), captureBackups: captureBackups, updateExistingHosts: false) }
        if manageCodex { try updateElectron(profile, preferencesURL: home("Library/Application Support/Codex/Default/Preferences"), captureBackups: captureBackups, updateExistingHosts: false) }
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

    func restoreOrApplyLaptopDefaults() throws {
        // Do not capture a possibly half-applied value as the initial backup.
        if !store.bool(forKey: baselineKey) {
            saveBackups([:])
            try apply(profile: .laptop, captureBackups: false)
            store.set(true, forKey: baselineKey)
        } else if loadBackups().isEmpty {
            try apply(profile: .laptop, captureBackups: false)
        } else {
            try restore()
        }
        if manageDock { try setDefault(domain: "com.apple.dock", key: "tilesize", value: ScaleProfile.laptop.dockSize, captureBackups: false) }
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
    private func saveCustomProfile() { store.set(try? JSONEncoder().encode(customProfile), forKey: "customProfile") }
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
    var foundationValue: Any {
        switch self {
        case .string(let value): value; case .number(let value): value; case .bool(let value): value
        case .array(let values): values.map(\.foundationValue); case .object(let values): values.mapValues(\.foundationValue); case .null: NSNull()
        }
    }
}
