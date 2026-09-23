// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loadline",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Loadline",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Loadline",
            swiftSettings: [.swiftLanguageMode(.v5)],
            // build.sh embeds Sparkle.framework in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        )
    ]
)
