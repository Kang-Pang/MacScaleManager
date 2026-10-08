import AppKit
import CoreGraphics
import Darwin

struct ScreenScalingSnapshot {
    let displays: [ScalingDisplay]
    let applications: [pid_t: CGRect]
    let dockFrame: CGRect?

    static func capture(includeOffscreen: Bool = false) -> Self {
        let displays = NSScreen.screens.compactMap { screen -> ScalingDisplay? in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
            return ScalingDisplay(id: id, frame: CGDisplayBounds(id), builtIn: CGDisplayIsBuiltin(id) != 0)
        }
        let dockPID = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier
        let windows = CGWindowListCopyWindowInfo(includeOffscreen ? .optionAll : .optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        var applications: [pid_t: CGRect] = [:]
        var dockFrames: [CGRect] = []
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
                let previousArea = applications[pid].map { $0.width * $0.height } ?? 0
                if frame.width * frame.height > previousArea { applications[pid] = frame }
            }
            // On tested macOS, Dock's interaction surface is layer 20 and covers
            // its host display. Wallpaper windows share the PID but are negative layers.
            if pid == dockPID && layer == 20 { dockFrames.append(frame) }
        }
        // Ambiguous/missing Dock surfaces must not be replaced by cursor guesses.
        let dockFrame = dockFrames.count == 1 ? dockFrames.first : nil
        return Self(displays: displays, applications: applications, dockFrame: dockFrame)
    }
}

/// Optional private API, resolved dynamically. Never restart Dock as a fallback
/// during screen following: that would interrupt Spaces and Stage Manager.
final class LiveDockSizeController {
    private let handle: UnsafeMutableRawPointer?
    private let getter: (@convention(c) () -> Float)?
    private let setter: (@convention(c) (Float) -> Void)?

    init() {
        handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
        if let handle, let get = dlsym(handle, "CoreDockGetTileSize"), let set = dlsym(handle, "CoreDockSetTileSize") {
            getter = unsafeBitCast(get, to: (@convention(c) () -> Float).self)
            setter = unsafeBitCast(set, to: (@convention(c) (Float) -> Void).self)
        } else { getter = nil; setter = nil }
    }

    deinit { if let handle { dlclose(handle) } }

    func apply(points: Int) -> Bool {
        guard let getter, let setter else { return false }
        let target = ScreenScalingPolicy.normalizedDockSize(points)
        if abs(getter() - target) > 0.001 { setter(target) }
        return abs(getter() - target) < 0.001
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
