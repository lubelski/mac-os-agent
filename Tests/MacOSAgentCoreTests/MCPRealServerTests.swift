import Foundation
import Testing
@testable import MacOSAgentCore

/// Runs a real MCP server through the SDK client: the reference "everything" server from npm,
/// started with `npx`, found on the search PATH as the app finds it. It needs the network the
/// first time, so it runs only with MAC_OS_AGENT_REAL_MCP set.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_REAL_MCP"] != nil))
struct MCPRealServerTests {
    let entry = MCPServerEntry(name: "everything", command: "npx", args: ["-y", "@modelcontextprotocol/server-everything"])

    @Test func connectsListsCallsAndStops() async throws {
        let connection = MCPSDKConnection(entry: entry)
        try await MCPRace.withTimeout(.seconds(180)) { try await connection.connect() }
        let tools = try await connection.listTools()
        print("everything server tools: \(tools.map(\.name).joined(separator: ", "))")
        #expect(tools.contains { $0.name == "echo" })
        print("read-only: \(tools.filter(\.readOnly).map(\.name).joined(separator: ", "))")
        for tool in tools {
            let name = MCPToolNaming.names(server: entry.name, tools: tools.map(\.name))[tool.name] ?? ""
            #expect(MCPToolNaming.isValidModelName(name))
        }

        let echo = try await connection.callTool(name: "echo", arguments: ["message": "hello from a test"])
        let text = MCPToolResultText.text(for: echo)
        print("echo: \(text)")
        #expect(text.contains("hello from a test"))

        if let image = tools.first(where: { $0.name.lowercased().contains("image") }) {
            let result = try await connection.callTool(name: image.name, arguments: [:])
            let text = MCPToolResultText.text(for: result)
            print("\(image.name): \(text)")
            #expect(text.contains("an image (image/png)"))
        }

        let groups = MCPServerProcess.runningProcessGroups
        #expect(!groups.isEmpty)
        await connection.stop()
        try await Task.sleep(for: .milliseconds(500))
        #expect(MCPServerProcess.runningProcessGroups.isEmpty)
        for group in groups {
            // No process is left in the server's group, npx's node child included.
            #expect(killpg(group, 0) == -1)
        }
    }

    @Test func aMissingCommandSaysSo() async throws {
        let connection = MCPSDKConnection(entry: MCPServerEntry(name: "missing", command: "no-such-mcp-server-command"))
        await #expect(throws: MCPConnectionError.commandNotFound("no-such-mcp-server-command")) {
            try await connection.connect()
        }
    }

    @Test func aServerThatExitsSaysWhy() async throws {
        let connection = MCPSDKConnection(entry: MCPServerEntry(
            name: "broken", command: "/bin/sh", args: ["-c", "echo 'PLACEHOLDER_TOKEN is not set' >&2; exit 3"]))
        do {
            try await MCPRace.withTimeout(.seconds(10)) { try await connection.connect() }
            Issue.record("connected to a server that exits")
        } catch {
            print("exit: \(error.localizedDescription)")
            #expect(error as? MCPConnectionError == .exited(status: 3, message: "PLACEHOLDER_TOKEN is not set"))
        }
    }
}
