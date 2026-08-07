import AppKit
import SwiftUI

@main
struct MacScaleManagerApp: App {
    @StateObject private var manager = ScaleManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(manager: manager)
        } label: {
            Image(systemName: manager.accessibilityTrusted ? manager.currentMode.symbolName : "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(manager.accessibilityTrusted ? (manager.currentMode == .desktop ? Color.blue : Color.gray) : Color.orange)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(manager: ScaleManager, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(manager: manager)))
        window.title = "MacScaleManager Settings"
        window.setContentSize(NSSize(width: 580, height: 720))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func windowWillClose(_ notification: Notification) {
        // NSApplication may keep a closed window alive briefly. Detach the hosted
        // SwiftUI hierarchy immediately so Settings and its app list are not kept
        // resident by that cache.
        window?.contentViewController = nil
        window?.delegate = nil
        onClose()
    }
}

private struct MenuContent: View {
    @ObservedObject var manager: ScaleManager

    var body: some View {
        Text("MacScaleManager")
            .font(.headline)
            .onAppear { manager.refreshDisplayStatus() }
        Text("当前模式：\(manager.currentMode.title)")
            .foregroundStyle(.secondary)
        Text(manager.preflightSummary(for: manager.currentMode == .desktop ? .laptop : .desktop))
            .font(.caption)
            .foregroundStyle(.secondary)
        if let progress = manager.preflightProgress {
            Text(progress)
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        }
        Divider()
        Button { manager.requestApply(.laptop) } label: {
            Label("Laptop Mode", systemImage: manager.currentMode == .laptop ? "checkmark.circle.fill" : "circle")
        }
        Button { manager.requestApply(.desktop) } label: {
            Label("Desktop Mode", systemImage: manager.currentMode == .desktop ? "checkmark.circle.fill" : "circle")
        }
        Button("只同步当前前台应用") { manager.syncFrontmostImmediateApp() }
        if let result = manager.lastImmediateResult {
            Text(result)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Divider()
        Button("启用内置显示器（⌃⌥I）") { manager.enableBuiltInDisplay() }
            .disabled(manager.builtInDisplayStatus.isEnabled)
        Button(manager.builtInDisplayStatus.isEnabled ? "关闭内置显示器" : "重新启用内置显示器") {
            manager.toggleBuiltInDisplay()
        }
        Divider()
        Button("Settings…") { manager.openSettings() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
