// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuitApps",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "QuitApps",
            path: "Sources/QuitApps",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
