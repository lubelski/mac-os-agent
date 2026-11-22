// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "mac-os-agent",
    platforms: [.macOS(.v27)],
    targets: [
        .target(name: "MacOSAgentCore"),
        .executableTarget(name: "mac-os-agent", dependencies: ["MacOSAgentCore"]),
        .testTarget(name: "MacOSAgentCoreTests", dependencies: ["MacOSAgentCore"]),
    ]
)
