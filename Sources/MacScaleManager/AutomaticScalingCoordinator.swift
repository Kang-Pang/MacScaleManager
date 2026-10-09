import AppKit
import Combine

@MainActor
final class AutomaticScalingCoordinator {
    private let preferences: ManagedPreferences
    private let monitor = ScreenScalingController()
    private let dock = LiveDockSizeController()
    private var windowFollowing = AutomaticWindowLayoutPolicy()
    private let windowSampler = FollowingWindowSampler()
    private var lastWindowStatus = "窗口跟随：等待换屏或 Dock 可用区域变化"
    private var dockLayoutNotBefore: TimeInterval = 0
    private let diagnoseWorkArea = CommandLine.arguments.contains("--diagnose-work-area")
    private var lastWorkAreaDiagnostic = ""
    private var subscription: AnyCancellable?
    private var configured: [String: String] = [:]
    private var configurationChecks: [String: String] = [:]
    private var knownConfigurationProfiles: [String: String] = [:]
    private var suppressedRestarts: [String: String] = [:]
    private var restartJobIdentifier: UUID?
    private var pendingRestartBundleID: String?
    private var restartConfirmation: RestartConfirmationController?
    private var shortcuts: [String: String]
    private var failedAttempts: [String: Date] = [:]
    private var uncertainRelativeApps: Set<String> = []
    private var applicationStatuses: [String: String] = [:]
    private var lastDockStatus = "等待识别 Dock 所在屏幕"
    private let startedAt = Date()
    private var applicationsEnabled = false
    private var observedProcesses: [pid_t: String] = [:]
    private var initialSynchronizationProcesses: Set<pid_t> = []
    private var initialFontSyncTokens: Set<String> = []
    private var configurationTargets: [ScreenConfigurationTarget] = []
    private var shortcutTargets: [String: CustomImmediateApp] = [:]
    private var layoutRules: [String: FollowingWindowRule] = [:]
    private var laptopConfigurationSignature = ""
    private var desktopConfigurationSignature = ""
    var statusChanged: ((String) -> Void)?
    var stopped = false

    init(preferences: ManagedPreferences) {
        self.preferences = preferences
        shortcuts = UserDefaults.standard.dictionary(forKey: "screenShortcutStatesV1") as? [String: String] ?? [:]
        monitor.poll = { [weak self] snapshot, stability in self?.poll(snapshot, stability: &stability) }
        subscription = preferences.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.configure() }
        }
        configure()
    }

    func configure() {
        guard !stopped else { return }
        let options = preferences.automaticScreenScaling
        configurationTargets = preferences.screenConfigurationTargets
        shortcutTargets.removeAll(keepingCapacity: true)
        if preferences.immediateMode {
            for adapter in preferences.configuredImmediateAdapters where adapter.isEnabled && shortcutTargets[adapter.bundleIdentifier] == nil {
                shortcutTargets[adapter.bundleIdentifier] = adapter.asImmediateApp()
            }
        }
        layoutRules.removeAll(keepingCapacity: true)
        for adapter in preferences.configuredWindowLayoutAdapters where adapter.isEnabled && layoutRules[adapter.bundleIdentifier] == nil {
            layoutRules[adapter.bundleIdentifier] = FollowingWindowRule(sizeFraction: adapter.sizeFraction,
                leftGapFraction: adapter.style == .fillWithLeftGap ? adapter.leftGapFraction : nil)
        }
        laptopConfigurationSignature = "laptop:\(fingerprint(preferences.laptopProfile))"
        desktopConfigurationSignature = "desktop:\(fingerprint(preferences.desktopProfile))"
        if options.applications && !applicationsEnabled {
            observedProcesses = Dictionary(uniqueKeysWithValues: RunningApplicationCatalog.shared.snapshot().applications
                .map { ($0.processIdentifier, token($0)) })
            if let app = NSWorkspace.shared.frontmostApplication,
               app.activationPolicy == .regular, app.bundleIdentifier != Bundle.main.bundleIdentifier {
                scheduleInitialSynchronization(app)
            }
        }
        applicationsEnabled = options.applications
        if !options.applications || !options.allowsConfigurationRestart { restartConfirmation?.dismiss() }
        monitor.setEnabled(options.applications || (options.dock && preferences.isManagedApplicationEnabled("dock")))
        if !options.applications {
            applicationStatuses.removeAll(); windowFollowing.reset(); windowSampler.reset()
            initialSynchronizationProcesses.removeAll(); initialFontSyncTokens.removeAll()
        }
        publishStatus()
    }

    func suspend() { monitor.suspended = true }
    func resume() { monitor.reset(); monitor.suspended = false; configured.removeAll(); configurationChecks.removeAll(); knownConfigurationProfiles.removeAll() }
    func stop() { stopped = true; monitor.setEnabled(false); restartConfirmation?.dismiss() }

    private func scheduleInitialSynchronization(_ app: NSRunningApplication) {
        initialSynchronizationProcesses.insert(app.processIdentifier)
        initialFontSyncTokens.insert(token(app))
    }

    func recordManual(mode: ScaleMode, bundleIdentifiers: [String]) {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, bundleIdentifiers.contains(id),
                  let target = preferences.automaticShortcutTarget(bundleIdentifier: id) else { continue }
            shortcuts[token(app)] = shortcutState(mode: mode, target: target)
            uncertainRelativeApps.remove(token(app))
        }
        saveShortcutStates()
    }

    /// Explicit foreground sync may activate an app, unlike background following.
    func syncExplicitly(_ app: NSRunningApplication, modeOverride: ScaleMode? = nil) -> String {
        let snapshot = ScreenScalingSnapshot.capture()
        guard let id = app.bundleIdentifier else { return "无法识别当前前台应用。" }
        guard let frame = snapshot.applications[app.processIdentifier],
              let display = ScreenScalingPolicy.display(for: frame, displays: snapshot.displays) else {
            return "无法确定当前应用所在屏幕，请让窗口保持可见后重试。"
        }
        let mode: ScaleMode = modeOverride ?? (display.builtIn ? .laptop : .desktop)
        if let target = preferences.automaticShortcutTarget(bundleIdentifier: id) {
            return synchronize(app, target: target, mode: mode, explicit: true)
        }
        guard let configuration = preferences.screenConfigurationTargets.first(where: { $0.bundleIdentifier == id }) else {
            if !preferences.immediateMode && preferences.configuredImmediateAdapters.contains(where: { $0.bundleIdentifier == id && $0.isEnabled }) {
                return "即时快捷键缩放未启用，请在 Settings 中开启。"
            }
            return "当前前台应用没有启用的缩放规则。"
        }
        if configuration.requiresQuit {
            suppressedRestarts.removeValue(forKey: id)
            restart(configuration: configuration, application: app, mode: mode, frame: frame)
            return applicationStatuses[id] ?? "等待配置同步"
        }
        do { try preferences.applyScreenConfiguration(configuration, mode: mode); return "\(configuration.name)：已写入 \(mode.title) 配置" }
        catch { return error.localizedDescription }
    }

    private func poll(_ snapshot: ScreenScalingSnapshot, stability: inout ScreenStabilityTracker) {
        let running = RunningApplicationCatalog.shared.snapshot().applications
        let liveTokens = Set(running.map(token))
        configured = configured.filter { liveTokens.contains($0.key) }
        configurationChecks = configurationChecks.filter { liveTokens.contains($0.key) }
        shortcuts = shortcuts.filter { liveTokens.contains($0.key) }
        uncertainRelativeApps.formIntersection(liveTokens)
        failedAttempts = failedAttempts.filter { liveTokens.contains($0.key) }
        let bundleIDs = Set(running.compactMap(\.bundleIdentifier))
        applicationStatuses = applicationStatuses.filter { bundleIDs.contains($0.key) || $0.key == pendingRestartBundleID }
        knownConfigurationProfiles = knownConfigurationProfiles.filter { bundleIDs.contains($0.key) || $0.key == pendingRestartBundleID }
        let mouseDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
        let modifierDown = !CGEventSource.flagsState(.combinedSessionState)
            .intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        let now = ProcessInfo.processInfo.systemUptime
        var candidateKeys = Set<String>()
        let options = preferences.automaticScreenScaling

        let regular = running
        if options.applications {
            for app in regular where observedProcesses[app.processIdentifier] != token(app) {
                scheduleInitialSynchronization(app)
            }
        }
        observedProcesses = Dictionary(uniqueKeysWithValues: regular.map { ($0.processIdentifier, token($0)) })
        initialSynchronizationProcesses.formIntersection(Set(observedProcesses.keys))
        initialFontSyncTokens.formIntersection(liveTokens)

        if options.dock && preferences.isManagedApplicationEnabled("dock") {
            if let frame = snapshot.dockFrame,
               let display = ScreenScalingPolicy.display(for: frame, displays: snapshot.displays) {
                let key = "dock"
                candidateKeys.insert(key)
                if stability.ready(key: key, candidate: StableScreenCandidate(displayID: display.id, frame: frame), now: now, mouseDown: mouseDown) {
                    let size = display.builtIn ? preferences.laptopProfile.dockSize : preferences.desktopProfile.dockSize
                    let revision = dock.revision
                    lastDockStatus = dock.apply(points: size)
                        ? "Dock：\(display.builtIn ? "内屏" : "外屏") \(size)"
                        : "Dock：当前系统不支持实时大小接口，未重启 Dock"
                    if dock.revision != revision {
                        // Never lay out against a pre-setter snapshot. Let the
                        // preference/work-area update and Dock animation settle.
                        dockLayoutNotBefore = now + 1
                    }
                }
            } else { lastDockStatus = "Dock：位置暂不可确认，保持原大小" }
        }

        if options.applications {
            // Window rules are independent from shortcut/configuration rules.
            // Reuse this snapshot and timer; AX is touched only on a real
            // settled display/work-area transition, never on every idle poll.
            var windowRules: [Int32: FollowingWindowRule] = [:]
            var windowApps: [Int32: NSRunningApplication] = [:]
            for app in running {
                guard let id = app.bundleIdentifier, id != pendingRestartBundleID,
                      let rule = layoutRules[id] else { continue }
                windowRules[app.processIdentifier] = rule
                windowApps[app.processIdentifier] = app
            }
            let layoutBlocked = mouseDown || modifierDown || now < dockLayoutNotBefore || !snapshot.layoutWorkAreaStable
            let realWindows = windowSampler.sample(applications: windowApps, snapshot: snapshot, blocked: layoutBlocked, now: now)
            let readyInitialProcesses = initialSynchronizationProcesses.filter { pid in
                guard let app = windowApps[pid] else { return false }
                let delay = app.bundleIdentifier.flatMap { shortcutTargets[$0] }?.desktopLaunchDelay ?? 2
                return app.launchDate.map { Date().timeIntervalSince($0) >= delay } ?? true
            }
            let requests = windowFollowing.update(windows: realWindows, displays: snapshot.displays,
                rules: windowRules, mouseDown: layoutBlocked, now: now, initialSyncProcesses: readyInitialProcesses)
            for request in requests {
                guard let app = windowApps[request.window.processID] else { continue }
                let name = app.localizedName ?? app.bundleIdentifier ?? "应用"
                let result = WindowLayoutController.applyFollowing(to: app, request: request)
                if diagnoseWorkArea {
                    print("WINDOW \(name) from=\(request.window.frame) target=\(request.targetFrame) result=\(String(describing: result))")
                    fflush(stdout)
                }
                var retry = false
                switch result {
                case .changed:
                    windowSampler.invalidate(processID: app.processIdentifier)
                    lastWindowStatus = "窗口跟随：\(name) 已\(request.preservePosition ? "调整大小，保留位置" : "适应屏幕可用区域")"
                case .skipped(let reason): lastWindowStatus = "窗口跟随：\(name) 跳过（\(reason)）"
                case .failed(let reason): lastWindowStatus = "窗口跟随：\(name) 失败（\(reason)）"
                case .deferred(let reason):
                    retry = true
                    windowSampler.deferRefresh(processID: app.processIdentifier, now: now)
                    lastWindowStatus = "窗口跟随：\(name)（\(reason)）"
                }
                windowFollowing.complete(request, retry: retry)
            }
            let targets = configurationTargets
            for app in running {
                guard let id = app.bundleIdentifier, let frame = snapshot.applications[app.processIdentifier],
                      let display = ScreenScalingPolicy.display(for: frame, displays: snapshot.displays) else { continue }
                let key = token(app)
                if id == pendingRestartBundleID { continue }
                let target = shortcutTargets[id]
                let configuration = targets.first { $0.bundleIdentifier == id }
                guard target != nil || configuration != nil else { continue }
                candidateKeys.insert(key)
                guard stability.ready(key: key, candidate: StableScreenCandidate(displayID: display.id, frame: frame),
                                      now: now, mouseDown: mouseDown || modifierDown) else { continue }
                let mode: ScaleMode = display.builtIn ? .laptop : .desktop
                if let target {
                    // Background apps keep their state until activated: never
                    // send global shortcuts into a different application.
                    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                        applicationStatuses[id] = shortcuts[key] == shortcutState(mode: mode, target: target)
                            ? "\(target.name)：已同步 \(mode.title)"
                            : "\(target.name)：等待前台同步 \(mode.title)"
                        continue
                    }
                    let age = app.launchDate.map { Date().timeIntervalSince($0) } ?? 100
                    guard age >= target.desktopLaunchDelay else { continue }
                    if initialFontSyncTokens.remove(key) != nil,
                       target.resetBeforeDesktop == true, target.laptopAction == .reset {
                        // Startup/enable sync repairs resettable foreground zoom
                        // even if a saved signature says it was already applied.
                        // Unknown relative zoom is never guessed or compounded.
                        shortcuts.removeValue(forKey: key)
                    }
                    applicationStatuses[id] = synchronize(app, target: target, mode: mode, explicit: false)
                } else if let configuration {
                    let signature = mode == .desktop ? desktopConfigurationSignature : laptopConfigurationSignature
                    if suppressedRestarts[id] != signature { suppressedRestarts.removeValue(forKey: id) }
                    if knownConfigurationProfiles[id] == signature { configured[key] = signature }
                    guard configured[key] != signature else { continue }
                    if configuration.requiresQuit && configurationChecks[key] != signature {
                        configurationChecks[key] = signature
                        if preferences.screenConfigurationMatches(configuration, mode: mode) {
                            configured[key] = signature
                            knownConfigurationProfiles[id] = signature
                            applicationStatuses[id] = "\(configuration.name)：已有配置符合 \(mode.title)，无需重启"
                            continue
                        }
                    }
                    if configuration.requiresQuit {
                        if !options.allowsConfigurationRestart {
                            applicationStatuses[id] = "\(configuration.name)：等待允许换屏重启后写入 \(mode.title)"
                        } else if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                            restart(configuration: configuration, application: app, mode: mode, frame: frame)
                        } else {
                            applicationStatuses[id] = "\(configuration.name)：等待前台后重启为 \(mode.title)"
                        }
                    } else if mayRetry(key) {
                        do {
                            try preferences.applyScreenConfiguration(configuration, mode: mode)
                            configured[key] = signature
                            failedAttempts.removeValue(forKey: key)
                            applicationStatuses[id] = "\(configuration.name)：已写入 \(mode.title) 配置"
                        } catch {
                            failedAttempts[key] = Date()
                            applicationStatuses[id] = "\(configuration.name)：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
        stability.retain(keys: candidateKeys)
        if diagnoseWorkArea {
            let frames = snapshot.displays.map { "\($0.id):\($0.usableFrame)" }.joined(separator: " ")
            let message = "AX=\(AXIsProcessTrusted()) liveDock=\(dock.currentPoints ?? -1) stable=\(snapshot.layoutWorkAreaStable) \(DockWorkAreaController.shared.diagnosticDescription) workAreas=\(frames)"
            if message != lastWorkAreaDiagnostic {
                print(message)
                fflush(stdout)
                lastWorkAreaDiagnostic = message
            }
        }
        publishStatus()
    }

    private func restart(configuration: ScreenConfigurationTarget, application: NSRunningApplication,
                         mode: ScaleMode, frame: CGRect) {
        let id = configuration.bundleIdentifier
        let profile = mode == .desktop ? preferences.desktopProfile : preferences.laptopProfile
        let signature = "\(mode.rawValue):\(fingerprint(profile))"
        guard preferences.automaticScreenScaling.allowsConfigurationRestart else {
            applicationStatuses[id] = "\(configuration.name)：换屏自动重启未启用"
            return
        }
        guard restartJobIdentifier == nil else { return }
        guard suppressedRestarts[id] != signature else {
            applicationStatuses[id] = "\(configuration.name)：上次退出未完成；换屏后重试或手动同步"
            return
        }
        let snapshot = ScreenScalingSnapshot.capture()
        guard let display = ScreenScalingPolicy.display(for: frame, displays: snapshot.displays),
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
              }) else {
            applicationStatuses[id] = "\(configuration.name)：无法确认目标屏幕，未请求退出"
            return
        }
        let job = UUID()
        restartJobIdentifier = job
        pendingRestartBundleID = id
        applicationStatuses[id] = "\(configuration.name)：等待在\(screen.localizedName)上确认重启"
        let confirmation = RestartConfirmationController(applicationName: configuration.name, mode: mode, screenName: screen.localizedName) { [weak self] confirmed in
            guard let self else { return }
            self.restartConfirmation = nil
            guard self.restartJobIdentifier == job else { return }
            guard confirmed, !self.stopped else {
                self.suppressedRestarts[id] = signature
                self.applicationStatuses[id] = "\(configuration.name)：已取消重启，未修改配置"
                self.restartJobIdentifier = nil; self.pendingRestartBundleID = nil
                self.publishStatus()
                if !self.stopped && !application.isTerminated { application.activate(options: []) }
                return
            }
            // Revalidate after waiting for the user: a display may have been
            // unplugged or the window moved while this alert was visible.
            // Stage Manager may temporarily hide the target when our alert
            // becomes active. Include its offscreen window for validation only.
            let current = ScreenScalingSnapshot.capture(includeOffscreen: true)
            guard self.preferences.automaticScreenScaling.applications,
                  self.preferences.automaticScreenScaling.allowsConfigurationRestart,
                  self.preferences.screenConfigurationTargets.contains(where: { $0.bundleIdentifier == id && $0.requiresQuit }),
                  !application.isTerminated,
                  let currentFrame = current.applications[application.processIdentifier],
                  ScreenScalingPolicy.display(for: currentFrame, displays: current.displays)?.id == display.id else {
                self.applicationStatuses[id] = "\(configuration.name)：屏幕、窗口或规则已变化，未请求退出"
                self.restartJobIdentifier = nil; self.pendingRestartBundleID = nil
                self.monitor.reset(); self.publishStatus()
                return
            }
            self.beginConfirmedRestart(configuration: configuration, application: application, mode: mode,
                                       frame: currentFrame, signature: signature, job: job)
        }
        restartConfirmation = confirmation
        publishStatus()
        confirmation.show(on: screen)
    }

    private func beginConfirmedRestart(configuration: ScreenConfigurationTarget, application: NSRunningApplication,
                                       mode: ScaleMode, frame: CGRect, signature: String, job: UUID) {
        let id = configuration.bundleIdentifier
        guard let url = application.bundleURL, application.terminate() else {
            suppressedRestarts[id] = signature
            applicationStatuses[id] = "\(configuration.name)：未能请求正常退出，未修改配置"
            restartJobIdentifier = nil; pendingRestartBundleID = nil; publishStatus()
            return
        }
        applicationStatuses[id] = "\(configuration.name)：正在正常退出，随后写入 \(mode.title) 并重开"
        publishStatus()
        waitForExit(application: application, configuration: configuration, mode: mode,
                    frame: frame, url: url, signature: signature, job: job, deadline: Date().addingTimeInterval(45))
    }

    private func waitForExit(application: NSRunningApplication, configuration: ScreenConfigurationTarget,
                             mode: ScaleMode, frame: CGRect, url: URL, signature: String, job: UUID, deadline: Date) {
        guard !stopped, restartJobIdentifier == job else { return }
        let id = configuration.bundleIdentifier
        guard application.isTerminated else {
            guard Date() < deadline else {
                suppressedRestarts[id] = signature
                applicationStatuses[id] = "\(configuration.name)：退出被取消或超时，未改配置、未强制关闭"
                restartJobIdentifier = nil; pendingRestartBundleID = nil; publishStatus()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.waitForExit(application: application, configuration: configuration, mode: mode,
                    frame: frame, url: url, signature: signature, job: job, deadline: deadline)
            }
            return
        }
        var wroteConfiguration = false
        var writtenSignature: String?
        if preferences.automaticScreenScaling.applications && preferences.automaticScreenScaling.allowsConfigurationRestart,
           let currentTarget = preferences.screenConfigurationTargets.first(where: { $0.bundleIdentifier == id }) {
            do {
                try preferences.applyScreenConfiguration(currentTarget, mode: mode)
                wroteConfiguration = true
                let profile = mode == .desktop ? preferences.desktopProfile : preferences.laptopProfile
                writtenSignature = "\(mode.rawValue):\(fingerprint(profile))"
            } catch {
                suppressedRestarts[id] = signature
                applicationStatuses[id] = "\(configuration.name)：配置写入失败（\(error.localizedDescription)），尝试重开"
            }
        }
        let didWrite = wroteConfiguration
        let appliedSignature = writtenSignature
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: openConfiguration) { [weak self] reopened, error in
            Task { @MainActor in
                guard let self, !self.stopped, self.restartJobIdentifier == job else { return }
                guard let reopened, error == nil else {
                    self.applicationStatuses[id] = "\(configuration.name)：重开失败，请手动打开（\(error?.localizedDescription ?? "未知错误")）"
                    self.suppressedRestarts[id] = signature
                    self.restartJobIdentifier = nil; self.pendingRestartBundleID = nil; self.publishStatus()
                    return
                }
                if didWrite, let actualSignature = appliedSignature {
                    self.knownConfigurationProfiles[id] = actualSignature
                    self.configured[self.token(reopened)] = actualSignature
                    self.applicationStatuses[id] = "\(configuration.name)：已重启并写入 \(mode.title) 配置"
                }
                self.restoreReopenedPosition(application: reopened, origin: frame.origin, job: job, attempt: 0)
            }
        }
    }

    private func restoreReopenedPosition(application: NSRunningApplication, origin: CGPoint, job: UUID, attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped, self.restartJobIdentifier == job else { return }
            let restored = WindowLayoutController.restorePosition(of: application, origin: origin)
            if !restored && attempt < 7 && !application.isTerminated {
                self.restoreReopenedPosition(application: application, origin: origin, job: job, attempt: attempt + 1)
                return
            }
            self.restartJobIdentifier = nil; self.pendingRestartBundleID = nil
            self.monitor.reset(); self.publishStatus()
        }
    }

    private func synchronize(_ app: NSRunningApplication, target: CustomImmediateApp, mode: ScaleMode, explicit: Bool) -> String {
        let key = token(app)
        let signature = shortcutState(mode: mode, target: target)
        let previous = shortcuts[key]
        let resettable = target.resetBeforeDesktop == true && target.laptopAction == .reset
        if previous == signature && !(explicit && resettable) { return "\(target.name)：已同步 \(mode.title)" }
        if !resettable {
            // Relative shortcuts cannot recover from an unknown/partially
            // applied sequence. Do not guess and compound the zoom.
            if uncertainRelativeApps.contains(key) {
                return "\(target.name)：上次快捷键被中断，请重启目标应用后再同步"
            }
            if previous?.hasPrefix(mode.rawValue + ":") == true {
                return "\(target.name)：本模式已同步，跳过重复相对缩放"
            }
            if previous == nil && mode == .laptop && target.laptopAction == .zoomOut {
                shortcuts[key] = signature
                saveShortcutStates()
                return "\(target.name)：内屏保持初始大小（没有本轮放大记录）"
            }
            if previous == nil && mode == .desktop && !explicit && (app.launchDate ?? .distantPast) < startedAt {
                return "\(target.name)：相对缩放基准未知；先恢复默认并手动同步，或重启此应用"
            }
        }
        guard explicit || mayRetry(key) else { return "\(target.name)：等待重试" }
        var effectiveTarget = target
        if mode == .laptop && target.laptopAction == .zoomOut, let previous,
           previous.hasPrefix("desktop:"), let text = previous.split(separator: ":").dropFirst().first, let steps = Int(text) {
            // Undo the actual applied count, not a count edited afterwards.
            effectiveTarget.desktopZoomSteps = steps
        }
        let result = ImmediateZoomController.applyWithResult(mode: mode, targets: [], customTargets: [effectiveTarget], foregroundOnly: !explicit)
        if result.changedBundleIdentifiers.contains(target.bundleIdentifier) {
            shortcuts[key] = signature
            failedAttempts.removeValue(forKey: key)
            saveShortcutStates()
            return "\(target.name)：已同步 \(mode.title)"
        }
        if !resettable && AXIsProcessTrusted() { uncertainRelativeApps.insert(key) }
        failedAttempts[key] = Date()
        return "\(target.name)：\(result.summary)"
    }

    private func token(_ app: NSRunningApplication) -> String {
        "\(app.bundleIdentifier ?? "")|\(app.processIdentifier)|\(app.launchDate?.timeIntervalSince1970 ?? 0)"
    }

    private func fingerprint<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value).base64EncodedString()) ?? ""
    }

    private func shortcutState(mode: ScaleMode, target: CustomImmediateApp) -> String {
        // UUIDs are ephemeral; only effective shortcut parameters define state.
        "\(mode.rawValue):\(target.desktopZoomSteps):\(target.laptopAction.rawValue):\(target.resetBeforeDesktop ?? false)"
    }

    private func mayRetry(_ key: String) -> Bool {
        failedAttempts[key].map { Date().timeIntervalSince($0) >= 5 } ?? true
    }

    private func saveShortcutStates() { UserDefaults.standard.set(shortcuts, forKey: "screenShortcutStatesV1") }

    private func publishStatus() {
        let options = preferences.automaticScreenScaling
        var parts: [String] = []
        if options.applications {
            parts.append("应用按屏幕自动缩放")
            if preferences.configuredWindowLayoutAdapters.contains(where: \.isEnabled) { parts.append(lastWindowStatus) }
            parts += applicationStatuses.sorted { $0.key < $1.key }.map(\.value)
        }
        if options.dock && preferences.isManagedApplicationEnabled("dock") { parts.append(lastDockStatus) }
        statusChanged?(parts.isEmpty ? "按屏幕自动缩放未启用" : parts.joined(separator: "；"))
    }
}
