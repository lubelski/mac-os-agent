// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "mac-os-agent",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // The MCP client. Only `MCP/MCPSDKConnection.swift` imports it. See `MCPServerConnection`.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "MacOSAgentCore",
            dependencies: [.product(name: "MCP", package: "swift-sdk")]
        ),
        // Runs one `run_script` script in JavaScriptCore, in a process of its own. See
        // `ScriptRunner` in MacOSAgentCore.
        // The App Sandbox needs a bundle identifier, which a command-line tool carries in an
        // Info.plist linked into its binary.
        .executableTarget(
            name: "mac-os-agent-script-runner",
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Resources/mac-os-agent-script-runner-Info.plist",
            ])]
        ),
        .executableTarget(
            name: "mac-os-agent",
            dependencies: ["MacOSAgentCore", .product(name: "Sparkle", package: "Sparkle")]
        ),
        .testTarget(name: "MacOSAgentCoreTests", dependencies: ["MacOSAgentCore", "mac-os-agent-script-runner"]),
        .testTarget(name: "MacOSAgentAppTests", dependencies: ["mac-os-agent", "MacOSAgentCore"]),
    ]
)
