// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RaviVoice",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Generated Swift SDK for the Ravi gateway, from the ravi.bot checkout next door.
        .package(name: "ravi-os-swift-sdk", path: "../ravi.bot/packages/ravi-os-swift-sdk"),
    ],
    targets: [
        .executableTarget(
            name: "RaviVoice",
            dependencies: [.product(name: "RaviSDK", package: "ravi-os-swift-sdk")],
            path: "Sources/RaviVoice",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RaviVoiceTests",
            dependencies: ["RaviVoice"],
            path: "Tests/RaviVoiceTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
