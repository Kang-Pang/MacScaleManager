import AppKit
import Foundation

enum ScaleMode: String, CaseIterable, Identifiable {
    case laptop, desktop, custom
    var id: String { rawValue }
    var title: String { switch self { case .laptop: "Laptop Mode"; case .desktop: "Desktop Mode"; case .custom: "Custom Mode" } }
    var symbolName: String { switch self { case .laptop: "laptopcomputer"; case .desktop: "display"; case .custom: "slider.horizontal.3" } }
}

struct ScaleProfile: Codable, Equatable {
    var editorFontSize: Double
    var terminalFontSize: Double
    var vscodeZoom: Int
    var browserZoomPercent: Int
    var dockSize: Int
    var cursorSize: Double

    static let desktop = ScaleProfile(editorFontSize: 16, terminalFontSize: 15, vscodeZoom: 1, browserZoomPercent: 125, dockSize: 56, cursorSize: 1.35)
    static let laptop = ScaleProfile(editorFontSize: 14, terminalFontSize: 13, vscodeZoom: 0, browserZoomPercent: 100, dockSize: 36, cursorSize: 1.0)
}

@MainActor
final class ScaleManager: ObservableObject {
    @Published private(set) var currentMode: ScaleMode
    @Published private(set) var lastError: String?
    @Published private(set) var lastImmediateResult: String?
    @Published private(set) var builtInDisplayStatus: BuiltInDisplayStatus
    @Published private(set) var lastDisplayResult: String?
    private var hotKeyController: GlobalHotKeyController?
    var preferences = ManagedPreferences()

    init() {
        currentMode = ScaleMode(rawValue: UserDefaults.standard.string(forKey: "currentMode") ?? "laptop") ?? .laptop
        lastError = nil
        lastImmediateResult = nil
        let initialDisplayStatus = DisplayController.currentStatus()
        builtInDisplayStatus = initialDisplayStatus
        lastDisplayResult = nil
        hotKeyController = nil
        // Persisting the selected mode also makes a launch after an app update or
        // restart restore the intended workspace configuration.
        do {
            if currentMode == .laptop {
                try preferences.restoreOrApplyLaptopDefaults()
                if preferences.manageTerminal { try? preferences.restoreTerminalFont() }
            } else {
                try preferences.apply(profile: profile(for: currentMode))
                if preferences.manageTerminal { try? preferences.applyTerminalFont(size: profile(for: currentMode).terminalFontSize) }
            }
        } catch { lastError = error.localizedDescription }
        hotKeyController = GlobalHotKeyController { [weak self] in
            self?.enableBuiltInDisplay()
        }
    }

    func profile(for mode: ScaleMode) -> ScaleProfile {
        if mode == .custom { return preferences.customProfile }
        return mode == .desktop ? preferences.desktopProfile : .laptop
    }

    func apply(_ mode: ScaleMode) {
        if preferences.immediateMode {
            lastImmediateResult = ImmediateZoomController.apply(mode: mode, targets: preferences.immediateTargets, customTargets: preferences.customImmediateApps, zoomSteps: preferences.immediateZoomSteps, laptopActions: preferences.immediateLaptopActions)
        }
        do {
            // Laptop Mode is deliberately a restore operation: users' original values
            // are more trustworthy than a guessed macOS/IDE "default".
            if mode == .laptop {
                try preferences.restoreOrApplyLaptopDefaults()
                if preferences.manageTerminal { try? preferences.restoreTerminalFont() }
            } else {
                try preferences.apply(profile: profile(for: mode))
                if preferences.manageTerminal { try? preferences.applyTerminalFont(size: profile(for: mode).terminalFontSize) }
            }
            currentMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "currentMode")
            lastError = nil
        } catch { presentModeFailure(error.localizedDescription) }
    }

    func restoreDefaults() {
        do {
            try preferences.restoreOrApplyLaptopDefaults()
            if preferences.manageTerminal { try? preferences.restoreTerminalFont() }
            currentMode = .laptop
            UserDefaults.standard.set(ScaleMode.laptop.rawValue, forKey: "currentMode")
            lastError = nil
        } catch { presentModeFailure(error.localizedDescription) }
    }

    private func presentModeFailure(_ message: String) {
        lastError = message
        let alert = NSAlert()
        alert.messageText = "模式切换失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func enableBuiltInDisplay() {
        switch DisplayController.setBuiltInDisplay(enabled: true) {
        case .success(let message):
            lastDisplayResult = message
            lastError = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.builtInDisplayStatus = DisplayController.currentStatus()
            }
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func toggleBuiltInDisplay() {
        let enable = !builtInDisplayStatus.isEnabled
        switch DisplayController.setBuiltInDisplay(enabled: enable) {
        case .success(let message):
            lastDisplayResult = message
            lastError = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.builtInDisplayStatus = DisplayController.currentStatus()
            }
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    func refreshDisplayStatus() {
        builtInDisplayStatus = DisplayController.currentStatus()
    }
}