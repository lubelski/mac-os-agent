// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "mac-os-agent",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "MacOSAgentCore"),
        .executableTarget(
            name: "mac-os-agent",
            dependencies: ["MacOSAgentCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "MacOSAgentCoreTests", dependencies: ["MacOSAgentCore"]),
        .testTarget(name: "MacOSAgentAppTests", dependencies: ["mac-os-agent", "MacOSAgentCore"]),
    ]
)
