import Foundation
import Synchronization
import Testing
@testable import MacOSAgentCore

/// A connection that starts no process. Each part acts as the test says.
private final class StandInConnection: MCPServerConnection {
    let connectDelay: Duration?
    let connectError: Error?
    let tools: [MCPToolInfo]
    let result: MCPCallResult
    private let state = Mutex<(connects: Int, calls: [String], stops: Int)>((0, [], 0))

    init(connectDelay: Duration? = nil, connectError: Error? = nil, tools: [MCPToolInfo] = [], result: MCPCallResult = MCPCallResult(content: [.text("done")])) {
        self.connectDelay = connectDelay
        self.connectError = connectError
        self.tools = tools
        self.result = result
    }

    var connects: Int { state.withLock { $0.connects } }
    var calls: [String] { state.withLock { $0.calls } }
    var stops: Int { state.withLock { $0.stops } }

    func connect() async throws {
        state.withLock { $0.connects += 1 }
        if let connectDelay { try await Task.sleep(for: connectDelay) }
        if let connectError { throw connectError }
    }

    func listTools() async throws -> [MCPToolInfo] { tools }

    func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
        state.withLock { $0.calls.append(name) }
        return result
    }

    func stop() async { state.withLock { $0.stops += 1 } }
}

private struct Folder {
    let url = FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-mcp-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var servers: URL { url.appending(path: "mcp-servers.json") }
    var settings: URL { url.appending(path: "mcp-settings.json") }
    var cache: URL { url.appending(path: "mcp-tools-cache.json") }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

private let forecast = MCPToolInfo(
    name: "get_forecast", description: "The forecast for a city.",
    inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]], readOnly: true)
private let addAlert = MCPToolInfo(
    name: "add_alert", description: "Adds a weather alert.", inputSchema: ["type": "object", "properties": ["city": ["type": "string"]]])

private func config(_ names: String...) -> MCPServerConfig {
    MCPServerConfig(servers: names.map { MCPServerEntry(name: $0, command: "/usr/bin/true") })
}

private func pool(
    _ config: MCPServerConfig, folder: Folder, cache: MCPToolCache = MCPToolCache(),
    connectTimeout: Duration = .seconds(5), callTimeout: Duration = .seconds(5),
    connection: @escaping @Sendable (MCPServerEntry) -> any MCPServerConnection
) -> MCPServerPool {
    MCPServerPool(
        config: config, settings: MCPSettingsStore(file: folder.settings), cache: cache, cacheFile: folder.cache,
        connectTimeout: connectTimeout, callTimeout: callTimeout, factory: connection)
}

private final class Asked: Sendable {
    private let list = Mutex<[ConfirmationRequest]>([])
    func append(_ request: ConfirmationRequest) { list.withLock { $0.append(request) } }
    var requests: [ConfirmationRequest] { list.withLock { $0 } }
}

private func context(approve: Bool, asked: Asked? = nil) -> ToolRunContext {
    ToolRunContext(callID: "call_1") { request in
        asked?.append(request)
        return approve
    }
}

// MARK: - The servers file

@Suite struct MCPServerConfigTests {
    @Test func readsTheMCPServersShape() throws {
        let config = MCPServerConfig.parse(Data("""
            {"mcpServers": {
              "weather": {"command": "npx", "args": ["-y", "weather-mcp"], "env": {"WEATHER_KEY": "placeholder"}},
              "files": {"command": "/usr/local/bin/files-mcp"}
            }}
            """.utf8))
        #expect(config.fileProblem == nil)
        #expect(config.servers.map(\.name) == ["files", "weather"])
        #expect(config.servers[1] == MCPServerEntry(name: "weather", command: "npx", args: ["-y", "weather-mcp"], env: ["WEATHER_KEY": "placeholder"]))
        #expect(config.problems.isEmpty)
        #expect(config.servers[1].commandLine == "npx -y weather-mcp")
    }

    @Test func aFileThatCannotBeReadIsOneProblem() {
        #expect(MCPServerConfig.parse(Data("{ not json".utf8)).fileProblem == "mcp-servers.json is not valid JSON.")
        #expect(MCPServerConfig.parse(Data("[]".utf8)).fileProblem != nil)
        #expect(MCPServerConfig.parse(Data(#"{"servers": {}}"#.utf8)).fileProblem == #"mcp-servers.json has no "mcpServers" object."#)
        #expect(MCPServerConfig.parse(Data(#"{"mcpServers": []}"#.utf8)).fileProblem != nil)
        let empty = MCPServerConfig.parse(Data("  \n".utf8))
        #expect(empty.fileProblem == nil && empty.servers.isEmpty)
    }

    @Test func aWrongEntryKeepsItsProblemAndTheRestLoad() {
        let config = MCPServerConfig.parse(Data("""
            {"mcpServers": {
              "good": {"command": "uvx", "args": ["good-mcp"]},
              "no-command": {"args": []},
              "remote": {"url": "https://example.com/mcp"},
              "bad-args": {"command": "npx", "args": "-y thing"},
              "bad-env": {"command": "npx", "env": {"PORT": 8080}},
              "sse": {"command": "npx", "type": "sse"},
              "not-an-object": "npx"
            }}
            """.utf8))
        #expect(config.usableServers.map(\.name) == ["good"])
        let problems = Dictionary(uniqueKeysWithValues: config.servers.map { ($0.name, $0.problem) })
        #expect(problems["no-command"] == #"The entry has no "command"."#)
        #expect(problems["remote"]??.contains("Remote servers are not supported") == true)
        #expect(problems["bad-args"] == #""args" should be a list of strings."#)
        #expect(problems["bad-env"] == #""env" should be an object of strings."#)
        #expect(problems["sse"]??.contains("stdio") == true)
        #expect(problems["not-an-object"] != nil)
        #expect(config.problems.count == 6)
        #expect(config.problems.contains { $0.hasPrefix("no-command: ") })
    }

    @Test func serverNamesMustBeSafeInAToolName() {
        for good in ["weather", "my-server", "github_2", "a", String(repeating: "x", count: 32)] {
            #expect(MCPServerConfig.problem(withName: good) == nil, "\(good)")
        }
        for bad in ["", "my server", "weather.app", "über", "two__parts", "_lead", "trail_", String(repeating: "x", count: 33), "a/b"] {
            #expect(MCPServerConfig.problem(withName: bad) != nil, "\(bad)")
        }
        let config = MCPServerConfig.parse(Data(#"{"mcpServers": {"my server": {"command": "npx"}, "ok": {"command": "npx"}}}"#.utf8))
        #expect(config.usableServers.map(\.name) == ["ok"])
        #expect(config.servers.first { $0.name == "my server" }?.problem?.contains("letters, digits") == true)
    }

    @Test func aMissingFileIsNoServersAndNoProblem() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let config = MCPServerConfig.read(from: folder.servers)
        #expect(!config.fileExists)
        #expect(config.servers.isEmpty && config.problems.isEmpty)
    }

    @Test func theFileIsMadeReadableOnlyByTheOwner() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try Data(#"{"mcpServers": {}}"#.utf8).write(to: folder.servers)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.servers.path)
        _ = MCPServerConfig.read(from: folder.servers)
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.servers.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }
}

// MARK: - The settings file

@Suite struct MCPSettingsTests {
    @Test func serversAreOnUntilTurnedOff() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = MCPSettingsStore(file: folder.settings)
        #expect(store.isEnabled("weather"))
        try store.setEnabled(false, server: "weather")
        #expect(!store.isEnabled("weather"))
        #expect(!MCPSettingsStore(file: folder.settings).isEnabled("weather"))
        try store.setEnabled(true, server: "weather")
        #expect(MCPSettingsStore(file: folder.settings).isEnabled("weather"))
    }

    @Test func goAheadDefaultsToAskUnlessReadOnly() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = MCPSettingsStore(file: folder.settings)
        #expect(store.goAhead(server: "weather", tool: "add_alert", readOnly: false) == .ask)
        #expect(store.goAhead(server: "weather", tool: "get_forecast", readOnly: true) == .dontAsk)
    }

    @Test func anOverrideIsKeptAndSettingTheDefaultRemovesIt() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let store = MCPSettingsStore(file: folder.settings)
        try store.setGoAhead(.dontAsk, server: "weather", tool: "add_alert", readOnly: false)
        try store.setGoAhead(.ask, server: "weather", tool: "get_forecast", readOnly: true)
        let reread = MCPSettingsStore(file: folder.settings)
        #expect(reread.goAhead(server: "weather", tool: "add_alert", readOnly: false) == .dontAsk)
        #expect(reread.goAhead(server: "weather", tool: "get_forecast", readOnly: true) == .ask)
        let text = try String(contentsOf: folder.settings, encoding: .utf8)
        #expect(text.contains(#""add_alert" : "dont-ask""#))

        try store.setGoAhead(.ask, server: "weather", tool: "add_alert", readOnly: false)
        #expect(store.goAheadOverride(server: "weather", tool: "add_alert") == nil)
    }

    @Test func aBrokenFileReadsAsTheDefaults() throws {
        let folder = try Folder()
        defer { folder.remove() }
        try Data("{ nope".utf8).write(to: folder.settings)
        let store = MCPSettingsStore(file: folder.settings)
        #expect(store.isEnabled("weather"))
        try Data(#"{"disabled": ["notes"], "goAhead": 3}"#.utf8).write(to: folder.settings)
        #expect(!MCPSettingsStore(file: folder.settings).isEnabled("notes"))
    }
}

// MARK: - Naming

@Suite struct MCPToolNamingTests {
    @Test func aToolKeepsItsNameAfterTheServer() {
        let names = MCPToolNaming.names(server: "weather", tools: ["get_forecast", "add-alert"])
        #expect(names == ["get_forecast": "weather__get_forecast", "add-alert": "weather__add-alert"])
    }

    @Test func otherCharactersBecomeUnderscoresWithAHash() {
        let names = MCPToolNaming.names(server: "files", tools: ["read.file"])
        let name = try! #require(names["read.file"])
        #expect(name.hasPrefix("files__read_file_"))
        #expect(MCPToolNaming.isValidModelName(name))
    }

    @Test func aLongNameIsShortenedToTheLimit() {
        let long = String(repeating: "very_long_tool_name_", count: 6)
        let server = String(repeating: "s", count: 32)
        let names = MCPToolNaming.names(server: server, tools: [long, long + "2"])
        #expect(Set(names.values).count == 2)
        for name in names.values {
            #expect(name.count <= 64)
            #expect(name.hasPrefix(server + "__"))
            #expect(MCPToolNaming.isValidModelName(name))
        }
        // The same list gives the same names next launch.
        #expect(MCPToolNaming.names(server: server, tools: [long + "2", long]) == names)
    }

    @Test func aCollisionKeepsTheNameThatFitsAsItIs() {
        let names = MCPToolNaming.names(server: "notes", tools: ["make.note", "make_note"])
        #expect(names["make_note"] == "notes__make_note")
        #expect(names["make.note"] != "notes__make_note")
        #expect(names["make.note"]?.hasPrefix("notes__make_note_") == true)
    }
}

// MARK: - The cache and what joins at launch

@Suite struct MCPToolCacheTests {
    @Test func theCacheRoundTrips() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let cache = MCPToolCache(servers: ["weather": .init(tools: [forecast, addAlert], updated: Date(timeIntervalSince1970: 1_800_000_000))])
        try cache.write(to: folder.cache)
        #expect(MCPToolCache.read(from: folder.cache) == cache)
        try Data("garbage".utf8).write(to: folder.cache)
        #expect(MCPToolCache.read(from: folder.cache) == MCPToolCache())
    }

    @Test func onlyUsableServersThatAreOnAndCachedJoin() throws {
        let folder = try Folder()
        defer { folder.remove() }
        var config = config("weather", "notes", "fresh", "off")
        config.servers.append(MCPServerEntry(name: "bad name", command: "npx", problem: "bad"))
        let settings = MCPSettingsStore(file: folder.settings)
        try settings.setEnabled(false, server: "off")
        let cache = MCPToolCache(servers: [
            "weather": .init(tools: [forecast]), "notes": .init(tools: [addAlert]),
            "off": .init(tools: [forecast]), "bad name": .init(tools: [forecast]), "gone": .init(tools: [forecast]),
        ])
        #expect(Set(cache.launchLists(config: config, settings: settings).keys) == ["weather", "notes"])
    }

    @Test func aNewServerIsCachedAndJoinsAtTheNextLaunch() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = pool(config("weather"), folder: folder) { _ in StandInConnection(tools: [forecast, addAlert]) }
        #expect(pool.makeTools().isEmpty)
        _ = try await pool.connection(to: "weather")
        let status = try #require(await pool.statuses().first)
        #expect(status.state == .connected)
        #expect(status.nextLaunchNote == "Its tools join the tool list at the next launch.")
        #expect(MCPToolCache.read(from: folder.cache).servers["weather"]?.tools == [forecast, addAlert])

        // The next launch builds its list from the cache.
        let next = MCPServerPool(
            config: config("weather"), settings: MCPSettingsStore(file: folder.settings), cache: MCPToolCache.read(from: folder.cache),
            cacheFile: folder.cache, factory: { _ in StandInConnection(tools: [forecast, addAlert]) })
        #expect(next.makeTools().map(\.definition.name).sorted() == ["weather__add_alert", "weather__get_forecast"])
        _ = try await next.connection(to: "weather")
        #expect(await next.statuses().first?.nextLaunchNote == nil)
    }

    @Test func aChangedListIsCachedAndSaysSo() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let cache = MCPToolCache(servers: ["weather": .init(tools: [forecast])])
        let pool = pool(config("weather"), folder: folder, cache: cache) { _ in StandInConnection(tools: [forecast, addAlert]) }
        #expect(pool.makeTools().map(\.definition.name) == ["weather__get_forecast"])
        _ = try await pool.connection(to: "weather")
        #expect(await pool.statuses().first?.nextLaunchNote == "Its tools changed. The new list is used from the next launch.")
        #expect(MCPToolCache.read(from: folder.cache).servers["weather"]?.tools.count == 2)
    }

    @Test func turningAServerOffStopsItAndSaysItsToolsLeave() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let connection = StandInConnection(tools: [forecast])
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast])])) { _ in connection }
        _ = try await pool.connection(to: "weather")
        try await pool.setEnabled(false, server: "weather")
        #expect(connection.stops == 1)
        let status = try #require(await pool.statuses().first)
        #expect(status.state == .off)
        #expect(status.nextLaunchNote == "Its tools leave the tool list at the next launch.")
        await #expect(throws: MCPPoolError.off) { try await pool.connection(to: "weather") }
    }
}

// MARK: - The tool

@Suite struct MCPToolTests {
    @Test func aToolDescribesItselfAsTheServerGaveIt() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast])])) { _ in StandInConnection() }
        let tool = try #require(pool.makeTools().first)
        #expect(tool.definition.name == "weather__get_forecast")
        #expect(tool.definition.description == "The forecast for a city.")
        #expect(tool.definition.parameters == forecast.inputSchema)
        #expect(tool.definition.strict == false)
        #expect(tool.source == ToolSource(id: "mcp:weather", title: "weather"))
        #expect(tool.summary(arguments: ["city": "Lisbon", "days": 3]) == "get_forecast on weather: city Lisbon, days 3")
        #expect(tool.summary(arguments: [:]) == "get_forecast on weather")
    }

    @Test func aSchemaWithoutPropertiesGetsAnEmptyObject() {
        #expect(MCPTool.schema(["type": "object"]) == ["type": "object", "properties": [:]])
        #expect(MCPTool.schema(.null) == ["type": "object", "properties": [:]])
    }

    @Test func theRequestSendsMCPToolsWithoutStrictMode() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast])])) { _ in StandInConnection() }
        let registry = ToolRegistry(builtIn: [ShellCommandTool()], additional: pool.makeTools())
        let body = OpenAIResponses.body(
            for: ModelRequest(instructions: "", entries: [], tools: registry.definitions),
            model: "gpt-test", reasoningEffort: "low", promptCacheKey: "k")
        let tools = try #require(body["tools"]?.arrayValue)
        #expect(tools[0]["strict"] == true)
        #expect(tools[1]["name"] == "weather__get_forecast")
        #expect(tools[1]["strict"] == false)
    }

    @Test func goAheadDefaultsAndOverridesApplyToTheNextCall() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let connection = StandInConnection(tools: [forecast, addAlert])
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast, addAlert])])) { _ in connection }
        let tools = Dictionary(uniqueKeysWithValues: pool.makeTools().map { ($0.definition.name, $0) })
        let alert = try #require(tools["weather__add_alert"])
        let read = try #require(tools["weather__get_forecast"])
        #expect(alert.goAhead == .always)
        #expect(read.goAhead == .never)

        let asked = Asked()
        #expect(await read.run(arguments: ["city": "Lisbon"], context: context(approve: true, asked: asked)) == "done")
        #expect(asked.requests.isEmpty)

        #expect(await alert.run(arguments: ["city": "Lisbon"], context: context(approve: true, asked: asked)) == "done")
        let request = try #require(asked.requests.first)
        #expect(request.kind == .mcpToolCall)
        #expect(request.body == .toolCall(server: "weather", tool: "add_alert", arguments: JSONValue.object(["city": "Lisbon"]).prettyEncodedString()))
        #expect(request.question == "Call this tool?")
        #expect(request.approveTitle == "Call")
        #expect(request.waitingText == "waiting for your go-ahead to call add_alert")

        #expect(await alert.run(arguments: [:], context: context(approve: false)) == MCPTool.declinedOutput)
        #expect(connection.calls == ["get_forecast", "add_alert"])

        // An override in Settings applies to the next call without a relaunch.
        try pool.settings.setGoAhead(.dontAsk, server: "weather", tool: "add_alert", readOnly: false)
        #expect(alert.goAhead == .never)
        let askedAgain = Asked()
        #expect(await alert.run(arguments: [:], context: context(approve: false, asked: askedAgain)) == "done")
        #expect(askedAgain.requests.isEmpty)
        #expect(ToolSummary(alert).mcp == MCPToolReference(server: "weather", tool: "add_alert", readOnly: false))
    }

    @Test func aCallWaitsForAServerThatIsStarting() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let connection = StandInConnection(connectDelay: .milliseconds(300), tools: [forecast])
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast])])) { _ in connection }
        await pool.start()
        #expect(await pool.statuses().first?.state == .starting)
        let tool = try #require(pool.makeTools().first)
        #expect(await tool.run(arguments: ["city": "Lisbon"], context: context(approve: true)) == "done")
        #expect(connection.connects == 1)
    }

    @Test func aServerThatNeverConnectsIsAPlainSentence() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast])]), connectTimeout: .milliseconds(200)) { _ in
            StandInConnection(connectDelay: .seconds(30))
        }
        let tool = try #require(pool.makeTools().first)
        let output = await tool.run(arguments: [:], context: context(approve: true))
        #expect(output == "The MCP server weather is not available, so get_forecast did not run: The server did not answer within 0 seconds.")
        #expect(await pool.statuses().first?.state == .failed("The server did not answer within 0 seconds."))
    }

    @Test func aFailedServerIsTriedAgainAtTheNextCall() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let attempts = Mutex(0)
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast])])) { _ in
            let first = attempts.withLock { count in
                count += 1
                return count == 1
            }
            return first
                ? StandInConnection(connectError: MCPConnectionError.exited(status: 1, message: "PLACEHOLDER_TOKEN is not set"))
                : StandInConnection(tools: [forecast])
        }
        let tool = try #require(pool.makeTools().first)
        let failed = await tool.run(arguments: [:], context: context(approve: true))
        #expect(failed.hasSuffix("The server exited with status 1: PLACEHOLDER_TOKEN is not set"))
        #expect(await tool.run(arguments: [:], context: context(approve: true)) == "done")
    }

    @Test func aCallThatTakesTooLongIsStopped() async throws {
        struct Slow: MCPServerConnection {
            func connect() async throws {}
            func listTools() async throws -> [MCPToolInfo] { [forecast] }
            func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
                // Ignores cancellation, as a stuck server would.
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return MCPCallResult(content: [])
            }
            func stop() async {}
        }
        let folder = try Folder()
        defer { folder.remove() }
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast])]), callTimeout: .seconds(1)) { _ in Slow() }
        let tool = try #require(pool.makeTools().first)
        #expect(await tool.run(arguments: [:], context: context(approve: true)) == "The call to get_forecast on weather was stopped after the 1 second limit.")
    }

    @Test func toolsGroupByServerAfterTheBuiltIns() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = pool(config("weather", "notes"), folder: folder, cache: MCPToolCache(servers: [
            "weather": .init(tools: [forecast, addAlert]), "notes": .init(tools: [MCPToolInfo(name: "search", description: "", inputSchema: ["type": "object"])]),
        ])) { _ in StandInConnection() }
        let registry = ToolRegistry(builtIn: BuiltInTools.make(), additional: pool.makeTools())
        let groups = registry.groups
        // One group per server, after every group of built-in tools.
        #expect(groups.suffix(2).map(\.source.title) == ["notes", "weather"])
        #expect(groups.dropLast(2).allSatisfy { !$0.source.isMCPServer })
        #expect(groups.last?.tools.map(\.name) == ["weather__add_alert", "weather__get_forecast"])
        #expect(registry.definitions.suffix(3).map(\.name) == ["notes__search", "weather__add_alert", "weather__get_forecast"])
        #expect(registry.definitions.prefix(BuiltInTools.names.count).map(\.name) == BuiltInTools.names)
    }

    @Test func theIncognitoWindowHasNoMCPTools() {
        let tools = BuiltInTools.makeIncognito()
        #expect(tools.map(\.definition.name) == BuiltInTools.incognitoNames)
        #expect(tools.allSatisfy { !$0.source.isMCPServer && !($0 is MCPTool) && !$0.definition.name.contains(MCPToolNaming.separator) })
    }
}

// MARK: - Results

@Suite struct MCPToolResultTests {
    @Test func textIsJoined() {
        #expect(MCPToolResultText.text(for: MCPCallResult(content: [.text("one"), .text("two")])) == "one\ntwo")
        #expect(MCPToolResultText.text(for: MCPCallResult(content: [])) == "(no output)")
    }

    @Test func otherContentIsNamedAndLeftOut() {
        let result = MCPCallResult(content: [.text("Here it is."), .image(mimeType: "image/png"), .resourceLink(uri: "file:///tmp/report.pdf", name: "report")])
        #expect(MCPToolResultText.text(for: result)
            == "Here it is.\n[The result also had an image (image/png) and a link to file:///tmp/report.pdf, left out here since only text is passed on.]")
        #expect(MCPToolResultText.text(for: MCPCallResult(content: [.audio(mimeType: "audio/wav")]))
            == "[The result also had audio (audio/wav), left out here since only text is passed on.]")
    }

    @Test func anErrorReadsAsTheErrorText() {
        #expect(MCPToolResultText.text(for: MCPCallResult(content: [.text("City not found.")], isError: true)) == "Error: City not found.")
        #expect(MCPToolResultText.text(for: MCPCallResult(content: [], isError: true)) == "Error: the tool reported an error with no message.")
    }

    @Test func aLongResultIsCutAndSaysSo() {
        let text = MCPToolResultText.text(for: MCPCallResult(content: [.text(String(repeating: "a", count: 50))]), limit: 20)
        #expect(text == String(repeating: "a", count: 20) + "\n[Cut at 20 of 50 characters.]")
    }
}

// MARK: - Behind the experiment

@Suite struct MCPExperimentTests {
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func add() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    private func inactivePool(folder: Folder, connections: Counter, loads: Counter, tools: [MCPToolInfo] = [forecast]) -> MCPServerPool {
        let cacheFile = folder.cache
        return MCPServerPool(
            config: MCPServerConfig(fileExists: false), settings: MCPSettingsStore(file: folder.settings), cache: MCPToolCache(),
            cacheFile: cacheFile,
            loader: {
                loads.add()
                return (config("weather"), MCPToolCache.read(from: cacheFile))
            },
            factory: { _ in
                connections.add()
                return StandInConnection(tools: tools)
            })
    }

    @Test func itIsOffByDefault() throws {
        let suite = "mac-os-agent-mcp-experiment-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!Experiment.mcpServers.isOn(defaults))
        Experiment.mcpServers.set(true, defaults)
        #expect(Experiment.mcpServers.isOn(defaults))
        #expect(!Experiment.mcpServers.key.isEmpty)
    }

    @Test func offReadsNothingStartsNothingAndMakesNoTools() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        try MCPToolCache(servers: ["weather": .init(tools: [forecast])]).write(to: folder.cache)
        let connections = Counter()
        let loads = Counter()
        let pool = inactivePool(folder: folder, connections: connections, loads: loads)
        await pool.start()
        #expect(pool.makeTools().isEmpty)
        #expect(await pool.statuses().isEmpty)
        #expect(await !pool.isActive)
        await #expect(throws: MCPPoolError.experimentOff) { try await pool.connection(to: "weather") }
        #expect(connections.count == 0, "no connection factory is called")
        #expect(loads.count == 0, "no file is read")
        let builtIn = BuiltInTools.make()
        let registry = ToolRegistry(builtIn: builtIn, additional: pool.makeTools())
        #expect(registry.definitions == ToolRegistry(builtIn: builtIn).definitions)
    }

    @Test func turningItOnReadsTheFilesStartsTheServersAndFillsTheCache() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let connections = Counter()
        let loads = Counter()
        let pool = inactivePool(folder: folder, connections: connections, loads: loads, tools: [forecast, addAlert])
        await pool.setActive(true)
        #expect(loads.count == 1)
        _ = try await pool.connection(to: "weather")
        #expect(connections.count == 1)
        #expect(MCPToolCache.read(from: folder.cache).servers["weather"]?.tools == [forecast, addAlert])
        let status = try #require(await pool.statuses().first)
        #expect(status.state == .connected)
        #expect(status.nextLaunchNote == "Its tools join the tool list at the next launch.")
        // The tool list for this run does not change.
        #expect(pool.makeTools().isEmpty)
    }

    @Test func turningItOffStopsTheServersAndACallSaysSo() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let connection = StandInConnection(tools: [forecast])
        let pool = pool(config("weather"), folder: folder, cache: MCPToolCache(servers: ["weather": .init(tools: [forecast])])) { _ in connection }
        let tool = try #require(pool.makeTools().first)
        #expect(await tool.run(arguments: [:], context: context(approve: true)) == "done")
        await pool.setActive(false)
        #expect(connection.stops == 1)
        #expect(await pool.statuses().isEmpty)
        #expect(await tool.run(arguments: [:], context: context(approve: true))
            == "MCP servers are turned off in Settings, Experiments, so get_forecast on weather did not run.")
        #expect(connection.calls == ["get_forecast"])

        // On again starts it again.
        await pool.setActive(true)
        #expect(await tool.run(arguments: [:], context: context(approve: true)) == "done")
        #expect(connection.connects == 2)
    }
}
