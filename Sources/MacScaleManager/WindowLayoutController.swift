import AppKit
import ApplicationServices

enum WindowLayoutResult {
    case changed
    case skipped(String)
    case failed(String)
}

enum FollowingWindowResult {
    case changed, skipped(String), failed(String), deferred(String)
}

/// Batch layouts preserve native full-screen windows. The centered style also
/// preserves filled windows; the left-gap style can rearrange them explicitly.
/// Manual sync may leave full-screen; minimized/non-resizable windows stay put.
@MainActor
enum WindowLayoutController {
    /// Background screen following never activates the app, exits full-screen,
    /// or selects a different window. Match the observed frame and revalidate
    /// it immediately before writing; a stale/moved/ambiguous window is skipped.
    static func applyFollowing(to application: NSRunningApplication,
                               request: FollowingWindowRequest) -> FollowingWindowResult {
        guard AXIsProcessTrusted() else { return .failed("未授予辅助功能权限") }
        guard application.processIdentifier == request.window.processID, !application.isTerminated else {
            return .skipped("应用已退出")
        }
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return .deferred("暂时无法读取应用窗口，等待重新采样") }
        let matches = windows.filter { window in
            guard let frame = quartzFrame(of: window) else { return false }
            return AutomaticWindowLayoutPolicy.nearlyEqual(frame, request.window.frame, tolerance: 3)
        }
        guard matches.count == 1, let window = matches.first else {
            return matches.isEmpty ? .deferred("窗口已变化，等待重新采样") : .skipped("无法唯一识别窗口")
        }
        guard let nativeFullScreen = nativeFullScreenState(window) else { return .skipped("无法确认原生全屏状态，未调整") }
        guard !nativeFullScreen else { return .skipped("保留原生全屏") }
        guard boolAttribute(kAXMinimizedAttribute as CFString, of: window) != true else { return .skipped("窗口已最小化") }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
              subrole as? String == kAXStandardWindowSubrole as String else { return .skipped("不是普通应用窗口") }
        guard isSettable(kAXSizeAttribute as CFString, of: window),
              request.preservePosition || isSettable(kAXPositionAttribute as CFString, of: window) else {
            return .skipped("应用不允许调整此窗口")
        }
        let snapshot = ScreenScalingSnapshot.capture()
        let displays = snapshot.displays
        guard let current = quartzFrame(of: window),
              snapshot.layoutWorkAreaStable,
              AutomaticWindowLayoutPolicy.nearlyEqual(current, request.window.frame, tolerance: 3),
              let display = displays.first(where: { $0.id == request.display.id }),
              display == request.display,
              ScreenScalingPolicy.display(for: current, displays: displays)?.id == display.id else {
            return .deferred("屏幕或窗口已变化，等待重新计算")
        }
        var size = request.targetFrame.size
        guard let windowSize = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, windowSize) == .success else {
            return .failed("应用拒绝窗口尺寸请求")
        }
        // For ordinary windows, do not send AXPosition at all. The app/OS may
        // still constrain its own frame, but we never recenter it or restore an
        // old source-screen position. Filled windows must follow the usable
        // origin as well when a Dock moves to the left/top edge.
        let afterSize = quartzFrame(of: window) ?? current
        if CommandLine.arguments.contains("--diagnose-work-area") {
            print("AX-SIZE pid=\(application.processIdentifier) requested=\(size) actual=\(afterSize)")
            fflush(stdout)
        }
        if request.needsPositionWrite(current: afterSize) {
            var origin = request.targetFrame.origin
            guard let position = AXValueCreate(.cgPoint, &origin),
                  AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success else {
                return .failed("应用拒绝可用区域位置请求")
            }
            // A position write can reconstrain the frame to the application's
            // stale screen work area. Reapply size once after moving, not in a
            // recurring retry loop. Unchanged positions never get written.
            if let positioned = quartzFrame(of: window),
               abs(positioned.width - size.width) > 3 || abs(positioned.height - size.height) > 3 {
                _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, windowSize)
            }
        }
        guard let actual = quartzFrame(of: window) else { return .failed("无法确认窗口调整结果") }
        guard abs(actual.width - size.width) <= 3, abs(actual.height - size.height) <= 3 else {
            return .failed("应用限制了窗口尺寸（目标 \(Int(size.width))×\(Int(size.height))，实际 \(Int(actual.width))×\(Int(actual.height))）")
        }
        guard abs(actual.minX - request.targetFrame.minX) <= 3,
              abs(actual.minY - request.targetFrame.minY) <= 3 else {
            return .failed(request.preservePosition ? "尺寸已调整，但应用或系统自行约束了窗口位置" : "应用限制了窗口位置，未完全适应可用区域")
        }
        return .changed
    }

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
        let snapshot = ScreenScalingSnapshot.capture()
        guard snapshot.layoutWorkAreaStable else { return .skipped("Dock 正在变化，请稍后重试") }
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let visible = snapshot.displays.first { $0.id == displayID }.map {
            CGRect(x: $0.usableFrame.minX, y: desktopTop - $0.usableFrame.maxY,
                   width: $0.usableFrame.width, height: $0.usableFrame.height)
        } ?? screen.visibleFrame
        let frame = WindowLayoutGeometry.frame(screen: screen.frame, visible: visible,
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
        nativeFullScreenState(window) ?? true
    }

    private static func nativeFullScreenState(_ window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &value)
        let flag = (value as? NSNumber)?.boolValue
        if result == .success && flag == true { return true }
        // A timeout/stale element is not evidence of being windowed. Some
        // applications do not expose AXFullScreen; only for an unsupported
        // attribute may the subrole serve as the fallback.
        guard (result == .success && flag != nil) || result == .attributeUnsupported else { return nil }
        var subroleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue) == .success,
           let subrole = subroleValue as? String {
            return subrole == "AXFullScreenWindow"
        }
        return result == .success ? flag : nil
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

    static func quartzFrame(of window: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &value) == .success,
              let value, let size = size(of: window) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static var desktopTop: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }
}
