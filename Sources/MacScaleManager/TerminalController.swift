import AppKit
import Foundation

@MainActor
enum TerminalController {
    private static let domain = "com.apple.Terminal"
    private static let terminalDefaults = UserDefaults(suiteName: domain)!

    static func currentFontSize() -> Double? {
        guard let font = defaultProfileFont() else { return nil }
        return Double(font.pointSize)
    }

    static func setDefaultFontSize(_ size: Double) throws {
        let liveScript = "tell application \"Terminal\" to set font size of default settings to \(Int(size.rounded()))"
        guard var preferences = terminalDefaults.persistentDomain(forName: domain),
              let profileName = preferences["Default Window Settings"] as? String,
              var profiles = preferences["Window Settings"] as? [String: Any],
              var profile = profiles[profileName] as? [String: Any],
              let font = font(from: profile),
              let resized = NSFont(name: font.fontName, size: CGFloat(size)) else {
            throw PreferenceError.systemCommandFailed("无法读取 Terminal 默认 Profile 的字体配置。")
        }
        profile["Font"] = try NSKeyedArchiver.archivedData(withRootObject: resized, requiringSecureCoding: false)
        profiles[profileName] = profile
        preferences["Window Settings"] = profiles
        terminalDefaults.setPersistentDomain(preferences, forName: domain)
        terminalDefaults.synchronize()
        if isRunning { try? runAppleScript(liveScript) }
    }

    private static var isRunning: Bool { NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Terminal" } }

    private static func runAppleScript(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw PreferenceError.systemCommandFailed("无法创建 Terminal 自动化脚本。")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            throw PreferenceError.systemCommandFailed(error[NSAppleScript.errorMessage] as? String ?? "Terminal 自动化失败")
        }
        return result.stringValue ?? ""
    }

    private static func defaultProfileFont() -> NSFont? {
        guard let preferences = terminalDefaults.persistentDomain(forName: domain),
              let profileName = preferences["Default Window Settings"] as? String,
              let profiles = preferences["Window Settings"] as? [String: Any],
              let profile = profiles[profileName] as? [String: Any] else { return nil }
        return font(from: profile)
    }

    private static func font(from profile: [String: Any]) -> NSFont? {
        guard let data = profile["Font"] as? Data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data)
    }
}
