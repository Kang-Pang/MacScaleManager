import Foundation
import CoreGraphics

struct AutomaticScreenScaling: Codable, Equatable {
    var applications: Bool = false
    var dock: Bool = false
    var restartConfigurationApplications: Bool?
    var allowsConfigurationRestart: Bool { restartConfigurationApplications ?? false }
}

/// All frames use Quartz desktop coordinates, including displays above/left
/// of the primary display. No mouse-position or main-screen guessing.
struct ScalingDisplay: Equatable {
    let id: UInt32
    let frame: CGRect
    let builtIn: Bool
    let visibleFrame: CGRect?

    init(id: UInt32, frame: CGRect, builtIn: Bool, visibleFrame: CGRect? = nil) {
        self.id = id; self.frame = frame; self.builtIn = builtIn; self.visibleFrame = visibleFrame
    }

    var usableFrame: CGRect { visibleFrame ?? frame }
}

enum ScreenScalingPolicy {
    static func display(for window: CGRect, displays: [ScalingDisplay]) -> ScalingDisplay? {
        guard window.width > 0, window.height > 0 else { return nil }
        let ranked = displays.map { display in
            let intersection = window.intersection(display.frame)
            return (display, intersection.isNull ? 0 : intersection.width * intersection.height)
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 > 0 else { return nil }
        // An exactly straddling window has no unambiguous destination yet.
        if ranked.count > 1 && abs(best.1 - ranked[1].1) < 1 { return nil }
        return best.0
    }

    static func normalizedDockSize(_ points: Int) -> Float {
        Float(min(max(points, 16), 128) - 16) / 112
    }
}

enum ScreenPromptPlacement {
    /// AppKit coordinates, using the destination screen's usable frame rather
    /// than NSScreen.main (which follows keyboard focus, not the moved app).
    static func frame(size: CGSize, visibleFrame: CGRect) -> CGRect {
        let width = min(size.width, visibleFrame.width)
        let height = min(size.height, visibleFrame.height)
        return CGRect(x: visibleFrame.midX - width / 2,
                      y: visibleFrame.midY - height / 2, width: width, height: height)
    }
}

struct StableScreenCandidate: Equatable {
    let displayID: UInt32
    let frame: CGRect
}

struct ScreenStabilityTracker {
    private var candidates: [String: (StableScreenCandidate, TimeInterval)] = [:]

    mutating func ready(key: String, candidate: StableScreenCandidate, now: TimeInterval,
                        mouseDown: Bool, delay: TimeInterval = 0.5) -> Bool {
        guard !mouseDown else { candidates.removeValue(forKey: key); return false }
        guard let previous = candidates[key], previous.0 == candidate else {
            candidates[key] = (candidate, now)
            return false
        }
        return now - previous.1 >= delay
    }

    mutating func retain(keys: Set<String>) { candidates = candidates.filter { keys.contains($0.key) } }
    mutating func reset() { candidates.removeAll() }
}
