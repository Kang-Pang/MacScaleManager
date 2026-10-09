import Foundation
import CoreGraphics

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}
let laptop = ScalingDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1470, height: 956), builtIn: true,
                            visibleFrame: CGRect(x: 0, y: 33, width: 1470, height: 867))
let desktop = ScalingDisplay(id: 3, frame: CGRect(x: 1470, y: 0, width: 1920, height: 1080), builtIn: false,
                             visibleFrame: CGRect(x: 1470, y: 33, width: 1920, height: 991))
let displays = [laptop, desktop]
let rule = FollowingWindowRule(sizeFraction: 0.75, leftGapFraction: nil)
let gapRule = FollowingWindowRule(sizeFraction: 0.75, leftGapFraction: 0.1)
let normal = CGRect(x: 100, y: 100, width: 900, height: 700)
func sample(_ frame: CGRect, id: UInt32 = 10, pid: Int32 = 100) -> FollowingWindowSample {
    FollowingWindowSample(id: id, processID: pid, frame: frame)
}
func step(_ policy: inout AutomaticWindowLayoutPolicy, _ frames: [FollowingWindowSample], _ now: Double,
          screens: [ScalingDisplay] = displays, rules: [Int32: FollowingWindowRule] = [100: rule],
          down: Bool = false, initial: Set<Int32> = []) -> [FollowingWindowRequest] {
    policy.update(windows: frames, displays: screens, rules: rules, mouseDown: down, now: now, initialSyncProcesses: initial)
}

var policy = AutomaticWindowLayoutPolicy()
check(step(&policy, [sample(normal)], 0).isEmpty, "first poll must not resize")
check(step(&policy, [sample(normal)], 0.6).isEmpty, "new launch only establishes baseline")
let moved = CGRect(x: 1700, y: 120, width: 900, height: 700)
check(step(&policy, [sample(moved)], 1, down: true).isEmpty, "do not adjust during drag")
check(step(&policy, [sample(moved)], 2).isEmpty, "wait after releasing mouse")
check(step(&policy, [sample(moved)], 2.4).isEmpty, "wait at least half a second")
let resize = step(&policy, [sample(moved)], 2.6)
check(resize.count == 1, "ordinary screen transition resizes once")
check(resize[0].preservePosition, "ordinary resize must not send a position request")
check(resize[0].targetFrame == CGRect(x: 1700, y: 120, width: 1440, height: 743), "use destination percentage and current origin")
check(step(&policy, [sample(resize[0].targetFrame)], 3).isEmpty, "own write must not trigger another layout")
check(step(&policy, [sample(resize[0].targetFrame)], 3.6).isEmpty, "idle polling is a no-op")
let dockGrow = ScalingDisplay(id: 3, frame: desktop.frame, builtIn: false,
                              visibleFrame: CGRect(x: 1470, y: 33, width: 1920, height: 950))
check(step(&policy, [sample(resize[0].targetFrame)], 4, screens: [laptop, dockGrow]).isEmpty, "work-area change also settles")
check(step(&policy, [sample(resize[0].targetFrame)], 4.6, screens: [laptop, dockGrow]).isEmpty, "Dock must not resize ordinary windows")

var filled = AutomaticWindowLayoutPolicy()
_ = step(&filled, [sample(laptop.usableFrame)], 0)
check(step(&filled, [sample(laptop.usableFrame)], 0.6).isEmpty, "filled launch must not rearrange")
// Intermediate drag geometry is not filled on either screen. Preserve the
// settled source-screen filled state throughout all held-mouse frames.
_ = step(&filled, [sample(CGRect(x: 1200, y: 60, width: 1470, height: 867))], 1, down: true)
let filledMoved = CGRect(x: 1700, y: 80, width: 1470, height: 867)
_ = step(&filled, [sample(filledMoved)], 2, down: true)
_ = step(&filled, [sample(filledMoved)], 3)
let fillRequest = step(&filled, [sample(filledMoved)], 3.6)
check(fillRequest.count == 1, "filled state survives dragging through boundary")
check(!fillRequest[0].preservePosition && fillRequest[0].targetFrame == desktop.usableFrame, "filled window fills destination usable area")
_ = step(&filled, [sample(desktop.usableFrame)], 4)
_ = step(&filled, [sample(desktop.usableFrame)], 4.6)
_ = step(&filled, [sample(desktop.usableFrame)], 5, screens: [laptop, dockGrow])
let dockRequest = step(&filled, [sample(desktop.usableFrame)], 5.6, screens: [laptop, dockGrow])
check(dockRequest.count == 1 && dockRequest[0].targetFrame == dockGrow.usableFrame, "Dock growth shrinks filled window")
_ = step(&filled, [sample(dockGrow.usableFrame)], 6, screens: [laptop, dockGrow])
_ = step(&filled, [sample(dockGrow.usableFrame)], 6.6, screens: [laptop, dockGrow])
_ = step(&filled, [sample(dockGrow.usableFrame)], 7)
let dockLeaves = step(&filled, [sample(dockGrow.usableFrame)], 7.6)
check(dockLeaves.count == 1 && dockLeaves[0].targetFrame == desktop.usableFrame, "released Dock space is filled again")
_ = step(&filled, [sample(desktop.usableFrame)], 8)
_ = step(&filled, [sample(desktop.usableFrame)], 8.6)
let leftDock = ScalingDisplay(id: 3, frame: desktop.frame, builtIn: false,
                              visibleFrame: CGRect(x: 1550, y: 33, width: 1840, height: 1047))
_ = step(&filled, [sample(desktop.usableFrame)], 9, screens: [laptop, leftDock])
let sideDock = step(&filled, [sample(desktop.usableFrame)], 9.6, screens: [laptop, leftDock])
check(sideDock.count == 1 && sideDock[0].targetFrame.minX == 1550, "filled origin must avoid a left-side Dock")
check(sideDock[0].targetFrame == leftDock.usableFrame, "respect both Dock edge and size")

let gap = AutomaticWindowLayoutPolicy.targetFrame(current: normal, display: laptop, kind: .leftGap, rule: gapRule)
check(gap == CGRect(x: 147, y: 33, width: 1323, height: 867), "left gap measured from physical edge")
check(AutomaticWindowLayoutPolicy.kind(frame: gap, display: laptop, rule: gapRule) == .leftGap, "recognize an existing left-gap fill")
check(AutomaticWindowLayoutPolicy.kind(frame: laptop.usableFrame, display: laptop, rule: gapRule) == .leftGap, "configured left-gap layout takes precedence over plain full fill")
check(AutomaticWindowLayoutPolicy.kind(frame: normal, display: laptop, rule: gapRule) == .leftGap, "configured tiled apps use left-gap layout on next transition")
var gapPolicy = AutomaticWindowLayoutPolicy()
_ = step(&gapPolicy, [sample(gap)], 0, rules: [100: gapRule])
_ = step(&gapPolicy, [sample(gap)], 0.6, rules: [100: gapRule])
_ = step(&gapPolicy, [sample(filledMoved)], 1, rules: [100: gapRule])
let gapMoved = step(&gapPolicy, [sample(filledMoved)], 1.6, rules: [100: gapRule])
check(gapMoved.count == 1 && gapMoved[0].targetFrame.minX == 1662, "preserve configured gap on new screen")

var unfill = AutomaticWindowLayoutPolicy()
_ = step(&unfill, [sample(laptop.usableFrame)], 0)
_ = step(&unfill, [sample(laptop.usableFrame)], 0.6)
_ = step(&unfill, [sample(normal)], 1)
check(step(&unfill, [sample(normal)], 1.6).isEmpty, "manual same-screen unfill is preserved")
_ = step(&unfill, [sample(moved)], 2)
let normalAgain = step(&unfill, [sample(moved)], 2.6)
check(normalAgain.count == 1 && normalAgain[0].preservePosition, "manual unfill cancels remembered filled state")

var hidden = AutomaticWindowLayoutPolicy()
_ = step(&hidden, [sample(normal)], 0)
_ = step(&hidden, [sample(normal)], 0.6)
_ = step(&hidden, [], 1)
_ = step(&hidden, [sample(moved)], 2)
check(step(&hidden, [sample(moved)], 2.6).count == 1, "brief Stage Manager hiding preserves baseline")
hidden.reset()
_ = step(&hidden, [sample(moved)], 3)
check(step(&hidden, [sample(moved)], 3.6).isEmpty, "reenabling establishes a fresh baseline")
check(step(&hidden, [sample(normal, id: 11)], 4, rules: [:]).isEmpty, "disabled/unlisted apps are ignored")
var longHidden = AutomaticWindowLayoutPolicy()
_ = step(&longHidden, [sample(laptop.usableFrame)], 0)
_ = step(&longHidden, [sample(laptop.usableFrame)], 0.6)
_ = step(&longHidden, [], 300)
let laptopDockGrow = ScalingDisplay(id: 1, frame: laptop.frame, builtIn: true,
                                    visibleFrame: CGRect(x: 0, y: 33, width: 1470, height: 820))
_ = step(&longHidden, [sample(laptop.usableFrame)], 301, screens: [laptopDockGrow, desktop])
check(step(&longHidden, [sample(laptop.usableFrame)], 301.6, screens: [laptopDockGrow, desktop]).count == 1,
      "long-hidden filled windows still avoid changed Dock when shown")
let above = ScalingDisplay(id: 4, frame: CGRect(x: -1920, y: -1080, width: 1920, height: 1080), builtIn: false,
                           visibleFrame: CGRect(x: -1920, y: -1047, width: 1920, height: 991))
check(AutomaticWindowLayoutPolicy.targetFrame(current: CGRect(x: -1700, y: -900, width: 500, height: 500),
       display: above, kind: .ordinary, rule: rule).origin == CGPoint(x: -1700, y: -900), "negative coordinates preserve origin")
check(AutomaticWindowLayoutPolicy.targetFrame(current: normal, display: above, kind: .filled, rule: rule) == above.usableFrame,
      "above/left display uses Quartz work area")
var ambiguity = AutomaticWindowLayoutPolicy()
_ = step(&ambiguity, [sample(normal)], 0)
_ = step(&ambiguity, [sample(normal)], 0.6)
check(step(&ambiguity, [sample(CGRect(x: 1020, y: 100, width: 900, height: 700))], 1).isEmpty, "boundary tie must not change window")
_ = step(&ambiguity, [sample(moved)], 2)
check(step(&ambiguity, [sample(moved)], 2.6).count == 1, "stable destination after boundary tie still resizes")

var racingDock = AutomaticWindowLayoutPolicy()
_ = step(&racingDock, [sample(normal)], 0)
_ = step(&racingDock, [sample(normal)], 0.6)
_ = step(&racingDock, [sample(moved)], 1)
let stale = step(&racingDock, [sample(moved)], 1.6)
check(stale.count == 1, "ordinary transition prepared before Dock changed")
racingDock.complete(stale[0], retry: true)
_ = step(&racingDock, [sample(moved)], 2, screens: [laptop, dockGrow])
let retried = step(&racingDock, [sample(moved)], 2.6, screens: [laptop, dockGrow])
check(retried.count == 1 && retried[0].targetFrame.height == 712, "stale work area must not consume ordinary screen transition")
racingDock.complete(retried[0], retry: false)
_ = step(&racingDock, [sample(retried[0].targetFrame)], 3, screens: [laptop, dockGrow])
check(step(&racingDock, [sample(retried[0].targetFrame)], 3.6, screens: [laptop, dockGrow]).isEmpty, "successful retry stops writing")
print("Window screen/Dock following: \(checks) checks passed.")

let staleDesktop = ScalingDisplay(id: 3, frame: desktop.frame, builtIn: false,
    visibleFrame: CGRect(x: 1470, y: 33, width: 1920, height: 991))
let dock56 = CGRect(x: 1800, y: 1000, width: 1260, height: 80)
let actualDesktop = DockWorkAreaGeometry.usableFrame(display: staleDesktop, dockHost: 3,
    edge: .bottom, dockBounds: dock56, autoHidden: false)
check(actualDesktop == CGRect(x: 1470, y: 33, width: 1920, height: 967), "large Dock uses actual container, not stale small-Dock visibleFrame")
let noDock = DockWorkAreaGeometry.usableFrame(display: laptop, dockHost: 3,
    edge: .bottom, dockBounds: dock56, autoHidden: false)
check(noDock == CGRect(x: 0, y: 33, width: 1470, height: 923), "Dock-less display fills to physical bottom")
check(noDock.minY == 33, "keep menu/notch inset on Dock-less screen")
let dock36 = CGRect(x: 400, y: 900, width: 700, height: 56)
let actualLaptop = DockWorkAreaGeometry.usableFrame(display: laptop, dockHost: 1,
    edge: .bottom, dockBounds: dock36, autoHidden: false)
check(actualLaptop.maxY == 900, "small Dock uses its own measured boundary")
let freedDesktop = DockWorkAreaGeometry.usableFrame(display: staleDesktop, dockHost: 1,
    edge: .bottom, dockBounds: dock36, autoHidden: false)
check(freedDesktop.maxY == desktop.frame.maxY, "former host releases ALL bottom Dock space")
check(freedDesktop.minY == 33, "former host keeps its own menu inset")
let leftBounds = CGRect(x: 1470, y: 200, width: 80, height: 700)
let actualLeft = DockWorkAreaGeometry.usableFrame(display: staleDesktop, dockHost: 3,
    edge: .left, dockBounds: leftBounds, autoHidden: false)
check(actualLeft.minX == 1550 && actualLeft.maxX == desktop.frame.maxX, "left Dock shifts usable edge")
check(actualLeft.maxY == desktop.frame.maxY, "left Dock must not retain a stale bottom inset")
let rightBounds = CGRect(x: 3310, y: 200, width: 80, height: 700)
check(DockWorkAreaGeometry.usableFrame(display: staleDesktop, dockHost: 3,
    edge: .right, dockBounds: rightBounds, autoHidden: false).maxX == 3310, "right Dock reserves its actual edge")
check(DockWorkAreaGeometry.usableFrame(display: staleDesktop, dockHost: 3,
    edge: .bottom, dockBounds: nil, autoHidden: false) == staleDesktop.usableFrame, "missing measurement keeps safe system fallback on host")
check(DockWorkAreaGeometry.usableFrame(display: staleDesktop, dockHost: 3,
    edge: .bottom, dockBounds: dock56, autoHidden: true) == staleDesktop.usableFrame, "auto-hide follows system work area rather than magnification")
let gapActual = AutomaticWindowLayoutPolicy.targetFrame(current: normal,
    display: ScalingDisplay(id: 3, frame: desktop.frame, builtIn: false, visibleFrame: actualDesktop), kind: .leftGap, rule: gapRule)
check(gapActual.minX == 1662 && gapActual.maxY == 1000, "10% gap fill respects measured large Dock without extra gap")
let gapNoDock = AutomaticWindowLayoutPolicy.targetFrame(current: normal,
    display: ScalingDisplay(id: 1, frame: laptop.frame, builtIn: true, visibleFrame: noDock), kind: .leftGap, rule: gapRule)
check(gapNoDock.minX == 147 && gapNoDock.maxY == 956, "10% gap fill reaches bottom on Dock-less display")
print("Dock actual work-area geometry: \(checks - 37) checks passed.")

var configuredTile = AutomaticWindowLayoutPolicy()
_ = step(&configuredTile, [sample(normal)], 0, rules: [100: gapRule])
check(step(&configuredTile, [sample(normal)], 0.6, rules: [100: gapRule]).isEmpty, "tiled rule still does not resize a newly observed window")
_ = step(&configuredTile, [sample(moved)], 1, rules: [100: gapRule])
let tiledTransition = step(&configuredTile, [sample(moved)], 1.6, rules: [100: gapRule])
check(tiledTransition.count == 1 && tiledTransition[0].targetFrame.minX == 1662 && !tiledTransition[0].preservePosition,
      "configured tiled app follows the left-gap layout, not ordinary 75% size")
let resolvedDesktop = ScalingDisplay(id: 3, frame: desktop.frame, builtIn: false, visibleFrame: actualDesktop)
_ = step(&configuredTile, [sample(tiledTransition[0].targetFrame)], 2, rules: [100: gapRule])
_ = step(&configuredTile, [sample(tiledTransition[0].targetFrame)], 2.6, rules: [100: gapRule])
_ = step(&configuredTile, [sample(tiledTransition[0].targetFrame)], 3, screens: [laptop, resolvedDesktop], rules: [100: gapRule])
let tiledDock = step(&configuredTile, [sample(tiledTransition[0].targetFrame)], 3.6, screens: [laptop, resolvedDesktop], rules: [100: gapRule])
check(tiledDock.count == 1 && tiledDock[0].targetFrame == gapActual, "actual large Dock boundary recomputes tiled height")
print("Configured tiled-layout transitions: 3 checks passed.")
check(!tiledDock[0].needsPositionWrite(current: tiledDock[0].window.frame), "Dock-only height update must not rewrite unchanged tiled origin")
check(tiledTransition[0].needsPositionWrite(current: tiledTransition[0].window.frame), "cross-screen tiled layout may position at its configured edge")
check(!resize[0].needsPositionWrite(current: CGRect(x: 1000, y: 200, width: 900, height: 700)), "ordinary windows never send position writes")
print("Window position write policy: 3 checks passed.")

var settlingDock = DockBoundsSettler()
check(!settlingDock.observe(dock56, now: 0), "first actual Dock frame is not stable yet")
check(!settlingDock.observe(dock36, now: 0.5), "size getter can lead actual Dock bounds; changed sample restarts settling")
check(!settlingDock.observe(dock36, now: 0.9), "do not accept two samples less than half a second apart")
check(settlingDock.observe(dock36, now: 1), "matching actual Dock frames settle after half a second")
check(!settlingDock.observe(nil, now: 2), "a disappeared Dock container is not immediately stable")
check(settlingDock.observe(nil, now: 2.5), "persistently missing AX bounds can use the safe fallback")
print("Dock container settling: 6 checks passed.")

let samplingStart = checks
var trigger = WindowSamplingTrigger()
check(!trigger.shouldRead(windows: [sample(normal)], displays: displays, frontmost: false, blocked: true, now: 0),
      "do not read AX during drag or Dock animation")
check(trigger.shouldRead(windows: [sample(normal)], displays: displays, frontmost: false, blocked: false, now: 1),
      "initial background AX sample is allowed")
check(!trigger.shouldRead(windows: [sample(normal)], displays: displays, frontmost: false, blocked: false, now: 2),
      "idle polls do not read AX")
let preview = CGRect(x: 10, y: 200, width: 171, height: 142)
check(trigger.shouldRead(windows: [sample(preview)], displays: displays, frontmost: false, blocked: false, now: 3),
      "Stage Manager preview triggers real-frame sampling")
check(!trigger.shouldRead(windows: [sample(preview)], displays: displays, frontmost: false, blocked: false, now: 4),
      "unchanged preview does not repeatedly read AX")
check(trigger.shouldRead(windows: [sample(preview)], displays: [laptop, dockGrow], frontmost: false, blocked: false, now: 5),
      "Dock area change samples background apps even if preview is unchanged")
check(trigger.shouldRead(windows: [sample(preview)], displays: [laptop, dockGrow], frontmost: true, blocked: false, now: 6),
      "activation refreshes a previously hidden window")
trigger.invalidate()
check(!trigger.shouldRead(windows: [sample(preview)], displays: [laptop, dockGrow], frontmost: true, blocked: true, now: 7),
      "invalidated sample still waits for release")
check(trigger.shouldRead(windows: [sample(preview)], displays: [laptop, dockGrow], frontmost: true, blocked: false, now: 8),
      "own layout write is refreshed once")
trigger.readFailed(now: 8)
check(!trigger.shouldRead(windows: [sample(preview)], displays: [laptop, dockGrow], frontmost: true, blocked: false, now: 9),
      "unresponsive background app is not polled every tick")
check(trigger.shouldRead(windows: [sample(preview)], displays: [laptop, dockGrow], frontmost: true, blocked: false, now: 10),
      "temporary AX failure gets one delayed retry")
trigger.readFailed(now: 10)
check(!trigger.shouldRead(windows: [sample(preview)], displays: [laptop, dockGrow], frontmost: true, blocked: false, now: 100),
      "persistent AX failure does not cause an endless retry loop")
var backgroundTile = AutomaticWindowLayoutPolicy()
_ = step(&backgroundTile, [sample(gap)], 0, rules: [100: gapRule])
_ = step(&backgroundTile, [sample(gap)], 0.6, rules: [100: gapRule])
// Feed real AX bounds, not the 171x142 CG preview, while the app stays hidden.
_ = step(&backgroundTile, [sample(gap)], 1, screens: [laptopDockGrow, desktop], rules: [100: gapRule])
let backgroundDock = step(&backgroundTile, [sample(gap)], 1.6, screens: [laptopDockGrow, desktop], rules: [100: gapRule])
check(backgroundDock.count == 1 && backgroundDock[0].targetFrame.height == 820,
      "background tiled window adapts before activation")
backgroundTile.complete(backgroundDock[0], retry: true)
_ = step(&backgroundTile, [], 2, screens: [laptopDockGrow, desktop], rules: [100: gapRule])
_ = step(&backgroundTile, [sample(gap)], 3, screens: [laptopDockGrow, desktop], rules: [100: gapRule])
check(step(&backgroundTile, [sample(gap)], 3.6, screens: [laptopDockGrow, desktop], rules: [100: gapRule]).count == 1,
      "unreadable background window must not consume the Dock transition")
print("Background window sampling: \(checks - samplingStart) checks passed.")

let initialStart = checks
var startup = AutomaticWindowLayoutPolicy()
check(step(&startup, [sample(normal)], 0, initial: [100]).isEmpty, "startup sync waits for stable window")
let startupRequest = step(&startup, [sample(normal)], 0.6, initial: [100])
check(startupRequest.count == 1, "startup foreground app syncs without a screen transition")
check(startupRequest[0].preservePosition && startupRequest[0].targetFrame.origin == normal.origin,
      "startup ordinary window keeps its position")
check(startupRequest[0].targetFrame.size == CGSize(width: 1102, height: 650), "startup uses current-screen percentage")
startup.complete(startupRequest[0], retry: false)
_ = step(&startup, [sample(startupRequest[0].targetFrame)], 1, initial: [100])
check(step(&startup, [sample(startupRequest[0].targetFrame)], 1.6, initial: [100]).isEmpty, "startup layout only runs once")
_ = step(&startup, [sample(normal)], 2, initial: [100])
check(step(&startup, [sample(normal)], 2.6, initial: [100]).isEmpty, "same-screen manual resize is not continually overwritten")
var delayedLaunch = AutomaticWindowLayoutPolicy()
_ = step(&delayedLaunch, [sample(normal)], 0)
_ = step(&delayedLaunch, [sample(normal)], 0.6)
check(step(&delayedLaunch, [sample(normal)], 2, initial: [100]).count == 1,
      "launch delay expiry still synchronizes an already baselined window")
var initialGap = AutomaticWindowLayoutPolicy()
_ = step(&initialGap, [sample(normal)], 0, rules: [100: gapRule], initial: [100])
let launchGap = step(&initialGap, [sample(normal)], 0.6, rules: [100: gapRule], initial: [100])
check(launchGap.count == 1 && launchGap[0].targetFrame == gap && !launchGap[0].preservePosition,
      "new tiled app adopts its configured left-gap fill immediately")
initialGap.complete(launchGap[0], retry: true)
check(step(&initialGap, [sample(normal)], 1, rules: [100: gapRule], initial: [100]).isEmpty,
      "deferred initial request settles again")
let launchRetry = step(&initialGap, [sample(normal)], 1.6, rules: [100: gapRule], initial: [100])
check(launchRetry.count == 1, "temporary AX failure does not consume initial sync")
initialGap.complete(launchRetry[0], retry: false)
_ = step(&initialGap, [sample(launchRetry[0].targetFrame)], 2, rules: [100: gapRule], initial: [100])
check(step(&initialGap, [sample(launchRetry[0].targetFrame)], 2.6, rules: [100: gapRule], initial: [100]).isEmpty,
      "successful launch retry stops writing")
var matchedInitial = AutomaticWindowLayoutPolicy()
_ = step(&matchedInitial, [sample(gap)], 0, rules: [100: gapRule], initial: [100])
check(step(&matchedInitial, [sample(gap)], 0.6, rules: [100: gapRule], initial: [100]).isEmpty,
      "matching startup layout needs no AX write")
_ = step(&matchedInitial, [sample(normal)], 1, rules: [100: gapRule], initial: [100])
check(step(&matchedInitial, [sample(normal)], 1.6, rules: [100: gapRule], initial: [100]).isEmpty,
      "matching initial layout is consumed once, not enforced on every frame")
startup.reset()
_ = step(&startup, [sample(normal)], 3, initial: [100])
check(step(&startup, [sample(normal)], 3.6, initial: [100]).count == 1, "reenabling can sync current app again")
var initialDrag = AutomaticWindowLayoutPolicy()
check(step(&initialDrag, [sample(normal)], 0, down: true, initial: [100]).isEmpty, "initial sync never runs during drag")
_ = step(&initialDrag, [sample(normal)], 1, initial: [100])
check(step(&initialDrag, [sample(normal)], 1.6, initial: [100]).count == 1, "initial sync runs after release and settling")
print("Startup/launch window synchronization: \(checks - initialStart) checks passed.")
