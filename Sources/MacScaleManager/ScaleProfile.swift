import Foundation

enum ScaleMode: String, CaseIterable, Identifiable {
    case laptop, desktop
    var id: String { rawValue }
    var title: String { switch self { case .laptop: "Laptop Mode"; case .desktop: "Desktop Mode" } }
    var symbolName: String { switch self { case .laptop: "laptopcomputer"; case .desktop: "display" } }
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
