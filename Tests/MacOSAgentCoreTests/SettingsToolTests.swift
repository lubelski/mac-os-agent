import Foundation
import Synchronization
import Testing
@testable import MacOSAgentCore

// MARK: - Stand-ins

/// A tool that records its arguments, asks for a go-ahead when told to, and returns its name.
private final class StandInGroupTool: AgentTool, @unchecked Sendable {
    let definition: ToolDefinition
    let asks: Bool
    private let received = Mutex<[JSONValue]>([])

    init(_ name: String, _ description: String, asks: Bool = false) {
        definition = ToolDefinition(name: name, description: description, parameters: ["type": "object", "properties": [:]])
        self.asks = asks
    }

    var calls: [JSONValue] { received.withLock { $0 } }

    func summary(arguments: JSONValue) -> String { "Stand-in \(definition.name) \(arguments["title"]?.stringValue ?? "")" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        received.withLock { $0.append(arguments) }
        if asks {
            let request = ConfirmationRequest(callID: context.callID, kind: .settingsChange, body: .setting(change: "Stand-in", notes: []), reason: "is a test")
            guard await context.confirm(request) else { return "Error: declined" }
        }
        return "ran \(definition.name)"
    }
}

private final class Asked: Sendable {
    private let list = Mutex<[ConfirmationRequest]>([])
    func append(_ request: ConfirmationRequest) { list.withLock { $0.append(request) } }
    var requests: [ConfirmationRequest] { list.withLock { $0 } }
}

private func context(approve: Bool = true, asked: Asked? = nil, callID: String = "call_1") -> ToolRunContext {
    ToolRunContext(callID: callID) { request in
        asked?.append(request)
        return approve
    }
}

/// A connection that starts no process and connects at once.
private struct StandInConnection: MCPServerConnection {
    var tools: [MCPToolInfo] = [MCPToolInfo(name: "get_forecast", description: "A forecast.", inputSchema: ["type": "object"], readOnly: true)]
    func connect() async throws {}
    func listTools() async throws -> [MCPToolInfo] { tools }
    func callTool(name: String, arguments: JSONValue) async throws -> MCPCallResult { MCPCallResult(content: [.text("done")]) }
    func stop() async {}
}

/// A temporary data folder and preferences suite, removed at the end of each test.
private final class Setup {
    let folder = FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-settings-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
    let suiteName = "mac-os-agent-settings-tools-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    var servers: URL { folder.appending(path: "mcp-servers.json") }
    var settings: URL { folder.appending(path: "mcp-settings.json") }

    func writeServers(_ text: String) throws {
        try Data(text.utf8).write(to: servers)
    }

    var serversText: String { (try? String(contentsOf: servers, encoding: .utf8)) ?? "" }

    /// A pool made from the servers file as it is now, as a launch makes it.
    func pool(active: Bool = true) -> MCPServerPool {
        let config = MCPServerConfig.read(from: servers)
        let loader: (@Sendable () -> (MCPServerConfig, MCPToolCache))? = active ? nil : { @Sendable in (config, MCPToolCache()) }
        let factory: MCPConnectionFactory = { _ in StandInConnection() }
        return MCPServerPool(
            config: config, settings: MCPSettingsStore(file: settings), cache: MCPToolCache(), cacheFile: nil,
            loader: loader, factory: factory)
    }

    func access(pool: MCPServerPool, toolsInThisRun: [String: Int] = [:], onAtLaunch: Set<Experiment> = []) -> AppSettingsAccess {
        AppSettingsAccess(serversFile: servers, mcp: pool, toolsInThisRun: toolsInThisRun, defaults: defaults, experimentsOnAtLaunch: onAtLaunch)
    }
}

/// A servers file with another key, a number written its own way, an env value that must never
/// show, a bridge, and a header token that must never show.
private let sampleServers = """
    {
      "comment": "kept by the owner",
      "mcpServers": {
        "weather": {"command": "npx", "args": ["-y", "weather-mcp"], "env": {"WEATHER_API_KEY": "secret-value-123"}, "timeout": 1.50},
        "tasks": {"command": "npx", "args": ["-y", "mcp-remote", "https://tasks.example.com/mcp", "--header", "Authorization: Bearer token-abc-999"]}
      }
    }
    """

// MARK: - find_tools and use_tool

@Suite struct FindAndUseToolTests {
    static let small = OnDemandToolGroup(name: "small", summary: "A few tools.", tools: [
        StandInGroupTool("read_notes", "Reads the notes. Returns every note."),
        StandInGroupTool("change_notes", "Changes a note.", asks: true),
    ])

    static let large = OnDemandToolGroup(name: "large", summary: "Many tools.", tools: [
        StandInGroupTool("list_comments", "Lists the comments on an issue. Takes the issue's id."),
        StandInGroupTool("get_issue", "Gets one issue by its id. Returns its title and status."),
        StandInGroupTool("list_issues", "Lists issues, filtered by assignee and status."),
        StandInGroupTool("save_comment", "Saves a comment on an issue."),
        StandInGroupTool("list_teams", "Lists the teams."),
    ])

    static let find = FindToolsTool(groups: [small, large])
    static let use = UseToolTool(groups: [small, large])

    @Test func aSmallGroupComesWholeWithFullDefinitions() async throws {
        let output = await Self.find.run(arguments: ["group": "small", "query": nil], context: context())
        let parsed = try #require(JSONValue.parse(output)?.arrayValue)
        #expect(parsed.compactMap { $0["name"]?.stringValue } == ["read_notes", "change_notes"])
        #expect(parsed.allSatisfy { $0["parameters"] != nil && $0["description"] != nil })
    }

    @Test func aLargeGroupWithNoQueryListsNamesAndFirstSentences() async {
        let output = await Self.find.run(arguments: ["group": "large", "query": nil], context: context())
        #expect(output.contains("get_issue: Gets one issue by its id."))
        #expect(!output.contains("Returns its title"))
        #expect(!output.contains("\"parameters\""))
    }

    @Test func anExactNameRanksFirstThenTheMostWordsMatched() async throws {
        let exact = await Self.find.run(arguments: ["group": "large", "query": "save_comment"], context: context())
        #expect(try #require(JSONValue.parse(exact)?.arrayValue).first?["name"]?.stringValue == "save_comment")
        // "issue" alone is in four descriptions. "get issue" is the name's two words.
        let words = await Self.find.run(arguments: ["group": "large", "query": "get issue"], context: context())
        let names = try #require(JSONValue.parse(words)?.arrayValue).compactMap { $0["name"]?.stringValue }
        #expect(names.first == "get_issue")
        #expect(!names.contains("list_teams"))
    }

    @Test func noMatchAndAnUnknownGroupSayWhatToDo() async {
        let none = await Self.find.run(arguments: ["group": "large", "query": "weather"], context: context())
        #expect(none.contains("null query"))
        let unknown = await Self.find.run(arguments: ["group": "linear", "query": nil], context: context())
        #expect(unknown.hasPrefix("Error:"))
        #expect(unknown.contains("small, large"))
    }

    @Test func useToolRunsTheToolWithItsOwnArguments() async throws {
        let tool = try #require(Self.small.tools[0] as? StandInGroupTool)
        let output = await Self.use.run(
            arguments: ["group": "small", "name": "read_notes", "arguments": ["title": "Groceries"]], context: context())
        #expect(output == "ran read_notes")
        #expect(tool.calls == [["title": "Groceries"]])
    }

    @Test func theGoAheadReachesTheOwnerOnTheUseToolCall() async {
        let asked = Asked()
        let approved = await Self.use.run(
            arguments: ["group": "small", "name": "change_notes", "arguments": [:]], context: context(asked: asked, callID: "call_use"))
        #expect(approved == "ran change_notes")
        #expect(asked.requests.map(\.callID) == ["call_use"])
        let declined = await Self.use.run(
            arguments: ["group": "small", "name": "change_notes", "arguments": [:]], context: context(approve: false))
        #expect(declined.hasPrefix("Error:"))
    }

    @Test func anUnknownGroupOrToolTellsTheModelToCallFindTools() async {
        let group = await Self.use.run(arguments: ["group": "nope", "name": "read_notes", "arguments": [:]], context: context())
        #expect(group.hasPrefix("Error:") && group.contains("find_tools"))
        let tool = await Self.use.run(arguments: ["group": "small", "name": "delete_notes", "arguments": [:]], context: context())
        #expect(tool.hasPrefix("Error:") && tool.contains("find_tools"))
    }

    @Test func useToolsRowReadsAsTheCallItMakes() {
        #expect(Self.use.summary(arguments: ["group": "small", "name": "read_notes", "arguments": ["title": "Groceries"]]) == "Stand-in read_notes Groceries")
        let summaries = ToolCallSummaries([Self.use])
        #expect(summaries.summary(name: "use_tool", arguments: #"{"group":"small","name":"read_notes","arguments":{"title":"Errands"}}"#) == "Stand-in read_notes Errands")
        // A row from a run without the experiment still reads as the settings call, and an
        // unknown group's as the tool and its group.
        #expect(ToolCallSummaries.builtIn.summary(name: "use_tool", arguments: #"{"group":"settings","name":"read_settings","arguments":{"area":"experiments"}}"#) == "Settings read experiments")
        #expect(ToolCallSummaries.builtIn.summary(name: "use_tool", arguments: #"{"group":"linear","name":"get_issue","arguments":{}}"#) == "get_issue in linear")
    }

    @Test func thePairGoesLastOfTheBuiltInToolsAndAScriptCanCallUseTool() {
        let off = BuiltInTools.make().map(\.definition.name)
        #expect(off == BuiltInTools.names(webSearch: false))
        #expect(!off.contains("find_tools"))
        let on = BuiltInTools.make(onDemandGroups: [Self.small]).map(\.definition.name)
        #expect(on == off + ["find_tools", "use_tool"])
        let mcpLike = StandInGroupTool("aaa__first", "An MCP tool.")
        let registry = ToolRegistry(builtIn: BuiltInTools.make(onDemandGroups: [Self.small]), additional: [mcpLike]).addingRunScript(true, helper: nil)
        #expect(Array(registry.definitions.map(\.name).suffix(4)) == ["find_tools", "use_tool", "aaa__first", "run_script"])
        let script = registry.tools.last as? RunScriptTool
        #expect(script?.tools.contains { $0.definition.name == "use_tool" } == true)
        #expect(registry.onDemandGroups.map(\.name) == ["small"])
    }

    @Test func settingsListsTheToolsInEachGroupUnderTheGroup() {
        let registry = ToolRegistry(builtIn: BuiltInTools.make(onDemandGroups: [Self.small]))
        let groups = registry.groups
        #expect(groups.first { $0.source == .onDemand }?.tools.map(\.name) == ["find_tools", "use_tool"])
        #expect(groups.last?.source.title == "Small Group")
        #expect(groups.last?.tools.map(\.name) == ["read_notes", "change_notes"])
    }
}

// MARK: - Instructions

@Suite struct SettingsToolsInstructionsTests {
    let folder = URL(filePath: "/tmp/skills")

    @Test func withTheExperimentOffTheInstructionsAreAsBefore() {
        let off = AgentInstructions.assemble(editable: "Be brief.", skills: [], skillsFolder: folder)
        #expect(off == AgentInstructions.assemble(editable: "Be brief.", skills: [], skillsFolder: folder, toolGroups: []))
        #expect(!off.contains("find_tools"))
        #expect(!off.contains("MOA"))
        #expect(AgentPrompt().toolGroups.isEmpty)
    }

    @Test func withItOnTheyNameTheAppAndListEachGroupInOneLine() {
        let on = AgentInstructions.assemble(editable: "Be brief.", skills: [], skillsFolder: folder, toolGroups: [SettingsToolGroup.listing])
        #expect(on.contains("This app is MacOS Agent, also called MOA or mac-os-agent."))
        #expect(on.contains("Call find_tools with a group's name"))
        #expect(on.contains("\n  - settings: MOA's own setup: its MCP servers"))
        // The skills list still ends the fixed part.
        #expect(on.hasSuffix("There are no skills yet."))
    }
}

// MARK: - read_settings

@Suite struct ReadSettingsToolTests {
    @Test func mcpServersAreReportedInLayersWithoutAnyEnvValue() async throws {
        let setup = try Setup()
        try setup.writeServers(sampleServers)
        Experiment.mcpServers.set(true, setup.defaults)
        let pool = setup.pool()
        try await pool.setEnabled(false, server: "tasks")
        _ = try await pool.connection(to: "weather")
        let tool = ReadSettingsTool(access: setup.access(pool: pool, toolsInThisRun: ["weather": 3], onAtLaunch: [.mcpServers]))

        let output = await tool.run(arguments: ["area": "mcp_servers"], context: context())
        #expect(!output.contains("secret-value-123"))
        #expect(!output.contains("token-abc-999"))
        let result = try #require(JSONValue.parse(output))
        let servers = try #require(result["servers"]?.arrayValue)
        let weather = try #require(servers.first { $0["name"]?.stringValue == "weather" })
        #expect(weather["saved"] == true)
        #expect(weather["on"] == true)
        #expect(weather["loaded_in_this_run"] == true)
        #expect(weather["tools_in_this_run"] == 3)
        #expect(weather["status"] == "connected")
        #expect(weather["env_names"] == ["WEATHER_API_KEY"])
        #expect(weather["bridge"] == nil)
        let tasks = try #require(servers.first { $0["name"]?.stringValue == "tasks" })
        #expect(tasks["on"] == false)
        #expect(tasks["status"] == "off")
        #expect(tasks["loaded_in_this_run"] == false)
        #expect(tasks["bridge"]?["remote_url"] == "https://tasks.example.com/mcp")
        #expect(tasks["bridge"]?["through"] == "run with npx")
        #expect(tasks["command"]?.stringValue?.contains("Authorization: (hidden)") == true)
        #expect(result["mcp_servers_experiment"]?["on"] == true)
        #expect(result["change_settings_accepts"]?.arrayValue?.count == 4)
        #expect(result["takes_effect"]?.stringValue?.contains("next launch") == true)
        #expect(result["change_rules"]?.encodedString().contains("mcp-remote") == true)
    }

    @Test func aServerAddedAfterLaunchOrWithTheExperimentOffSaysWhyItIsNotStarted() async throws {
        let setup = try Setup()
        try setup.writeServers(#"{"mcpServers": {}}"#)
        let pool = setup.pool()
        try setup.writeServers(#"{"mcpServers": {"notes": {"command": "/usr/bin/true"}}}"#)
        let tool = ReadSettingsTool(access: setup.access(pool: pool))
        let added = try #require(JSONValue.parse(await tool.run(arguments: ["area": "mcp_servers"], context: context())))
        #expect(added["servers"]?.arrayValue?.first?["status"]?.stringValue?.contains("added after launch") == true)

        let inactive = ReadSettingsTool(access: setup.access(pool: setup.pool(active: false)))
        let off = try #require(JSONValue.parse(await inactive.run(arguments: ["area": "mcp_servers"], context: context())))
        #expect(off["servers"]?.arrayValue?.first?["status"]?.stringValue?.contains("experiment is off") == true)
        #expect(off["mcp_servers_experiment"]?["on"] == false)
    }

    @Test func experimentsListEveryKeyWithItsSwitchAndWhenAChangeTakesEffect() async throws {
        let setup = try Setup()
        Experiment.scripts.set(true, setup.defaults)
        let tool = ReadSettingsTool(access: setup.access(pool: .empty, onAtLaunch: [.settingsTools]))
        let result = try #require(JSONValue.parse(await tool.run(arguments: ["area": "experiments"], context: context())))
        let experiments = try #require(result["experiments"]?.arrayValue)
        #expect(experiments.compactMap { $0["key"]?.stringValue } == Experiment.allCases.map(\.rawValue))
        let scripts = try #require(experiments.first { $0["key"] == "scripts" })
        #expect(scripts["on"] == true)
        #expect(scripts["on_at_launch"] == false)
        #expect(scripts["takes_effect"]?.stringValue?.contains("next launch") == true)
        let queue = try #require(experiments.first { $0["key"] == "queueMessagesWhileRunning" })
        #expect(queue["takes_effect"] == "Now.")
        #expect(queue["on_at_launch"] == nil)
        #expect(experiments.first { $0["key"] == "settingsTools" }?["on_at_launch"] == true)
    }

    @Test func anUnknownAreaIsAnError() async throws {
        let setup = try Setup()
        let output = await ReadSettingsTool(access: setup.access(pool: .empty)).run(arguments: ["area": "themes"], context: context())
        #expect(output.hasPrefix("Error:") && output.contains("mcp_servers, experiments"))
    }

    @Test func bridgesAreFoundWithNpxOrMcpRemoteItself() {
        let npx = MCPServerEntry(name: "figma", command: "npx", args: ["-y", "mcp-remote@0.1.2", "https://mcp.figma.com/mcp"])
        #expect(MCPRemoteBridge(npx)?.cardSentence(server: "figma") == "figma is a remote server. MOA will reach it through mcp-remote, run with npx.")
        let direct = MCPServerEntry(name: "figma", command: "/opt/homebrew/bin/mcp-remote", args: ["https://mcp.figma.com/mcp"])
        #expect(MCPRemoteBridge(direct)?.runner == "mcp-remote")
        #expect(MCPRemoteBridge(MCPServerEntry(name: "weather", command: "npx", args: ["-y", "weather-mcp"])) == nil)
        #expect(MCPCommandDisplay.hidingSecrets(inURL: "https://example.com/sse?api_key=abc&team=one") == "https://example.com/sse?api_key=(hidden)&team=one")
    }
}

// MARK: - change_settings

@Suite struct ChangeSettingsToolTests {
    static func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    @Test func addingAServerKeepsEverythingElseAndTheFilePrivate() async throws {
        let setup = try Setup()
        try setup.writeServers(sampleServers)
        let asked = Asked()
        let tool = ChangeSettingsTool(access: setup.access(pool: setup.pool()))
        let output = await tool.run(arguments: ["area": "mcp_servers", "change": ["add": [
            "name": "notes", "command": "npx", "args": ["-y", "notes-mcp"], "env_names": ["NOTES_TOKEN"],
        ]]], context: context(asked: asked))

        #expect(output.contains("Added the MCP server notes"))
        #expect(output.contains("next launch"))
        #expect(output.contains("fills in the values of NOTES_TOKEN"))
        #expect(Self.mode(setup.servers) == 0o600)
        let text = setup.serversText
        #expect(text.contains("\"comment\": \"kept by the owner\""))
        #expect(text.contains("\"secret-value-123\""))
        #expect(text.contains("1.50"))
        let config = MCPServerConfig.read(from: setup.servers)
        #expect(config.servers.map(\.name) == ["notes", "tasks", "weather"])
        #expect(config.servers.first { $0.name == "notes" }?.env == ["NOTES_TOKEN": ""])
        #expect(config.servers.first { $0.name == "tasks" }?.args.last == "Authorization: Bearer token-abc-999")

        let request = try #require(asked.requests.first)
        #expect(request.kind == .settingsChange)
        #expect(request.text.contains("Add the MCP server notes"))
        #expect(request.text.contains("Command: npx -y notes-mcp"))
        #expect(request.text.contains("NOTES_TOKEN"))
    }

    @Test func addingABridgeSaysSoOnTheCardAndInTheResult() async throws {
        let setup = try Setup()
        let asked = Asked()
        let tool = ChangeSettingsTool(access: setup.access(pool: setup.pool()))
        let output = await tool.run(arguments: ["area": "mcp_servers", "change": ["add": [
            "name": "figma", "command": "npx", "args": ["-y", "mcp-remote", "https://mcp.figma.com/mcp"],
        ]]], context: context(asked: asked))
        #expect(asked.requests.first?.text.contains("figma is a remote server. MOA will reach it through mcp-remote, run with npx.") == true)
        #expect(output.contains("It is a bridge"))
        #expect(output.contains("sign-in"))
        #expect(output.contains("MCP servers experiment is off"))
        #expect(MCPServerConfig.read(from: setup.servers).servers.map(\.name) == ["figma"])
        #expect(Self.mode(setup.servers) == 0o600)
    }

    @Test func aTakenNameABadNameEnvValuesAndAURLAreRefusedWithoutAsking() async throws {
        let setup = try Setup()
        try setup.writeServers(sampleServers)
        let before = setup.serversText
        let asked = Asked()
        let tool = ChangeSettingsTool(access: setup.access(pool: setup.pool()))
        let changes: [JSONValue] = [
            ["add": ["name": "weather", "command": "npx", "args": []]],
            ["add": ["name": "two__underscores", "command": "npx"]],
            ["add": ["name": "notes", "command": "npx", "env": ["NOTES_TOKEN": "abc"]]],
            ["add": ["name": "figma", "url": "https://mcp.figma.com/mcp"]],
            ["add": ["name": "figma", "command": "https://mcp.figma.com/mcp"]],
            ["add": ["name": "notes", "command": "npx", "env_names": ["1BAD"]]],
            ["add": ["name": "notes", "command": "npx"], "remove": "weather"],
        ]
        for change in changes {
            let output = await tool.run(arguments: ["area": "mcp_servers", "change": change], context: context(asked: asked))
            #expect(output.hasPrefix("Error:"), "\(change.encodedString()) gave \(output)")
        }
        let taken = await tool.run(arguments: ["area": "mcp_servers", "change": changes[0]], context: context())
        #expect(taken.contains("already an MCP server named \"weather\""))
        let url = await tool.run(arguments: ["area": "mcp_servers", "change": changes[3]], context: context())
        #expect(url.contains("mcp-remote"))
        #expect(asked.requests.isEmpty)
        #expect(setup.serversText == before)
    }

    @Test func aDeclinedChangeChangesNothing() async throws {
        let setup = try Setup()
        try setup.writeServers(sampleServers)
        let before = setup.serversText
        let pool = setup.pool()
        let tool = ChangeSettingsTool(access: setup.access(pool: pool))
        for change: JSONValue in [["add": ["name": "notes", "command": "npx"]], ["remove": "weather"], ["turn_off": "weather"]] {
            let output = await tool.run(arguments: ["area": "mcp_servers", "change": change], context: context(approve: false))
            #expect(output == ChangeSettingsTool.declinedOutput)
        }
        #expect(setup.serversText == before)
        #expect(pool.settings.isEnabled("weather"))
        let experiment = await tool.run(arguments: ["area": "experiments", "change": ["experiment": "scripts", "on": true]], context: context(approve: false))
        #expect(experiment == ChangeSettingsTool.declinedOutput)
        #expect(!Experiment.scripts.isOn(setup.defaults))
    }

    @Test func removingAServerKeepsTheOthers() async throws {
        let setup = try Setup()
        try setup.writeServers(sampleServers)
        let tool = ChangeSettingsTool(access: setup.access(pool: setup.pool()))
        let output = await tool.run(arguments: ["area": "mcp_servers", "change": ["remove": "tasks"]], context: context())
        #expect(output.contains("Removed the MCP server tasks"))
        #expect(MCPServerConfig.read(from: setup.servers).servers.map(\.name) == ["weather"])
        #expect(setup.serversText.contains("kept by the owner"))
        #expect(Self.mode(setup.servers) == 0o600)
        let missing = await tool.run(arguments: ["area": "mcp_servers", "change": ["remove": "tasks"]], context: context())
        #expect(missing.hasPrefix("Error:") && missing.contains("weather"))
    }

    @Test func turningAServerOffAndOnGoesToTheMCPSettings() async throws {
        let setup = try Setup()
        try setup.writeServers(sampleServers)
        let pool = setup.pool()
        let asked = Asked()
        let tool = ChangeSettingsTool(access: setup.access(pool: pool))
        let off = await tool.run(arguments: ["area": "mcp_servers", "change": ["turn_off": "weather"]], context: context(asked: asked))
        #expect(off.contains("Turned off the MCP server weather"))
        #expect(!pool.settings.isEnabled("weather"))
        #expect(!MCPSettingsStore(file: setup.settings).isEnabled("weather"))
        let again = await tool.run(arguments: ["area": "mcp_servers", "change": ["turn_off": "weather"]], context: context(asked: asked))
        #expect(again.contains("already off"))
        #expect(asked.requests.count == 1)
        _ = await tool.run(arguments: ["area": "mcp_servers", "change": ["turn_on": "weather"]], context: context())
        #expect(pool.settings.isEnabled("weather"))
        let unknown = await tool.run(arguments: ["area": "mcp_servers", "change": ["turn_on": "nope"]], context: context())
        #expect(unknown.hasPrefix("Error:"))
    }

    @Test func anExperimentIsTurnedOnAndOffByItsKey() async throws {
        let setup = try Setup()
        let asked = Asked()
        let tool = ChangeSettingsTool(access: setup.access(pool: .empty))
        let on = await tool.run(arguments: ["area": "experiments", "change": ["experiment": "scripts", "on": true]], context: context(asked: asked))
        #expect(Experiment.scripts.isOn(setup.defaults))
        #expect(on.contains("next launch"))
        #expect(asked.requests.first?.text.contains("Turn on the experiment “Scripts that call tools”") == true)
        let off = await tool.run(arguments: ["area": "experiments", "change": ["experiment": "scripts", "on": false]], context: context())
        #expect(off.contains("Turned off"))
        #expect(!Experiment.scripts.isOn(setup.defaults))
        let unknown = await tool.run(arguments: ["area": "experiments", "change": ["experiment": "darkMode", "on": true]], context: context())
        #expect(unknown.hasPrefix("Error:") && unknown.contains("queueMessagesWhileRunning") && unknown.contains("settingsTools"))
    }

    @Test func throughUseToolTheCardIsOnTheUseToolRowAndItsRowReadsAsTheChange() async throws {
        let setup = try Setup()
        let group = SettingsToolGroup.make(access: setup.access(pool: .empty))
        let use = UseToolTool(groups: [group])
        let arguments: JSONValue = ["group": "settings", "name": "change_settings", "arguments": ["area": "experiments", "change": ["experiment": "scripts", "on": true]]]
        #expect(use.summary(arguments: arguments) == "Settings turn on the experiment Scripts that call tools")
        let asked = Asked()
        _ = await use.run(arguments: arguments, context: context(asked: asked, callID: "call_use"))
        #expect(asked.requests.map(\.callID) == ["call_use"])
        #expect(Experiment.scripts.isOn(setup.defaults))
        #expect(ChangeSettingsTool(access: setup.access(pool: .empty)).goAhead == .always)
    }
}
