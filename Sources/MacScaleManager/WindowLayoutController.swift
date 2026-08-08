import AppKit
import ApplicationServices

enum WindowLayoutResult {
    case changed
    case skipped(String)
    case failed(String)
}

/// Resizes only normal Accessibility windows. Full-screen, minimized and
/// non-resizable windows are left untouched so layout never breaks a user's
/// presentation, Split View, or an app-owned window arrangement.
enum WindowLayoutController {
    static func apply(to application: NSRunningApplication, sizeFraction: CGFloat, force: Bool = false) -> WindowLayoutResult {
        guard AXIsProcessTrusted() else { return .failed("未授予辅助功能权限") }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = focusedWindow(of: appElement) else { return .skipped("没有可调整的窗口") }

        if !force && isFullScreen(window) { return .skipped("窗口处于全屏或最大化状态") }
        if force && boolAttribute("AXFullScreen" as CFString, of: window) == true {
            guard isSettable("AXFullScreen" as CFString, of: window) else { return .failed("应用不允许退出原生全屏") }
            guard AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse) == .success else {
                return .failed("无法退出原生全屏")
            }
        }
        if boolAttribute(kAXMinimizedAttribute as CFString, of: window) == true { return .skipped("窗口已最小化") }
        guard isSettable(kAXPositionAttribute as CFString, of: window),
              isSettable(kAXSizeAttribute as CFString, of: window) else {
            return .skipped("应用不允许调整此窗口")
        }

        guard let screen = targetScreen(for: window) else { return .failed("无法确定目标屏幕") }
        let fraction = min(max(sizeFraction, 0.3), 1.0)
        let frame = screen.visibleFrame
        var size = CGSize(width: floor(frame.width * fraction), height: floor(frame.height * fraction))
        let appKitOrigin = CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2)
        // Accessibility uses a top-left desktop origin, while AppKit uses a
        // bottom-left origin. Convert before sending the AX position.
        var origin = CGPoint(x: appKitOrigin.x, y: desktopTop - appKitOrigin.y - size.height)
        guard let position = AXValueCreate(.cgPoint, &origin),
              let windowSize = AXValueCreate(.cgSize, &size) else { return .failed("无法生成窗口尺寸") }
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, windowSize)
        return positionResult == .success && sizeResult == .success ? .changed : .failed("应用拒绝了窗口尺寸请求")
    }

    private static func focusedWindow(of application: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
           let window = value as! AXUIElement? { return window }
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first
    }

    private static func boolAttribute(_ attribute: CFString, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }

    private static func isSettable(_ attribute: CFString, of element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success && settable.boolValue
    }

    private static func targetScreen(for window: AXUIElement) -> NSScreen? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
           let value {
            let axValue = value as! AXValue
            var point = CGPoint.zero
            if AXValueGetValue(axValue, .cgPoint, &point),
               let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: point.x, y: desktopTop - point.y)) }) { return screen }
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        if boolAttribute("AXFullScreen" as CFString, of: window) == true { return true }
        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String,
           subrole == "AXFullScreenWindow" { return true }
        guard let screen = targetScreen(for: window), let size = size(of: window) else { return false }
        // Dragging a macOS window to the top uses the "zoom/fill" state rather
        // than AXFullScreen. It fills visibleFrame (excluding menu bar/Dock),
        // so compare with that area instead of the physical screen frame.
        let visible = screen.visibleFrame
        return size.width >= visible.width - 8 && size.height >= visible.height - 8
    }

    private static func size(of window: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let value else { return nil }
        let axValue = value as! AXValue
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static var desktopTop: CGFloat {
        NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
    }
}
