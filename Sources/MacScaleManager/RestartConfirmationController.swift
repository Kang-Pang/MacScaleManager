import AppKit

/// A non-modal native alert: polling Dock can continue while the user decides.
/// Present the window directly so NSAlert.runModal cannot recenter it on the
/// main display. No app is terminated by this controller.
@MainActor
final class RestartConfirmationController: NSObject, NSWindowDelegate {
    private let alert = NSAlert()
    private var completion: ((Bool) -> Void)?

    init(applicationName: String, mode: ScaleMode, screenName: String, completion: @escaping (Bool) -> Void) {
        self.completion = completion
        super.init()
        alert.messageText = "\(applicationName) 需要重启以调整缩放"
        alert.informativeText = "目标屏幕：\(screenName)\n目标参数：\(mode.title)\n\n确认后将请求应用正常退出，退出成功后写入配置并重新打开。若有未保存内容，请在应用中处理；不会强制退出。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重启并调整缩放")
        alert.addButton(withTitle: "暂不调整")
        alert.layout()
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(confirm)
        alert.buttons[1].target = self
        alert.buttons[1].action = #selector(cancel)
        // Enter must not accidentally close a working application while the
        // prompt appears. Cancel is the safe keyboard default.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        alert.window.defaultButtonCell = alert.buttons[1].cell as? NSButtonCell
        alert.window.styleMask.insert(.closable)
        alert.window.delegate = self
        alert.window.isReleasedWhenClosed = false
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.window.hidesOnDeactivate = false
    }

    func show(on screen: NSScreen) {
        NSApp.activate(ignoringOtherApps: true)
        alert.window.setFrame(ScreenPromptPlacement.frame(size: alert.window.frame.size, visibleFrame: screen.visibleFrame), display: true)
        alert.window.makeKeyAndOrderFront(nil)
        alert.window.orderFrontRegardless()
    }

    func dismiss() { finish(confirmed: false) }
    @objc private func confirm() { finish(confirmed: true) }
    @objc private func cancel() { finish(confirmed: false) }
    func windowWillClose(_ notification: Notification) { finish(confirmed: false) }

    private func finish(confirmed: Bool) {
        guard let completion else { return }
        self.completion = nil
        alert.window.delegate = nil
        alert.window.orderOut(nil)
        alert.window.close()
        completion(confirmed)
    }
}
