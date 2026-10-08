import Foundation
import CoreGraphics

func check(_ actual: CGRect, _ expected: CGRect, _ name: String) {
    precondition(actual == expected, "\(name): expected \(expected), got \(actual)")
}

let screen = CGRect(x: 0, y: 0, width: 2560, height: 1440)
let visible = CGRect(x: 0, y: 60, width: 2560, height: 1350)
check(WindowLayoutGeometry.frame(screen: screen, visible: visible, style: .fillWithLeftGap,
                                 sizeFraction: 0.75, leftGapFraction: 0.1),
      CGRect(x: 256, y: 60, width: 2304, height: 1350), "10% gap fills remaining area")

check(WindowLayoutGeometry.frame(screen: screen, visible: visible, style: .fillWithLeftGap,
                                 sizeFraction: 0.75, leftGapFraction: 0.2),
      CGRect(x: 512, y: 60, width: 2048, height: 1350), "per-app gap customization")

let leftDisplay = CGRect(x: -2560, y: 400, width: 2560, height: 1440)
let leftVisible = CGRect(x: -2560, y: 460, width: 2560, height: 1350)
check(WindowLayoutGeometry.frame(screen: leftDisplay, visible: leftVisible, style: .fillWithLeftGap,
                                 sizeFraction: 0.75, leftGapFraction: 0.1),
      CGRect(x: -2304, y: 460, width: 2304, height: 1350), "offset external display")

let insetVisible = CGRect(x: 200, y: 60, width: 2360, height: 1350)
check(WindowLayoutGeometry.frame(screen: screen, visible: insetVisible, style: .fillWithLeftGap,
                                 sizeFraction: 0.75, leftGapFraction: 0.1),
      CGRect(x: 256, y: 60, width: 2304, height: 1350), "do not double-count existing inset")

let widerInset = CGRect(x: 300, y: 60, width: 2260, height: 1350)
check(WindowLayoutGeometry.frame(screen: screen, visible: widerInset, style: .fillWithLeftGap,
                                 sizeFraction: 0.75, leftGapFraction: 0.1),
      widerInset, "respect larger existing inset")

check(WindowLayoutGeometry.frame(screen: screen, visible: visible, style: .centered,
                                 sizeFraction: 0.75, leftGapFraction: 0.1),
      CGRect(x: 320, y: 229, width: 1920, height: 1012), "preserve centered layout")

let decoded = try JSONDecoder().decode(WindowLayoutStyle.self, from: Data("\"fillWithLeftGap\"".utf8))
precondition(decoded == .fillWithLeftGap, "JSON style round-trip")
print("Window layout geometry: 7 checks passed.")

precondition(!ConfigurationQuitPolicy.requiresQuit(for: "vscode", overrides: nil), "VS Code must apply live by default")
precondition(ConfigurationQuitPolicy.requiresQuit(for: "edge", overrides: nil), "Edge must preserve quit preflight by default")
precondition(!ConfigurationQuitPolicy.requiresQuit(for: "edge", overrides: ["edge": false]), "disabling quit must allow live writes")
precondition(ConfigurationQuitPolicy.requiresQuit(for: "vscode", overrides: ["vscode": true]), "explicitly enabling quit must apply to VS Code")
precondition(!ConfigurationQuitPolicy.requiresQuit(for: "dock", overrides: nil), "system appearance must not be treated as an app to quit")
print("Configuration quit policy: 5 checks passed.")
