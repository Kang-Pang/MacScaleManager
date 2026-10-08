import AppKit
import ApplicationServices

enum WindowLayoutResult {
    case changed
    case skipped(String)
    case failed(String)
}

/// Batch layouts preserve native full-screen windows. The centered style also
/// preserves filled windows; the left-gap style can rearrange them explicitly.
/// Manual sync may leave full-screen; minimized/non-resizable windows stay put.
enum WindowLayoutController {
    /// Reopening a quit-required app may lose its display placement. Restore
    /// only its former position, not its size or native full-screen state.
    static func restorePosition(of application: NSRunningApplication, origin: CGPoint) -> Bool {
        guard AXIsProcessTrusted(), let window = focusedWindow(of: AXUIElementCreateApplication(application.processIdentifier)),
              !isNativeFullScreen(window), isSettable(kAXPositionAttribute as CFString, of: window) else { return false }
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
    }

    static func apply(to application: NSRunningApplication, adapter: ExternalWindowLayoutAdapter,
                      force: Bool = false) -> WindowLayoutResult {
        apply(to: application, sizeFraction: adapter.sizeFraction, style: adapter.style,
              leftGapFraction: adapter.leftGapFraction, force: force)
    }

    static func apply(to application: NSRunningApplication, sizeFraction: CGFloat,
                      style: WindowLayoutStyle = .centered, leftGapFraction: CGFloat = 0.1,
                      force: Bool = false) -> WindowLayoutResult {
        guard AXIsProcessTrusted() else { return .failed("未授予辅助功能权限") }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        guard let window = focusedWindow(of: appElement) else { return .skipped("没有可调整的窗口") }

        if !force && (isNativeFullScreen(window) || (style == .centered && isFullScreen(window))) {
            return .skipped("窗口处于全屏或最大化状态")
        }
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
        let frame = WindowLayoutGeometry.frame(screen: screen.frame, visible: screen.visibleFrame,
                                              style: style, sizeFraction: sizeFraction,
                                              leftGapFraction: leftGapFraction)
        var size = frame.size
        // Accessibility uses a top-left desktop origin, while AppKit uses a
        // bottom-left origin. Convert before sending the AX position.
        var origin = CGPoint(x: frame.minX, y: desktopTop - frame.maxY)
        guard let position = AXValueCreate(.cgPoint, &origin),
              let windowSize = AXValueCreate(.cgSize, &size) else { return .failed("无法生成窗口尺寸") }
        // Shrink before moving so an old full-width window can move right
        // without macOS clamping its origin against the screen's right edge.
        let sizeResult = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, windowSize)
        let positionResult = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
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

    private static func isNativeFullScreen(_ window: AXUIElement) -> Bool {
        if boolAttribute("AXFullScreen" as CFString, of: window) == true { return true }
        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String,
           subrole == "AXFullScreenWindow" { return true }
        return false
    }

    private static func isFullScreen(_ window: AXUIElement) -> Bool {
        if isNativeFullScreen(window) { return true }
        guard let screen = targetScreen(for: window), let size = size(of: window) else { return false }
        // Dragging a macOS window to the top uses the "zoom/fill" state rather
        // than AXFullScreen. Chromium-style title bars and multi-display
        // coordinate rounding can leave a few pixels of variance, so treat a
        // window that is effectively filling visibleFrame as protected too.
        let visible = screen.visibleFrame
        return size.width >= visible.width * 0.96 && size.height >= visible.height * 0.90
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
