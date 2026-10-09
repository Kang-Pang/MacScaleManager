import Foundation
import CoreGraphics

struct FollowingWindowSample: Equatable {
    let id: UInt32
    let processID: Int32
    let frame: CGRect
}

/// CG frames are cheap change signals, not necessarily real window geometry:
/// Stage Manager can replace them with scaled preview rectangles. AX is read
/// only after a relevant change, activation, or one bounded failure retry.
struct WindowSamplingTrigger {
    private struct Signature: Equatable {
        let windows: [FollowingWindowSample]
        let displays: [ScalingDisplay]
        let frontmost: Bool
    }
    private var signature: Signature?
    private var invalidated = false
    private var retryAt: TimeInterval?
    private var retryUsed = false

    mutating func invalidate() { invalidated = true }

    mutating func shouldRead(windows: [FollowingWindowSample], displays: [ScalingDisplay],
                             frontmost: Bool, blocked: Bool, now: TimeInterval) -> Bool {
        guard !blocked else { return false }
        let next = Signature(windows: windows.sorted { $0.id < $1.id }, displays: displays, frontmost: frontmost)
        if signature != next || invalidated {
            signature = next; invalidated = false; retryAt = nil; retryUsed = false
            return true
        }
        if let retryAt, now >= retryAt {
            self.retryAt = nil; retryUsed = true
            return true
        }
        return false
    }

    mutating func readFailed(now: TimeInterval) {
        if !retryUsed { retryAt = now + 2 }
    }
}

struct FollowingWindowRule {
    let sizeFraction: CGFloat
    /// A configured left-gap rule is a tiled layout, not a size suggestion.
    let leftGapFraction: CGFloat?
}

enum FollowingWindowKind: Equatable {
    case ordinary, filled, leftGap
}

struct FollowingWindowRequest {
    let window: FollowingWindowSample
    let display: ScalingDisplay
    let targetFrame: CGRect
    let preservePosition: Bool

    func needsPositionWrite(current: CGRect) -> Bool {
        !preservePosition && (abs(current.minX - targetFrame.minX) > 1 || abs(current.minY - targetFrame.minY) > 1)
    }
}

/// Pure Quartz-coordinate policy. Existing background windows establish a
/// baseline; explicitly scheduled startup/launch syncs run once per process.
struct AutomaticWindowLayoutPolicy {
    private struct Key: Hashable {
        let processID: Int32
        let windowID: UInt32
        init(_ window: FollowingWindowSample) { processID = window.processID; windowID = window.id }
    }
    private struct State {
        var frame: CGRect
        var display: ScalingDisplay
        var kind: FollowingWindowKind
        var lastSeen: TimeInterval
    }
    private struct Candidate: Equatable {
        let frame: CGRect
        let display: ScalingDisplay
    }
    private var states: [Key: State] = [:]
    private var candidates: [Key: (Candidate, TimeInterval)] = [:]
    private var previousStates: [Key: State] = [:]
    private var initiallySynchronizedProcesses: Set<Int32> = []
    private var initialRequests: Set<Key> = []

    mutating func reset() {
        states.removeAll(); candidates.removeAll(); previousStates.removeAll()
        initiallySynchronizedProcesses.removeAll(); initialRequests.removeAll()
    }

    /// A Dock animation or a last-moment move invalidated the request between
    /// sampling and AX. Preserve the original transition and settle again.
    mutating func complete(_ request: FollowingWindowRequest, retry: Bool) {
        let key = Key(request.window)
        if initialRequests.remove(key) != nil, retry {
            initiallySynchronizedProcesses.remove(request.window.processID)
        }
        if let previous = previousStates.removeValue(forKey: key), retry {
            states[key] = previous
            candidates.removeValue(forKey: key)
        }
    }

    mutating func update(windows: [FollowingWindowSample], displays: [ScalingDisplay],
                         rules: [Int32: FollowingWindowRule], mouseDown: Bool,
                         now: TimeInterval, initialSyncProcesses: Set<Int32> = []) -> [FollowingWindowRequest] {
        var requests: [FollowingWindowRequest] = []
        previousStates.removeAll()
        initialRequests.removeAll()
        var liveKeys = Set<Key>()
        for window in windows {
            guard let rule = rules[window.processID],
                  let display = ScreenScalingPolicy.display(for: window.frame, displays: displays) else { continue }
            let key = Key(window)
            liveKeys.insert(key)
            states[key]?.lastSeen = now
            // Keep the last settled source-screen shape throughout a drag.
            // Otherwise an intermediate frame would erase the filled state.
            guard !mouseDown else { candidates.removeValue(forKey: key); continue }
            let candidate = Candidate(frame: window.frame, display: display)
            guard let pending = candidates[key], pending.0 == candidate else {
                candidates[key] = (candidate, now)
                continue
            }
            guard now - pending.1 >= 0.5 else { continue }
            let initialSync = initialSyncProcesses.contains(window.processID)
                && !initiallySynchronizedProcesses.contains(window.processID)
            let baseline = State(frame: window.frame, display: display,
                                 kind: Self.kind(frame: window.frame, display: display, rule: rule), lastSeen: now)
            let previous = states[key] ?? baseline
            if states[key] == nil && !initialSync { states[key] = baseline; continue }
            let changedScreen = previous.display.id != display.id
            let changedArea = previous.display.usableFrame != display.usableFrame || previous.display.frame != display.frame
            let currentKind = Self.kind(frame: window.frame, display: display, rule: rule)
            var kind = currentKind
            if changedScreen {
                kind = previous.kind
            } else if changedArea && previous.kind != .ordinary {
                // The OS may already have resized a zoomed window for the new
                // Dock, or may still show the old frame. Accept either case.
                if Self.nearlyEqual(window.frame, previous.frame, tolerance: 4)
                    || Self.kind(frame: window.frame, display: previous.display, rule: rule) == previous.kind
                    || currentKind == previous.kind { kind = previous.kind }
            }
            states[key] = State(frame: window.frame, display: display, kind: kind, lastSeen: now)
            guard initialSync || changedScreen || (changedArea && kind != .ordinary) else { continue }
            if initialSync { initiallySynchronizedProcesses.insert(window.processID) }
            let target = Self.targetFrame(current: window.frame, display: display, kind: kind, rule: rule)
            // Consume the transition even if AX rejects it: no repeated writes
            // every timer tick. Another real screen/area transition may retry.
            states[key]?.frame = target
            guard !Self.nearlyEqual(window.frame, target, tolerance: 1) else { continue }
            previousStates[key] = previous
            if initialSync { initialRequests.insert(key) }
            requests.append(FollowingWindowRequest(window: window, display: display,
                                                   targetFrame: target, preservePosition: kind == .ordinary))
        }
        candidates = candidates.filter { liveKeys.contains($0.key) }
        // Stage Manager/other Spaces can hide windows for a long time. Keep
        // their baseline until the app exits or its rule is disabled. A fixed
        // LRU bound also covers closed windows without another CG/AX poll.
        states = states.filter { rules[$0.key.processID] != nil }
        initiallySynchronizedProcesses = initiallySynchronizedProcesses.filter { rules[$0] != nil }
        if states.count > 256 {
            states = Dictionary(uniqueKeysWithValues: states.sorted { $0.value.lastSeen > $1.value.lastSeen }
                .prefix(256).map { ($0.key, $0.value) })
        }
        return requests
    }

    static func kind(frame: CGRect, display: ScalingDisplay, rule: FollowingWindowRule) -> FollowingWindowKind {
        if rule.leftGapFraction != nil { return .leftGap }
        if nearlyEqual(frame, display.usableFrame, tolerance: 16) { return .filled }
        return .ordinary
    }

    static func targetFrame(current: CGRect, display: ScalingDisplay, kind: FollowingWindowKind,
                            rule: FollowingWindowRule) -> CGRect {
        switch kind {
        case .filled: return display.usableFrame
        case .leftGap: return leftGapFrame(display: display, fraction: rule.leftGapFraction ?? 0.1)
        case .ordinary:
            let fraction = min(max(rule.sizeFraction, 0.3), 1)
            return CGRect(origin: current.origin, size: CGSize(width: floor(display.usableFrame.width * fraction),
                                                               height: floor(display.usableFrame.height * fraction)))
        }
    }

    static func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func leftGapFrame(display: ScalingDisplay, fraction: CGFloat) -> CGRect {
        let visible = display.usableFrame
        let left = max(visible.minX, display.frame.minX + floor(display.frame.width * min(max(fraction, 0), 0.4)))
        return CGRect(x: left, y: visible.minY, width: max(1, visible.maxX - left), height: visible.height)
    }
}
