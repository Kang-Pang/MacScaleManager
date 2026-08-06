import CoreGraphics
import Darwin
import Foundation

struct BuiltInDisplayStatus {
    let builtInAvailable: Bool
    let isEnabled: Bool
    let hasExternalDisplay: Bool

    var canDisable: Bool { builtInAvailable && isEnabled && hasExternalDisplay }
}

@MainActor
enum DisplayController {
    /// macOS does not expose an API for enabling or disabling an individual
    /// display. This is the same private CoreGraphics entry point used by
    /// displayplacer, resolved dynamically so the app still launches if Apple
    /// removes it in a future macOS release.
    private typealias ConfigureDisplayEnabled = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> CGError

    static func currentStatus() -> BuiltInDisplayStatus {
        let displays = onlineDisplays()
        let builtIn = displays.first(where: { CGDisplayIsBuiltin($0) != 0 })
        let externalIsActive = displays.contains {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0
        }
        return BuiltInDisplayStatus(
            builtInAvailable: builtIn != nil || savedBuiltInDisplayID != nil,
            isEnabled: builtIn.map { CGDisplayIsActive($0) != 0 } ?? false,
            hasExternalDisplay: externalIsActive
        )
    }


    static func setBuiltInDisplay(enabled: Bool) -> Result<String, DisplayControlError> {
        let status = currentStatus()
        guard status.builtInAvailable else { return .failure(.builtInNotFound) }
        guard enabled || status.hasExternalDisplay else { return .failure(.externalDisplayRequired) }
        guard let builtIn = activeOrSavedBuiltInDisplayID else {
            return .failure(.builtInNotFound)
        }
        if !enabled {
            UserDefaults.standard.set(Int(builtIn), forKey: builtInDisplayIDKey)
        }
        guard let configure = configureDisplayEnabled else { return .failure(.unsupportedSystemVersion) }

        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success else { return .failure(.coreGraphicsError(beginResult)) }

        let configureResult = configure(configuration, builtIn, enabled)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            return .failure(.coreGraphicsError(configureResult))
        }

        let completeResult = CGCompleteDisplayConfiguration(configuration, .permanently)
        guard completeResult == .success else { return .failure(.coreGraphicsError(completeResult)) }
        return .success(enabled ? "已重新启用内置显示器。" : "已关闭内置显示器；可从菜单栏再次重新启用。")
    }


    private static let builtInDisplayIDKey = "managedBuiltInDisplayID"

    private static var savedBuiltInDisplayID: CGDirectDisplayID? {
        guard let number = UserDefaults.standard.object(forKey: builtInDisplayIDKey) as? NSNumber else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static var activeOrSavedBuiltInDisplayID: CGDirectDisplayID? {
        onlineDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? savedBuiltInDisplayID
    }

    private static var configureDisplayEnabled: ConfigureDisplayEnabled? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureDisplayEnabled.self)
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let result = CGGetOnlineDisplayList(UInt32(displayIDs.count), &displayIDs, &count)
        guard result == .success else { return [] }
        return Array(displayIDs.prefix(Int(count)))
    }
}

enum DisplayControlError: LocalizedError {
    case builtInNotFound
    case externalDisplayRequired
    case unsupportedSystemVersion
    case coreGraphicsError(CGError)

    var errorDescription: String? {
        switch self {
        case .builtInNotFound:
            return "未检测到内置显示器。"
        case .externalDisplayRequired:
            return "请先连接并启用至少一个外接显示器，再关闭内置显示器。"
        case .unsupportedSystemVersion:
            return "当前 macOS 版本不支持内置显示器开关。"
        case .coreGraphicsError(let error):
            return "系统未能应用显示器变更（CoreGraphics 错误 \(error.rawValue)）。"
        }
    }
}