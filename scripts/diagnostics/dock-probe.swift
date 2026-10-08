import AppKit
import CoreGraphics
import Darwin

func snapshot() {
    let defaults = UserDefaults(suiteName: "com.apple.dock")!
    defaults.synchronize()
    print("configuredTileSize=\(defaults.object(forKey: "tilesize") ?? "missing")")
    for screen in NSScreen.screens {
        let display = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        print("screen=\(screen.localizedName) id=\(display) builtIn=\(CGDisplayIsBuiltin(display)) frame=\(screen.frame) visible=\(screen.visibleFrame)")
    }
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    print("enumeratedWindowCount=\(windows.count)")
    let dockPID = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.apple.dock" }?.processIdentifier
    for window in windows where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == dockPID {
        print("dockPID=\(window[kCGWindowOwnerPID as String] ?? "?") layer=\(window[kCGWindowLayer as String] ?? "?") bounds=\(window[kCGWindowBounds as String] ?? "?") title=\(window[kCGWindowName as String] ?? "unavailable")")
    }
}

func independentSnapshot() {
    guard !CommandLine.arguments[0].hasSuffix(".swift") else { return }
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    probe.arguments = []
    do {
        try probe.run()
        probe.waitUntilExit()
    } catch { print("independentSnapshotError=\(error)") }
}

let path = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
guard let handle = dlopen(path, RTLD_LAZY) else { fatalError("Cannot load HIServices") }
defer { dlclose(handle) }
guard let getSymbol = dlsym(handle, "CoreDockGetTileSize"),
      let setSymbol = dlsym(handle, "CoreDockSetTileSize") else { fatalError("Live Dock size API is unavailable") }
let getSize = unsafeBitCast(getSymbol, to: (@convention(c) () -> Float).self)
let setSize = unsafeBitCast(setSymbol, to: (@convention(c) (Float) -> Void).self)
let original = getSize()
print("normalizedSize=\(original)")
snapshot()

if CommandLine.arguments.contains("--test-live-size") || CommandLine.arguments.contains("--hold-56") {
    defer {
        setSize(original)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("RESTORED normalizedSize=\(getSize())")
        snapshot()
        independentSnapshot()
    }
    // Read-only baseline 36 -> 0.17857143 and calibration 0.5 -> 72 confirm
    // the normalized range (points - 16) / 112 on this tested macOS version.
    let values: [Float] = CommandLine.arguments.contains("--hold-56") ? [Float(56 - 16) / 112] : [Float(56 - 16) / 112, original]
    for value in values {
        setSize(value)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        print("APPLIED normalizedSize=\(getSize()) requested=\(value)")
        snapshot()
        independentSnapshot()
        if CommandLine.arguments.contains("--hold-56") {
            RunLoop.current.run(until: Date().addingTimeInterval(12))
        }
    }
}
