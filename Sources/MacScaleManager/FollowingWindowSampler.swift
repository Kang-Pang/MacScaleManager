import AppKit
import ApplicationServices

/// Read real window frames without activating applications. Keep AX identities
/// stable across Stage Manager preview changes, and cache them while idle.
@MainActor
final class FollowingWindowSampler {
    private struct Window {
        let id: UInt32
        let element: AXUIElement
        let sample: FollowingWindowSample
    }
    private struct Application {
        var trigger = WindowSamplingTrigger()
        var windows: [Window] = []
        var readable = false
    }
    private var applications: [pid_t: Application] = [:]
    private var nextID: UInt32 = 0

    func reset() { applications.removeAll() }
    func invalidate(processID: pid_t) { applications[processID]?.trigger.invalidate() }
    func deferRefresh(processID: pid_t, now: TimeInterval) {
        applications[processID]?.readable = false
        applications[processID]?.trigger.readFailed(now: now)
    }

    func sample(applications running: [pid_t: NSRunningApplication], snapshot: ScreenScalingSnapshot,
                blocked: Bool, now: TimeInterval) -> [FollowingWindowSample] {
        applications = applications.filter { running[$0.key] != nil }
        guard AXIsProcessTrusted() else { reset(); return [] }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for pid in running.keys.sorted() {
            var state = applications[pid] ?? Application()
            let signal = snapshot.layoutWindows.filter { $0.processID == pid }
            if state.trigger.shouldRead(windows: signal, displays: snapshot.displays,
                                        frontmost: frontmost == pid, blocked: blocked, now: now) {
                if let windows = read(processID: pid, previous: state.windows) {
                    state.windows = windows
                    state.readable = true
                    if CommandLine.arguments.contains("--diagnose-work-area") {
                        print("WINDOW-SAMPLE pid=\(pid) frontmost=\(frontmost == pid) cg=\(signal.map(\.frame)) ax=\(windows.map { $0.sample.frame })")
                        fflush(stdout)
                    }
                } else {
                    // Never lay out using stale frames after an unreadable AX
                    // sample. Policy keeps its old baseline for reappearance.
                    state.readable = false
                    state.trigger.readFailed(now: now)
                }
            }
            applications[pid] = state
        }
        return applications.values.filter(\.readable).flatMap { $0.windows.map(\.sample) }
    }

    private func read(processID: pid_t, previous: [Window]) -> [Window]? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { return nil }
        var result: [Window] = []
        for element in elements.prefix(32) {
            var subrole: CFTypeRef?, minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
                  subrole as? String == kAXStandardWindowSubrole as String,
                  AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  (minimized as? NSNumber)?.boolValue == false,
                  let frame = WindowLayoutController.quartzFrame(of: element),
                  frame.width >= 100, frame.height >= 80 else { continue }
            let id: UInt32
            if let previous = previous.first(where: { CFEqual($0.element, element) }) { id = previous.id }
            else { nextID &+= 1; id = nextID }
            result.append(Window(id: id, element: element,
                                 sample: FollowingWindowSample(id: id, processID: processID, frame: frame)))
        }
        return result
    }
}
