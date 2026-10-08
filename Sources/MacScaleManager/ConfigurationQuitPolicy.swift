import Foundation

/// A shared policy for both preflight and the final write guard. VS Code
/// watches settings.json, whereas the browsers cache preferences in memory.
enum ConfigurationQuitPolicy {
    static func requiresQuit(for key: String, overrides: [String: Bool]?) -> Bool {
        overrides?[key] ?? ["chrome", "edge", "zotero", "notion", "claude", "codex"].contains(key)
    }
}
