import Foundation
import CoreGraphics

enum WindowLayoutStyle: String, Codable, CaseIterable, Identifiable {
    case centered
    case fillWithLeftGap

    var id: String { rawValue }
    var title: String {
        switch self {
        case .centered: "按比例居中"
        case .fillWithLeftGap: "填满屏幕，左侧留空"
        }
    }
}

/// Pure AppKit-coordinate geometry, shared with the command-line regression test.
enum WindowLayoutGeometry {
    static func frame(screen: CGRect, visible: CGRect, style: WindowLayoutStyle,
                      sizeFraction: CGFloat, leftGapFraction: CGFloat) -> CGRect {
        if style == .fillWithLeftGap {
            // Measure the gap from the physical screen edge. A left-side Dock
            // or Stage Manager inset must not be added a second time.
            let gap = min(max(leftGapFraction, 0), 0.4)
            let left = max(visible.minX, screen.minX + floor(screen.width * gap))
            return CGRect(x: left, y: visible.minY,
                          width: max(1, visible.maxX - left), height: visible.height)
        }
        let fraction = min(max(sizeFraction, 0.3), 1)
        let width = floor(visible.width * fraction)
        let height = floor(visible.height * fraction)
        return CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2,
                      width: width, height: height)
    }
}
