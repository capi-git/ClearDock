// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClearDock",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ClearDock",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
