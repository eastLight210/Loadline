// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loadline",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Loadline",
            path: "Sources/Loadline",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
