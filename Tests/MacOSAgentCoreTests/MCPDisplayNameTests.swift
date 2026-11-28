import Foundation
import Synchronization
import Testing
@testable import MacOSAgentCore

/// A connection that starts no process and says what the test gives it about itself.
private struct DescribedConnection: MCPServerConnection {
    let tools: [MCPToolInfo]
    let serverInfo: MCPServerInfo?

    func connect() async throws {}
    func listTools() async throws -> [MCPToolInfo] { tools }
    func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult { MCPCallResult(content: [.text("done")]) }
    func stop() async {}
}

private struct Folder {
    let url = FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-mcp-names-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var settings: URL { url.appending(path: "mcp-settings.json") }
    var cache: URL { url.appending(path: "mcp-tools-cache.json") }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private let forecast = MCPToolInfo(
    name: "get_forecast", title: "Forecast", description: "The forecast for a city.",
    inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]], readOnly: true)
private let addAlert = MCPToolInfo(
    name: "add_alert", description: "Adds a weather alert.", inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])

@Suite struct HumanizedNameTests {
    @Test(arguments: [
        ("linear", "Linear"),
        ("github-pr-explorer", "Github PR Explorer"),
        ("get_attachment", "Get Attachment"),
        ("getAttachment", "Get Attachment"),
        ("getHTTPResponse", "Get HTTP Response"),
        ("HTTPServer", "HTTP Server"),
        ("add_to_list", "Add to List"),
        ("to_do", "To Do"),
        ("list_issues_v2", "List Issues V2"),
        ("s3_bucket", "S3 Bucket"),
        ("user.id", "User ID"),
        ("api-url", "API URL"),
        ("ui_mcp", "UI MCP"),
        ("SEND_EMAIL", "Send Email"),
        ("weather__get_forecast", "Weather Get Forecast"),
        ("  spaced  out ", "Spaced Out"),
        ("calendar-sync", "Calendar Sync"),
        ("a", "A"),
    ])
    func humanizes(_ name: String, _ expected: String) {
        #expect(HumanizedName.from(name) == expected)
    }

    @Test func aNameOfOnlySeparatorsIsKeptAsItIs() {
        #expect(HumanizedName.from("__") == "__")
        #expect(HumanizedName.from("") == "")
    }
}

@Suite struct MCPDisplayNameStoreTests {
    @Test func namesDefaultToTheHumanizedOnes() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = MCPSettingsStore(file: folder.settings)
        #expect(store.serverNameOverride("calendar-sync") == nil)
        #expect(store.serverDisplayName("calendar-sync") == "Calendar Sync")
        #expect(store.toolDisplayName(server: "weather", tool: "get_forecast") == "Get Forecast")
    }

    @Test func overridesRoundTripThroughTheFile() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = MCPSettingsStore(file: folder.settings)
        try store.setServerDisplayName("Forecasts", server: "weather")
        try store.setToolDisplayName("  Five Days  ", server: "weather", tool: "get_forecast")
        let reread = MCPSettingsStore(file: folder.settings)
        #expect(reread.serverDisplayName("weather") == "Forecasts")
        #expect(reread.toolDisplayName(server: "weather", tool: "get_forecast") == "Five Days")
        #expect(reread.toolDisplayName(server: "weather", tool: "add_alert") == "Add Alert")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.settings)) as? [String: Any])
        #expect(json["serverNames"] as? [String: String] == ["weather": "Forecasts"])
        #expect(json["toolNames"] as? [String: [String: String]] == ["weather": ["get_forecast": "Five Days"]])
    }

    @Test func anEmptyNameOrTheDefaultMeansTheDefault() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = MCPSettingsStore(file: folder.settings)
        try store.setServerDisplayName("Forecasts", server: "weather")
        try store.setServerDisplayName("   ", server: "weather")
        #expect(store.serverNameOverride("weather") == nil)
        try store.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        try store.setToolDisplayName("Get Forecast", server: "weather", tool: "get_forecast")
        #expect(store.toolNameOverride(server: "weather", tool: "get_forecast") == nil)
        try store.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        try store.setToolDisplayName(nil, server: "weather", tool: "get_forecast")
        #expect(store.toolNameOverride(server: "weather", tool: "get_forecast") == nil)
        // With none left, the keys go too, so the file is as it was before names existed.
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.settings)) as? [String: Any])
        #expect(json["serverNames"] == nil)
        #expect(json["toolNames"] == nil)
    }

    @Test func aFileFromBeforeDisplayNamesStillLoads() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try Data(#"{"disabled":["notes"],"goAhead":{"weather":{"add_alert":"deny"}}}"#.utf8).write(to: folder.settings)
        let store = MCPSettingsStore(file: folder.settings)
        #expect(!store.isEnabled("notes"))
        #expect(store.goAhead(server: "weather", tool: "add_alert", readOnly: false) == .deny)
        #expect(store.serverDisplayName("notes") == "Notes")
        // A change to something else keeps the file free of the new keys.
        try store.setEnabled(true, server: "notes")
        let text = try String(contentsOf: folder.settings, encoding: .utf8)
        #expect(!text.contains("serverNames"))
        #expect(!text.contains("toolNames"))
    }

    @Test func namesOfTheWrongShapeAreSkippedAndTheRestLoads() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try Data(#"{"disabled":["notes"],"serverNames":["not", "an", "object"],"toolNames":{"weather":{"get_forecast":"Five Days"}}}"#.utf8)
            .write(to: folder.settings)
        let store = MCPSettingsStore(file: folder.settings)
        #expect(!store.isEnabled("notes"))
        #expect(store.serverNameOverride("weather") == nil)
        #expect(store.toolDisplayName(server: "weather", tool: "get_forecast") == "Five Days")
    }

    @Test func aChangePostsSoSettingsReadsAgain() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = MCPSettingsStore(file: folder.settings)
        let changes = Mutex(0)
        let observer = NotificationCenter.default.addObserver(forName: MCPSettingsStore.namesDidChange, object: store, queue: nil) { _ in
            changes.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try store.setServerDisplayName("Forecasts", server: "weather")
        try store.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        #expect(changes.withLock { $0 } == 2)
    }
}

@Suite struct MCPServerDescriptionTests {
    @Test func theFileCanDescribeAServer() {
        let config = MCPServerConfig.parse(Data(#"""
            {"mcpServers": {
              "weather": {"command": "npx", "description": "Forecasts for my trips."},
              "notes": {"command": "uvx", "description": 3},
              "clock": {"command": "npx"}
            }}
            """#.utf8))
        #expect(config.servers.map(\.name) == ["clock", "notes", "weather"])
        #expect(config.servers.allSatisfy { $0.problem == nil })
        #expect(config.servers[2].description == "Forecasts for my trips.")
        // A description that is not a string is left out, and the entry still works.
        #expect(config.servers[1].description == nil)
        #expect(config.servers[0].description == nil)
    }

    @Test func theOwnersDescriptionComesFirstThenTheServersThenItsInstructions() {
        let info = MCPServerInfo(
            name: "weather-mcp", version: "1.0", description: "Weather from a service.",
            instructions: "Use these tools for forecasts. Ask for a city first.")
        let described = MCPServerEntry(name: "weather", command: "npx", description: "  Forecasts\nfor my trips. ")
        let plain = MCPServerEntry(name: "weather", command: "npx")
        #expect(MCPServerSummary.resolve(entry: described, info: info) == MCPServerSummary(text: "Forecasts for my trips.", source: .file))
        #expect(MCPServerSummary.resolve(entry: plain, info: info) == MCPServerSummary(text: "Weather from a service.", source: .server))
        var withInstructionsOnly = info
        withInstructionsOnly.description = "  "
        #expect(MCPServerSummary.resolve(entry: plain, info: withInstructionsOnly)
            == MCPServerSummary(text: "Use these tools for forecasts.", source: .instructions))
        #expect(MCPServerSummary.resolve(entry: plain, info: MCPServerInfo(name: "weather-mcp", version: "1.0")) == nil)
        #expect(MCPServerSummary.resolve(entry: plain, info: nil) == nil)
    }

    @Test func whatAServerSaysAboutItselfIsKeptWithItsTools() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let info = MCPServerInfo(name: "weather-mcp", title: "Weather", version: "1.4.0", description: "Weather from a service.")
        let pool = MCPServerPool(
            config: MCPServerConfig(servers: [MCPServerEntry(name: "weather", command: "/usr/bin/true")]),
            settings: MCPSettingsStore(file: folder.settings), cache: MCPToolCache(), cacheFile: folder.cache,
            factory: { _ in DescribedConnection(tools: [forecast], serverInfo: info) })
        _ = try await pool.connection(to: "weather")
        let status = try #require(await pool.statuses().first)
        #expect(status.serverInfo == info)
        #expect(status.summary?.source == .server)
        #expect(MCPToolCache.read(from: folder.cache).servers["weather"]?.server == info)

        // The next launch shows it before the server connects again.
        let next = MCPServerPool(
            config: MCPServerConfig(servers: [MCPServerEntry(name: "weather", command: "/usr/bin/true")]),
            settings: MCPSettingsStore(file: folder.settings), cache: MCPToolCache.read(from: folder.cache), cacheFile: nil,
            factory: { _ in DescribedConnection(tools: [forecast], serverInfo: nil) })
        #expect(await next.statuses().first?.serverInfo == info)
    }

    @Test func aChangeInWhatTheServerSaysAloneIsCachedToo() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let info = MCPServerInfo(name: "weather-mcp", version: "2.0")
        let cache = MCPToolCache(servers: ["weather": .init(tools: [forecast], updated: Date(timeIntervalSince1970: 0))])
        let pool = MCPServerPool(
            config: MCPServerConfig(servers: [MCPServerEntry(name: "weather", command: "/usr/bin/true")]),
            settings: MCPSettingsStore(file: folder.settings), cache: cache, cacheFile: folder.cache,
            factory: { _ in DescribedConnection(tools: [forecast], serverInfo: info) })
        _ = try await pool.connection(to: "weather")
        let entry = try #require(MCPToolCache.read(from: folder.cache).servers["weather"])
        #expect(entry.server == info)
        // The date still says when the tools last changed.
        #expect(entry.updated == Date(timeIntervalSince1970: 0))
    }

    @Test func aCacheFromBeforeServerInfoStillLoads() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try Data(#"""
            {"servers": {"weather": {"updated": "2026-11-21T09:00:00Z", "tools": [
              {"name": "get_forecast", "description": "The forecast.", "readOnly": true, "inputSchema": {"type": "object"}}
            ]}}}
            """#.utf8).write(to: folder.cache)
        let cache = MCPToolCache.read(from: folder.cache)
        #expect(cache.servers["weather"]?.tools.map(\.name) == ["get_forecast"])
        #expect(cache.servers["weather"]?.server == nil)
    }
}

/// Display names are for people. What the model is sent stays the same, so the prompt cache
/// holds whatever the owner calls a server or a tool.
@Suite struct MCPDisplayNamesLeaveTheRequestAloneTests {
    @Test func namesChangeNothingTheModelIsSent() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let settings = MCPSettingsStore(file: folder.settings)
        let pool = MCPServerPool(
            config: MCPServerConfig(servers: [MCPServerEntry(name: "weather", command: "/usr/bin/true", description: "Forecasts.")]),
            settings: settings, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast, addAlert])]), cacheFile: nil,
            factory: { _ in DescribedConnection(tools: [], serverInfo: nil) })
        func body() throws -> Data {
            let registry = ToolRegistry(builtIn: [ShellCommandTool()], additional: pool.makeTools())
            let body = OpenAIResponses.body(
                for: ModelRequest(instructions: "", entries: [], tools: registry.definitions),
                model: "gpt-test", reasoningEffort: "low", promptCacheKey: "k")
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(body)
        }
        let before = try body()
        try settings.setServerDisplayName("Forecasts", server: "weather")
        try settings.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        try settings.setToolDisplayName("Warn Me", server: "weather", tool: "add_alert")
        let after = try body()
        #expect(before == after)
        let text = String(decoding: after, as: UTF8.self)
        #expect(text.contains("weather__get_forecast"))
        #expect(!text.contains("Five Days"))
        #expect(!text.contains("Forecasts"))
    }
}
