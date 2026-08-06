// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacScaleManager",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MacScaleManager", targets: ["MacScaleManager"])],
    targets: [.executableTarget(name: "MacScaleManager")]
)
