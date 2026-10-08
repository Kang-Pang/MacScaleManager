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
    private struct ShortcutRequest {
        let name: String
        let bundleIdentifier: String
        let perform: () -> Bool
    }

    static func requestAccessibilityPermission() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func apply(mode: ScaleMode, targets: [ImmediateTarget], customTargets: [CustomImmediateApp] = [], zoomSteps: [String: Int] = [:], laptopActions: [String: String] = [:]) -> String {
        applyWithResult(mode: mode, targets: targets, customTargets: customTargets, zoomSteps: zoomSteps, laptopActions: laptopActions).summary
    }

    static func applyWithResult(mode: ScaleMode, targets: [ImmediateTarget], customTargets: [CustomImmediateApp] = [], zoomSteps: [String: Int] = [:], laptopActions: [String: String] = [:], foregroundOnly: Bool = false) -> ImmediateZoomResult {
        guard AXIsProcessTrusted() else { return ImmediateZoomResult(unavailableNames: ["请在系统设置中授予 MacScaleManager 辅助功能权限"]) }
        let original = NSWorkspace.shared.frontmostApplication
        let applications = NSWorkspace.shared.runningApplications
        var result = ImmediateZoomResult()
        let requests = targets.map { target in
            ShortcutRequest(name: target.title, bundleIdentifier: target.bundleIdentifier) {
                applyShortcut(
                    for: target,
                    mode: mode,
                    desktopZoomSteps: zoomSteps[target.rawValue] ?? (target == .codex ? 3 : 2),
                    laptopAction: CustomLaptopAction(rawValue: laptopActions[target.rawValue] ?? "reset") ?? .reset
                )
                return true
            }
        } + customTargets.map { target in
            ShortcutRequest(name: target.name, bundleIdentifier: target.bundleIdentifier) {
                applyShortcut(for: target, mode: mode, expectedPID: foregroundOnly ? original?.processIdentifier : nil)
            }
        }
        for request in requests {
            guard let application = applications.first(where: { $0.bundleIdentifier == request.bundleIdentifier }) else {
                result.unavailableNames.append(request.name)
                continue
            }
            guard foregroundOnly ? (NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier) : focusForKeyboardInput(application) else {
                result.unavailableNames.append("\(request.name)（无法置前）")
                continue
            }
            guard request.perform() else {
                result.unavailableNames.append("\(request.name)（焦点或鼠标状态变化，已停止）")
                continue
            }
            result.changedNames.append(request.name)
            result.changedBundleIdentifiers.append(request.bundleIdentifier)
        }
        if !foregroundOnly, let original { original.activate(options: [.activateAllWindows]) }
        return result
    }

    private static func applyShortcut(for target: ImmediateTarget, mode: ScaleMode, desktopZoomSteps: Int, laptopAction: CustomLaptopAction) {
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

    private static func applyShortcut(for target: CustomImmediateApp, mode: ScaleMode, expectedPID: pid_t? = nil) -> Bool {
        let interval = min(max(target.shortcutIntervalSeconds ?? 0.25, 0.1), 1.0)
        func send(_ code: CGKeyCode) -> Bool {
            if let expectedPID {
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID,
                      !CGEventSource.buttonState(.combinedSessionState, button: .left),
                      !CGEventSource.buttonState(.combinedSessionState, button: .right) else { return false }
            }
            postShortcut(keyCode: code, settleInterval: interval)
            return true
        }
        if mode == .laptop {
            if target.laptopAction == .reset { return send(0x1D) }
            else {
                for _ in 0..<min(max(0, target.desktopZoomSteps), 6) { if !send(0x1B) { return false } }
            }
        } else {
            if target.resetBeforeDesktop ?? false, !send(0x1D) { return false }
            for _ in 0..<min(max(0, target.desktopZoomSteps), 6) { if !send(0x18) { return false } }
        }
        return true
    }

    private static func waitUntilFrontmost(_ application: NSRunningApplication) -> Bool {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return false
    }

    private static func focusForKeyboardInput(_ application: NSRunningApplication) -> Bool {
        // A menu-bar app is normally frontmost at this point. Merely raising a
        // window is not enough: the app must own the keyboard focus before CG
        // keyboard events are posted (Terminal is particularly strict about it).
        application.activate(options: [.activateAllWindows])
        let element = AXUIElementCreateApplication(application.processIdentifier)
        _ = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let window = focusedWindow as! AXUIElement? {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        guard waitUntilFrontmost(application) else { return false }
        // Let the target's event loop install the focused responder before the
        // first shortcut. This is intentionally longer than the inter-key delay.
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
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
