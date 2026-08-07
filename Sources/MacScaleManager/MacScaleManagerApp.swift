import AppKit
import SwiftUI

@main
struct MacScaleManagerApp: App {
    @StateObject private var manager = ScaleManager()

    var body: some Scene {
        MenuBarExtra("MacScaleManager", systemImage: manager.currentMode.symbolName) {
            MenuContent(manager: manager)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(manager: manager)
        }
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
        Divider()
        Button { manager.apply(.laptop) } label: {
            Label("Laptop Mode", systemImage: manager.currentMode == .laptop ? "checkmark.circle.fill" : "circle")
        }
        Button { manager.apply(.desktop) } label: {
            Label("Desktop Mode", systemImage: manager.currentMode == .desktop ? "checkmark.circle.fill" : "circle")
        }
        Button { manager.apply(.custom) } label: {
            Label("Custom Mode", systemImage: manager.currentMode == .custom ? "checkmark.circle.fill" : "circle")
        }
        if let error = manager.lastError {
            Text("切换失败：\(error)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .systemRed))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
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
        SettingsLink { Text("Settings…") }
        Button("Restore Default") { manager.restoreDefaults() }
        Divider()
        Button("Quit") { NSApplication.shared.terminate(nil) }
    }
}
