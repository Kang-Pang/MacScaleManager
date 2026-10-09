import AppKit
import ApplicationServices

// Uses the actual production screen detector and timer. Read-only by default;
// --live-dock enables just the Dock operation and restores its original size.
let live = CommandLine.arguments.contains("--live-dock")
let original = UserDefaults(suiteName: "com.apple.dock")?.integer(forKey: "tilesize") ?? 36
let controller = ScreenScalingController()
let dock = LiveDockSizeController()
var count = 0
var lastDescription = ""
print("accessibilityTrusted=\(AXIsProcessTrusted()) liveDock=\(live)")
controller.poll = { snapshot, stability in
    count += 1
    let frontmost = NSWorkspace.shared.frontmostApplication
    var description = "displays=\(snapshot.displays.count)"
    if let app = frontmost, let frame = snapshot.applications[app.processIdentifier],
       let screen = ScreenScalingPolicy.display(for: frame, displays: snapshot.displays) {
        description += " frontmost=\(app.bundleIdentifier ?? "unknown") display=\(screen.id) profile=\(screen.builtIn ? "laptop" : "desktop")"
    }
    if let frame = snapshot.dockFrame, let screen = ScreenScalingPolicy.display(for: frame, displays: snapshot.displays) {
        description += " dockDisplay=\(screen.id)"
        if live, stability.ready(key: "dock", candidate: StableScreenCandidate(displayID: screen.id, frame: frame),
                                 now: ProcessInfo.processInfo.systemUptime,
                                 mouseDown: CGEventSource.buttonState(.combinedSessionState, button: .left)) {
            let size = screen.builtIn ? 36 : 56
            description += " liveSize=\(size) success=\(dock.apply(points: size))"
        }
    } else { description += " dock=unconfirmed" }
    if description != lastDescription { print(description); fflush(stdout); lastDescription = description }
}
controller.setEnabled(true)
RunLoop.current.run(until: Date().addingTimeInterval(8))
let idleCount = count
// Local notification delivery only: does not switch a real Space or activate
// an application. Verify the production observer wakes an idle one-shot timer.
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
RunLoop.current.run(until: Date().addingTimeInterval(0.3))
precondition(count > idleCount, "workspace notification must wake an idle monitor promptly")
controller.setEnabled(false)
let stoppedCount = count
NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
RunLoop.current.run(until: Date().addingTimeInterval(1))
precondition(count == stoppedCount, "disabled screen following must stop polling")
if live { print("restored=\(dock.apply(points: original)) size=\(original)") }
print("pollCount=\(count) idleNotificationWake=true disabledTimerStopped=true")
