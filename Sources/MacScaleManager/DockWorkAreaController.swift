import AppKit
import ApplicationServices

/// Reconciles AppKit's sometimes delayed work area with the actual Dock
/// container. AX is read briefly until matching bounds confirm that a
/// host/size/orientation transition has settled, then cached while idle.
/// Never activates Dock or another app.
@MainActor
final class DockWorkAreaController {
    static let shared = DockWorkAreaController()
    private struct Signature: Equatable {
        let displays: [ScalingDisplay]
        let host: UInt32
        let processID: pid_t
        let points: Int?
        let edge: DockEdge
        let autoHidden: Bool
    }
    private let dock = LiveDockSizeController()
    private let preferences = UserDefaults(suiteName: "com.apple.dock")
    private var signature: Signature?
    private var changedAt: TimeInterval = 0
    private var measured = false
    private var bounds: CGRect?
    private var lastAttempt: TimeInterval = -.infinity
    private var boundsSettler = DockBoundsSettler()

    var diagnosticDescription: String {
        "dockContainer=\(bounds.map { String(describing: $0) } ?? "native-fallback") measured=\(measured)"
    }

    func resolve(displays: [ScalingDisplay], dockFrame: CGRect?, dockPID: pid_t?) -> (displays: [ScalingDisplay], stable: Bool) {
        guard let dockFrame, let dockPID,
              let host = ScreenScalingPolicy.display(for: dockFrame, displays: displays) else {
            // Dock's CG surface may disappear for a frame during a transition.
            // Never apply the stale native fallback as a new settled layout.
            return (displays, false)
        }
        let edge = DockEdge(rawValue: preferences?.string(forKey: "orientation") ?? "bottom") ?? .bottom
        let autoHidden = preferences?.bool(forKey: "autohide") ?? false
        let next = Signature(displays: displays, host: host.id, processID: dockPID, points: dock.currentPoints, edge: edge, autoHidden: autoHidden)
        let now = ProcessInfo.processInfo.systemUptime
        if next != signature {
            signature = next; changedAt = now; measured = false; bounds = nil; lastAttempt = -.infinity
            boundsSettler = DockBoundsSettler()
        }
        guard now - changedAt >= 0.75 else { return (displays, false) }
        if (!measured && now - lastAttempt >= 0.5) || (measured && bounds == nil && now - lastAttempt >= 5) {
            let sample = Self.readDockBounds(processID: dockPID, display: host, edge: edge)
            measured = boundsSettler.observe(sample, now: now)
            bounds = sample; lastAttempt = now
        }
        guard measured else { return (displays, false) }
        let result = displays.map { display in
            ScalingDisplay(id: display.id, frame: display.frame, builtIn: display.builtIn,
                visibleFrame: DockWorkAreaGeometry.usableFrame(display: display, dockHost: host.id,
                    edge: edge, dockBounds: bounds, autoHidden: autoHidden))
        }
        return (result, true)
    }

    static func readDockBounds(processID: pid_t, display: ScalingDisplay, edge: DockEdge) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var nodes: [(AXUIElement, Int)] = [(app, 0)]
        var rectangles: [CGRect] = []
        var visited = 0
        while let (node, depth) = nodes.popLast(), visited < 32 {
            visited += 1
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &value) == .success,
               value as? String == kAXListRole as String {
                if let frame = frame(of: node), isDockContainer(frame, display: display, edge: edge) { rectangles.append(frame) }
                // Do not enumerate icon names or contents; only the container
                // frame matters, and descending into each icon wastes AX calls.
                continue
            }
            guard depth < 3, AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
                  let children = value as? [AXUIElement] else { continue }
            nodes += children.prefix(16).map { ($0, depth + 1) }
        }
        return rectangles.max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func isDockContainer(_ frame: CGRect, display: ScalingDisplay, edge: DockEdge) -> Bool {
        let screen = display.frame
        guard frame.width > 0, frame.height > 0, !frame.intersection(screen).isNull else { return false }
        switch edge {
        case .bottom: return frame.width > frame.height && frame.height < screen.height * 0.4 && frame.midY > screen.midY
        case .left: return frame.height > frame.width && frame.width < screen.width * 0.4 && frame.midX < screen.midX
        case .right: return frame.height > frame.width && frame.width < screen.width * 0.4 && frame.midX > screen.midX
        }
    }
}
