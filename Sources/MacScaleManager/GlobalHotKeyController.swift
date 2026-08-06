import Carbon.HIToolbox
import Foundation

/// Registers a process-wide shortcut while MacScaleManager is running.
final class GlobalHotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    nonisolated(unsafe) fileprivate static var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        Self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            globalHotKeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        var hotKeyID = EventHotKeyID(signature: OSType(0x4D534D47), id: 1) // MSMG
        RegisterEventHotKey(
            UInt32(kVK_ANSI_I),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
        Self.action = nil
    }
}

private let globalHotKeyHandler: EventHandlerUPP = { _, _, _ in
    DispatchQueue.main.async {
        GlobalHotKeyController.action?()
    }
    return noErr
}
