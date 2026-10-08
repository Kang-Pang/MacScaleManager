import Foundation
import CoreGraphics

enum DockEdge: String { case bottom, left, right }

/// Live size getters can update before the Dock container animation finishes.
/// Require repeated matching geometry, not just an elapsed time since the SPI.
struct DockBoundsSettler {
    private var candidate: CGRect?
    private var candidateSince: TimeInterval?

    mutating func observe(_ bounds: CGRect?, now: TimeInterval) -> Bool {
        guard let since = candidateSince, candidate == bounds else {
            candidate = bounds; candidateSince = now
            return false
        }
        return now - since >= 0.5
    }
}

enum DockWorkAreaGeometry {
    /// Quartz coordinates. Keep the system's menu/notch inset, but reserve a
    /// Dock inset ONLY on its actual host screen. Dock-less screens fill down
    /// to their physical bottom instead of inheriting a stale Dock reservation.
    static func usableFrame(display: ScalingDisplay, dockHost: UInt32,
                            edge: DockEdge, dockBounds: CGRect?, autoHidden: Bool) -> CGRect {
        let screen = display.frame
        let native = display.usableFrame
        let top = max(screen.minY, native.minY)
        var area = CGRect(x: screen.minX, y: top, width: screen.width, height: max(1, screen.maxY - top))
        guard display.id == dockHost else { return area }
        guard !autoHidden, let bounds = dockBounds, !bounds.intersection(screen).isNull else { return native }
        // AXList describes the Dock container, not only the icon image size.
        // Do not add another visible gap above/beside that boundary.
        let margin: CGFloat = 0
        switch edge {
        case .bottom: area.size.height = max(1, min(area.maxY, bounds.minY - margin) - area.minY)
        case .left:
            let left = max(area.minX, bounds.maxX + margin)
            area = CGRect(x: left, y: area.minY, width: max(1, area.maxX - left), height: area.height)
        case .right: area.size.width = max(1, min(area.maxX, bounds.minX - margin) - area.minX)
        }
        return area
    }
}
