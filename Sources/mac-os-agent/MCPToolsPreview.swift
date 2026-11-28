import Foundation
import MacOSAgentCore

/// Stand-in MCP servers for panel states, with display names set, so the rows and the go-ahead
/// card show them. Nothing here starts a process, reads the data folder, or writes a file: the
/// names are held in memory by a store over `/dev/null`.
///
/// `tasks` is called Home Tasks, and its `create_task` has the default name, Create Task.
/// `weather` has the default name, Weather, and its `get_forecast` is called Five-Day Forecast.
/// `notes` is not a server here, so a call to it reads by its literal names made readable.
@MainActor
enum MCPToolsPreview {
    static let names = ["mcp-tools"]

    /// The servers' tools, as a run would have them.
    static let tools: [any AgentTool] = {
        let settings = MCPSettingsStore(file: URL(filePath: "/dev/null"))
        // The store keeps a change in memory even when the file cannot be written.
        try? settings.setServerDisplayName("Home Tasks", server: "tasks")
        try? settings.setToolDisplayName("Five-Day Forecast", server: "weather", tool: "get_forecast")
        let object: JSONValue = ["type": "object", "properties": [:]]
        let pool = MCPServerPool(
            config: MCPServerConfig(servers: [
                MCPServerEntry(name: "tasks", command: "/usr/bin/true"),
                MCPServerEntry(name: "weather", command: "/usr/bin/true"),
            ]),
            settings: settings,
            cache: MCPToolCache(servers: [
                "tasks": .init(tools: [MCPToolInfo(name: "create_task", description: "Creates a task.", inputSchema: object)]),
                "weather": .init(tools: [
                    MCPToolInfo(name: "get_forecast", description: "The forecast for a city.", inputSchema: object, readOnly: true),
                ]),
            ]),
            cacheFile: nil, factory: { _ in NoConnection() })
        return pool.makeTools()
    }()

    /// What the rows say, by display names: the built-in tools' summaries and these servers'.
    static var summaries: ToolCallSummaries {
        ToolRegistry(builtIn: BuiltInTools.make(webSearch: SearchWebTool(key: nil)), additional: tools).summaries.showingDisplayNames()
    }

    /// The display names a go-ahead card for one of the tools shows.
    static func displayNames(of name: String) -> ConfirmationRequest.DisplayNames? {
        (tools.first { $0.definition.name == name } as? MCPTool)?.displayNames
    }

    static func session(named name: String) -> AgentSession? {
        switch name {
        case "mcp-tools": return toolsSession()
        default: return nil
        }
    }

    /// Calls to two listed tools, one renamed, and to a server since removed.
    private static func toolsSession() -> AgentSession {
        var thread = PanelPreview.StandInThread(now: Date())
        thread.user("what's the weather in lisbon this week, and remind me to pack an umbrella", minutesAgo: 2)
        thread.call(
            "call_forecast", name: "weather__get_forecast", arguments: ["city": "Lisbon", "days": 5],
            output: "Mon 18° rain, Tue 17° rain, Wed 19° cloudy, Thu 21° sun, Fri 20° sun", details: nil)
        thread.call(
            "call_task", name: "tasks__create_task", arguments: ["title": "Pack an umbrella", "due": "2026-11-29"],
            output: "Created task 4821.", details: nil)
        // A server that has since been removed from mcp-servers.json.
        thread.call(
            "call_notes", name: "notes__search_notes", arguments: ["query": "Lisbon trip"],
            output: "2 notes: Lisbon trip, Packing list", details: nil)
        thread.reply("Rain Monday and Tuesday, then sun from Thursday. I added Pack an umbrella to your tasks for Saturday, and your Lisbon trip note is there too.")
        return AgentSession(previewEntries: thread.entries, summaries: summaries)
    }

    private struct NoConnection: MCPServerConnection {
        func connect() async throws { throw MCPConnectionError.notConnected }
        func listTools() async throws -> [MCPToolInfo] { [] }
        func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult { throw MCPConnectionError.notConnected }
        func stop() async {}
    }
}
