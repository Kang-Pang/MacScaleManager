import Foundation

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message); checks += 1
}
var cadence = ScreenPollingCadence()
cadence.wake(now: 0)
check(cadence.interval(changed: false, interacting: false, now: 0) == 0.5, "wake uses fast cadence")
check(cadence.interval(changed: false, interacting: false, now: 4.9) == 0.5, "keep settling interval during activity grace")
check(cadence.interval(changed: false, interacting: false, now: 5) == 1.5, "idle reduces wakeups")
check(cadence.interval(changed: true, interacting: false, now: 6) == 0.5, "Dock or window change immediately restores fast cadence")
check(cadence.interval(changed: false, interacting: false, now: 10.9) == 0.5, "changed sample has time to settle and execute")
check(cadence.interval(changed: false, interacting: true, now: 11) == 0.5, "held mouse keeps fast cadence")
check(cadence.interval(changed: false, interacting: false, now: 15.9) == 0.5, "release keeps settling grace")
check(cadence.interval(changed: false, interacting: false, now: 16) == 1.5, "return to idle after release")
cadence.wake(now: 30)
check(cadence.interval(changed: false, interacting: false, now: 30) == 0.5, "launch/activation/screen notification wakes an idle monitor")

var roster = ApplicationCatalogRefreshPolicy()
check(roster.shouldRefresh(now: 0), "first roster query refreshes")
check(!roster.shouldRefresh(now: 0.5), "normal fast polls reuse roster")
check(!roster.shouldRefresh(now: 9.9), "idle does not query every helper")
check(roster.shouldRefresh(now: 10), "bounded fallback catches missed lifecycle events")
roster.invalidate(launching: false, now: 11)
check(roster.shouldRefresh(now: 11), "activation/termination refreshes immediately")
roster.invalidate(launching: true, now: 12)
check(roster.shouldRefresh(now: 12), "launch invalidates cached process metadata")
check(!roster.shouldRefresh(now: 12.4), "launch grace still avoids duplicate scans")
check(roster.shouldRefresh(now: 12.5), "delayed regular activation policy is detected promptly")
check(roster.shouldRefresh(now: 14.5), "startup grace includes apps that finish initialization later")
check(!roster.shouldRefresh(now: 15), "startup grace does not leave permanent fast roster queries")
check(roster.shouldRefresh(now: 24.5), "fallback continues after startup grace")
print("Adaptive polling and application roster caching: \(checks) checks passed.")
