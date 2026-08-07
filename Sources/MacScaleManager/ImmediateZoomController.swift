import AppKit
import ApplicationServices

enum ImmediateTarget: String, CaseIterable, Identifiable {
    case qq, wechat, codex, claude, notion, terminal

    var id: String { rawValue }
    var title: String {
        switch self {
        case .qq: "QQ"; case .wechat: "微信"; case .codex: "Codex"; case .claude: "Claude"; case .notion: "Notion"; case .terminal: "Terminal"
        }
    }
    var bundleIdentifier: String {
        switch self {
        case .qq: "com.tencent.qq"; case .wechat: "com.tencent.xinWeChat"; case .codex: "com.openai.codex"
        case .claude: "com.anthropic.claude"; case .notion: "notion.id"; case .terminal: "com.apple.Terminal"
        }
    }
}

enum CustomLaptopAction: String, Codable, CaseIterable, Identifiable {
    case reset, zoomOut
    var id: String { rawValue }
    var title: String { self == .reset ? "⌘0 重置" : "⌘- 缩小" }
}

struct CustomImmediateApp: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var bundleIdentifier: String
    var desktopZoomSteps: Int
    var laptopAction: CustomLaptopAction
    var resetBeforeDesktop: Bool?
    var launchDelaySeconds: Double?
    var shortcutIntervalSeconds: Double?
    var desktopLaunchDelay: TimeInterval { min(max(launchDelaySeconds ?? 2.0, 0.5), 10.0) }
}

/// Structured output lets the coordinator remember exactly which apps were
/// successfully synchronized, without inferring success from localized text.
struct ImmediateZoomResult {
    var changedNames: [String] = []
    var changedBundleIdentifiers: [String] = []
    var unavailableNames: [String] = []

    var summary: String {
        var parts: [String] = []
        if !changedNames.isEmpty { parts.append("即时应用：\(changedNames.joined(separator: "、"))") }
        if !unavailableNames.isEmpty { parts.append("未运行：\(unavailableNames.joined(separator: "、"))") }
        return parts.isEmpty ? "即时模式：没有选中的目标应用。" : parts.joined(separator: "；")
    }
}

struct ImmediateZoomController {
    static func requestAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func apply(mode: ScaleMode, targets: [ImmediateTarget], customTargets: [CustomImmediateApp] = [], zoomSteps: [String: Int] = [:], laptopActions: [String: String] = [:]) -> String {
        applyWithResult(mode: mode, targets: targets, customTargets: customTargets, zoomSteps: zoomSteps, laptopActions: laptopActions).summary
    }

    static func applyWithResult(mode: ScaleMode, targets: [ImmediateTarget], customTargets: [CustomImmediateApp] = [], zoomSteps: [String: Int] = [:], laptopActions: [String: String] = [:]) -> ImmediateZoomResult {
        guard AXIsProcessTrusted() else { return ImmediateZoomResult(unavailableNames: ["请在系统设置中授予 MacScaleManager 辅助功能权限"]) }
        let original = NSWorkspace.shared.frontmostApplication
        let applications = NSWorkspace.shared.runningApplications
        var result = ImmediateZoomResult()
        for target in targets {
            guard let application = applications.first(where: { $0.bundleIdentifier == target.bundleIdentifier }) else {
                result.unavailableNames.append(target.title)
                continue
            }
            application.activate(options: [.activateAllWindows])
            guard waitUntilFrontmost(application) else {
                result.unavailableNames.append("\(target.title)（无法置前）")
                continue
            }
            applyShortcut(for: target, application: application, mode: mode, desktopZoomSteps: zoomSteps[target.rawValue] ?? (target == .codex ? 3 : 2), laptopAction: CustomLaptopAction(rawValue: laptopActions[target.rawValue] ?? "reset") ?? .reset)
            result.changedNames.append(target.title)
            result.changedBundleIdentifiers.append(target.bundleIdentifier)
        }
        for target in customTargets {
            guard let application = applications.first(where: { $0.bundleIdentifier == target.bundleIdentifier }) else {
                result.unavailableNames.append(target.name)
                continue
            }
            application.activate(options: [.activateAllWindows])
            guard waitUntilFrontmost(application) else {
                result.unavailableNames.append("\(target.name)（无法置前）")
                continue
            }
            applyShortcut(for: target, mode: mode)
            result.changedNames.append(target.name)
            result.changedBundleIdentifiers.append(target.bundleIdentifier)
        }
        if let original { original.activate(options: [.activateAllWindows]) }
        return result
    }

    private static func applyShortcut(for target: ImmediateTarget, application: NSRunningApplication, mode: ScaleMode, desktopZoomSteps: Int, laptopAction: CustomLaptopAction) {
        if mode == .laptop {
            if laptopAction == .zoomOut {
                for _ in 0..<max(1, desktopZoomSteps) { postShortcut(keyCode: 0x1B) }
            } else {
                postShortcut(keyCode: 0x1D)
            }
        } else {
            let interval: TimeInterval = target == .codex ? 0.28 : 0.25
            for _ in 0..<min(max(desktopZoomSteps, 1), 6) { postShortcut(keyCode: 0x18, settleInterval: interval) }
        }
    }

    private static func applyShortcut(for target: CustomImmediateApp, mode: ScaleMode) {
        if mode == .laptop {
            if target.laptopAction == .reset { postShortcut(keyCode: 0x1D) }
            else { postShortcut(keyCode: 0x1B) }
        } else {
            if target.resetBeforeDesktop ?? false { postShortcut(keyCode: 0x1D) }
            let interval = min(max(target.shortcutIntervalSeconds ?? 0.25, 0.1), 1.0)
            for _ in 0..<max(1, target.desktopZoomSteps) { postShortcut(keyCode: 0x18, settleInterval: interval) }
        }
    }

    private static func waitUntilFrontmost(_ application: NSRunningApplication) -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private static func postShortcut(keyCode: CGKeyCode, flags: CGEventFlags = .maskCommand, settleInterval: TimeInterval = 0.25) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(settleInterval))
    }
}
