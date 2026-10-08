import AppKit
import CoreGraphics
import Darwin

struct ScreenScalingSnapshot {
    let displays: [ScalingDisplay]
    let applications: [pid_t: CGRect]
    let dockFrame: CGRect?
    let layoutWindows: [FollowingWindowSample]
    let layoutWorkAreaStable: Bool

    @MainActor
    static func captureDisplays() -> [ScalingDisplay] {
        let screens = NSScreen.screens
        // AppKit's origin is bottom-left of the primary display, not of the
        // highest display. Quartz/AX coordinates are top-left of the primary.
        let primaryTop = screens.first?.frame.maxY ?? 0
        return screens.compactMap { screen -> ScalingDisplay? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            let visible = screen.visibleFrame
            return ScalingDisplay(id: id, frame: CGDisplayBounds(id), builtIn: CGDisplayIsBuiltin(id) != 0,
                                  visibleFrame: CGRect(x: visible.minX, y: primaryTop - visible.maxY,
                                                       width: visible.width, height: visible.height))
        }
    }

    @MainActor
    static func capture(includeOffscreen: Bool = false) -> Self {
        let displays = captureDisplays()
        let dockPID = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier
        let windows = CGWindowListCopyWindowInfo(includeOffscreen ? .optionAll : .optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var applications: [pid_t: CGRect] = [:]
        var dockFrames: [CGRect] = []
        var layoutWindows: [FollowingWindowSample] = []
        for window in windows {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 100, frame.height >= 80,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1 > 0 else { continue }
            // Prefer the largest normal window: a small popup on another
            // display must not decide the whole application's zoom level.
            if layer == 0 {
                if let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                    layoutWindows.append(FollowingWindowSample(id: id, processID: pid, frame: frame))
                }
                let previousArea = applications[pid].map { $0.width * $0.height } ?? 0
                if frame.width * frame.height > previousArea { applications[pid] = frame }
            }
            // On tested macOS, Dock's interaction surface is layer 20 and covers
            // its host display. Wallpaper windows share the PID but are negative layers.
            if pid == dockPID && layer == 20 { dockFrames.append(frame) }
        }
        // Ambiguous/missing Dock surfaces must not be replaced by cursor guesses.
        let dockFrame = dockFrames.count == 1 ? dockFrames.first : nil
        let workAreas = DockWorkAreaController.shared.resolve(displays: displays, dockFrame: dockFrame, dockPID: dockPID)
        return Self(displays: workAreas.displays, applications: applications, dockFrame: dockFrame,
                    layoutWindows: layoutWindows, layoutWorkAreaStable: workAreas.stable)
    }
}

/// Optional private API, resolved dynamically. Never restart Dock as a fallback
/// during screen following: that would interrupt Spaces and Stage Manager.
final class LiveDockSizeController {
    private let handle: UnsafeMutableRawPointer?
    private let getter: (@convention(c) () -> Float)?
    // Current macOS DesktopSettings calls (normalized size, save preference).
    // Older reverse-engineered one-argument declarations leave the boolean
    // register unspecified and can accidentally perform preview-only updates.
    private let setter: (@convention(c) (Float, Bool) -> Void)?
    private let preferences = UserDefaults(suiteName: "com.apple.dock")
    private(set) var revision: UInt64 = 0

    init() {
        handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
        if let handle, let get = dlsym(handle, "CoreDockGetTileSize"), let set = dlsym(handle, "CoreDockSetTileSize") {
            getter = unsafeBitCast(get, to: (@convention(c) () -> Float).self)
            setter = unsafeBitCast(set, to: (@convention(c) (Float, Bool) -> Void).self)
        } else { getter = nil; setter = nil }
    }

    deinit { if let handle { dlclose(handle) } }

    var currentPoints: Int? { getter.map { Int((16 + $0() * 112).rounded()) } }

    func apply(points: Int) -> Bool {
        guard let getter, let setter else { return false }
        let points = min(max(points, 16), 128)
        let target = ScreenScalingPolicy.normalizedDockSize(points)
        var changed = false
        if abs(getter() - target) > 0.001 { setter(target, true); changed = true }
        guard abs(getter() - target) < 0.001 else { return false }
        // CoreDock's live tile setter alone can leave the persisted tilesize
        // unchanged. Keep the stored and live settings in agreement, although
        // this alone does not guarantee AppKit's work area has refreshed;
        // DockWorkAreaController measures the actual boundary separately.
        // Write/flush only on transitions, never on an unchanged idle poll.
        if let preferences, preferences.integer(forKey: "tilesize") != points {
            preferences.set(points, forKey: "tilesize")
            preferences.synchronize()
            changed = true
        }
        if changed { revision &+= 1 }
        return true
    }
}

@MainActor
final class ScreenScalingController {
    private var timer: Timer?
    private var stability = ScreenStabilityTracker()
    private var isPolling = false
    var suspended = false
    var poll: ((ScreenScalingSnapshot, inout ScreenStabilityTracker) -> Void)?

    func setEnabled(_ enabled: Bool) {
        guard enabled else { timer?.invalidate(); timer = nil; stability.reset(); return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.suspended, !self.isPolling else { return }
                self.isPolling = true
                defer { self.isPolling = false }
                self.poll?(ScreenScalingSnapshot.capture(), &self.stability)
            }
        }
        timer.tolerance = 0.2
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func reset() { stability.reset() }
}
