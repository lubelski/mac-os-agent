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

    /// Apple's title style, the repo's convention: articles, coordinating conjunctions, and
    /// prepositions of four letters or fewer are lower case, except as the first or last word.
    @Test(arguments: [
        // The last word is always capitalized.
        ("log_in", "Log In"),
        ("sign_up", "Sign Up"),
        ("check_out", "Check Out"),
        ("opt_out_of", "Opt out Of"),
        ("what_to_search_for", "What to Search For"),
        // The first word is too.
        ("the_list", "The List"),
        ("for_each_item", "For Each Item"),
        // Each minor word, inside a name.
        ("pick_a_file", "Pick a File"),
        ("pick_an_item", "Pick an Item"),
        ("read_the_news", "Read the News"),
        ("salt_and_pepper", "Salt and Pepper"),
        ("now_but_later", "Now but Later"),
        ("wait_for_reply", "Wait for Reply"),
        ("neither_nor_both", "Neither nor Both"),
        ("this_or_that", "This or That"),
        ("now_so_later", "Now so Later"),
        ("not_yet_done", "Not yet Done"),
        ("meet_at_noon", "Meet at Noon"),
        ("sort_by_date", "Sort by Date"),
        ("copy_from_clipboard", "Copy from Clipboard"),
        ("files_in_folder", "Files in Folder"),
        ("move_into_folder", "Move into Folder"),
        ("list_of_issues", "List of Issues"),
        ("turn_off_alarm", "Turn off Alarm"),
        ("get_on_board", "Get on Board"),
        ("move_onto_stack", "Move onto Stack"),
        ("sign_out_user", "Sign out User"),
        ("hand_over_task", "Hand over Task"),
        ("add_to_list", "Add to List"),
        ("set_up_account", "Set up Account"),
        ("reply_with_quote", "Reply with Quote"),
        // Words outside the list are capitalized, including "as" and longer prepositions.
        ("save_as_draft", "Save As Draft"),
        ("search_within_results", "Search Within Results"),
        ("sort_about_dates", "Sort About Dates"),
        ("send_email_after_meeting", "Send Email After Meeting"),
        // Short forms and capitals keep their place in the rule.
        ("get_id_of_url", "Get ID of URL"),
        ("addToList", "Add to List"),
    ])
    func followsTitleStyle(_ name: String, _ expected: String) {
        #expect(HumanizedName.from(name) == expected)
    }

    @Test func theMinorWordsAreExactlyTheConventionsList() {
        #expect(HumanizedName.minorWords == [
            "a", "an", "the",
            "and", "but", "for", "nor", "or", "so", "yet",
            "at", "by", "from", "in", "into", "of", "off", "on", "onto", "out", "over", "to", "up", "with",
        ])
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

    @Test func aServerRowsThirdLineIsItsDescriptionOrAPlaceholder() {
        let described = MCPServerRowDescription(MCPServerSummary(text: "Forecasts for my trips.", source: .file))
        #expect(described.text == "Forecasts for my trips.")
        #expect(!described.isPlaceholder)
        let plain = MCPServerRowDescription(nil)
        #expect(plain == .placeholder)
        #expect(plain.text == "No description")
        #expect(plain.isPlaceholder)
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
        // A call to the tool already in the thread, which every later request replays.
        let replayed = [
            ThreadEntry(date: Date(timeIntervalSince1970: 0), item: .userMessage(text: "weather in lisbon")),
            ThreadEntry(date: Date(timeIntervalSince1970: 1), item: .toolCall(.init(
                callID: "call_1", name: "weather__get_forecast", arguments: #"{"city":"Lisbon"}"#, provider: "openai", model: "gpt-test"))),
            ThreadEntry(date: Date(timeIntervalSince1970: 2), item: .toolResult(.init(callID: "call_1", output: "Rain."))),
        ]
        func body() throws -> Data {
            let registry = ToolRegistry(builtIn: [ShellCommandTool()], additional: pool.makeTools())
            let body = OpenAIResponses.body(
                for: ModelRequest(instructions: "", entries: replayed, tools: registry.definitions),
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

/// A call's row reads by display names, resolved from the literal names the thread keeps each
/// time the row is built, so a rename reaches rows drawn before it, in the panel and in History.
@Suite struct MCPCallRowsReadByDisplayNamesTests {
    private func weatherPool(_ folder: Folder) -> MCPServerPool {
        MCPServerPool(
            config: MCPServerConfig(servers: [MCPServerEntry(name: "weather", command: "/usr/bin/true")]),
            settings: MCPSettingsStore(file: folder.settings), cache: MCPToolCache(servers: ["weather": .init(tools: [forecast, addAlert])]),
            cacheFile: nil, factory: { _ in DescribedConnection(tools: [forecast, addAlert], serverInfo: nil) })
    }

    private func call(_ name: String, _ arguments: String = #"{"city":"Lisbon"}"#, id: String = "call_1") -> ThreadItem.ToolCall {
        ThreadItem.ToolCall(callID: id, name: name, arguments: arguments, provider: "openai", model: "gpt-test")
    }

    private func thread(_ calls: [ThreadItem.ToolCall]) -> [ThreadEntry] {
        var entries = [ThreadEntry(date: Date(timeIntervalSince1970: 0), item: .userMessage(text: "weather in lisbon"))]
        for (index, call) in calls.enumerated() {
            entries.append(ThreadEntry(date: Date(timeIntervalSince1970: Double(2 * index + 1)), item: .toolCall(call)))
            entries.append(ThreadEntry(date: Date(timeIntervalSince1970: Double(2 * index + 2)), item: .toolResult(.init(callID: call.callID, output: "Rain."))))
        }
        return entries
    }

    private func commands(_ transcript: Transcript) -> [String] {
        transcript.rows.compactMap { row in
            if case .tool(let command, _, _) = row.kind { command } else { nil }
        }
    }

    @Test func aListedToolReadsByTheOwnersNamesOrTheDefaults() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = weatherPool(folder)
        let summaries = ToolCallSummaries(pool.makeTools(), showsDisplayNames: true)
        #expect(summaries.summary(of: call("weather__get_forecast")) == "Get Forecast on Weather: city Lisbon")
        try pool.settings.setServerDisplayName("Forecasts", server: "weather")
        try pool.settings.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        #expect(summaries.summary(of: call("weather__get_forecast")) == "Five Days on Forecasts: city Lisbon")
        #expect(summaries.summary(of: call("weather__add_alert", "{}")) == "Add Alert on Forecasts")
        // Without display names, as before, and as anything but a person's rows reads it.
        let literal = ToolCallSummaries(pool.makeTools())
        #expect(literal.summary(of: call("weather__get_forecast")) == "get_forecast on weather: city Lisbon")
        #expect(literal.displaySummary(of: call("weather__get_forecast")) == nil)
    }

    @Test func aToolNoLongerListedReadsByItsLiteralNamesMadeReadable() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = weatherPool(folder)
        // An override set before the server went is not used: the row falls back to the default.
        try pool.settings.setServerDisplayName("Old Notes", server: "notes")
        let summaries = ToolCallSummaries([ShellCommandTool()] + pool.makeTools(), showsDisplayNames: true)
        #expect(summaries.summary(of: call("notes__search_notes", #"{"query":"trip"}"#)) == "Search Notes on Notes: query trip")
        #expect(summaries.summary(of: call("calendar-sync__sync_now", "not json")) == "Sync Now on Calendar Sync")
        // A built-in tool, and an unknown one with no server in its name, read as they did.
        #expect(summaries.summary(of: call(ShellCommandTool.name, #"{"command":"ls","destructive":false}"#)) == "Bash ls")
        #expect(summaries.summary(of: call("gone_tool")) == "gone_tool")
        #expect(ToolCallSummaries.builtIn.summary(of: call("notes__search_notes")) == "notes__search_notes")
    }

    @Test func aRenameReachesRowsDrawnBeforeIt() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = weatherPool(folder)
        let entries = thread([call("weather__get_forecast")])
        let summaries = ToolCallSummaries(pool.makeTools(), showsDisplayNames: true)
        #expect(commands(Transcript(entries: entries, summaries: summaries)) == ["Get Forecast on Weather: city Lisbon"])
        try pool.settings.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        // The thread is the same. Drawing it again reads the new name.
        #expect(commands(Transcript(entries: entries, summaries: summaries)) == ["Five Days on Weather: city Lisbon"])
        // The thread still holds the literal name.
        guard case .toolCall(let stored) = entries[1].item else { Issue.record("not a call"); return }
        #expect(stored.name == "weather__get_forecast")
    }

    @Test func aRunningCallKeepsItsDisplayNames() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = weatherPool(folder)
        try pool.settings.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        let tools = pool.makeTools()
        var transcript = Transcript(summaries: ToolCallSummaries(tools, showsDisplayNames: true))
        let made = call("weather__get_forecast")
        transcript.apply(ThreadEntry(item: .toolCall(made)))
        // The loop reports the literal summary, which the row does not take.
        let literal = try #require(tools.first { $0.definition.name == made.name }).summary(arguments: ["city": "Lisbon"])
        transcript.toolRunning(made.callID, command: literal)
        #expect(commands(transcript) == ["Five Days on Weather: city Lisbon"])
        // Without display names the row takes it, as before.
        var plain = Transcript(summaries: ToolCallSummaries(tools))
        plain.apply(ThreadEntry(item: .toolCall(made)))
        plain.toolRunning(made.callID, command: literal)
        #expect(commands(plain) == ["get_forecast on weather: city Lisbon"])
    }

    @Test func historyReadsByDisplayNamesAndIsSearchedByLiteralOnes() throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = weatherPool(folder)
        try pool.settings.setToolDisplayName("Five Days", server: "weather", tool: "get_forecast")
        let entries = thread([call("weather__get_forecast")])
        let contents = ThreadContents(entries: entries)
        let episode = try #require(contents.episodes.first)
        let summaries = ToolCallSummaries(pool.makeTools(), showsDisplayNames: true)
        #expect(EpisodeLine.lines(of: episode, in: contents, summaries: summaries).map(\.text).contains("Five Days on Weather: city Lisbon"))
        let panes = HistoryPanes(contents: contents, items: EpisodeListItem.all(in: contents), summaries: summaries)
        #expect(panes.call("call_1", in: episode)?.summary == "Five Days on Weather: city Lisbon")
        // Search reads the literal call, so the tool's name on its server finds it, and a display
        // name finds it only where its words are in the literal one.
        #expect(HistorySearchText.scan(entries, for: "get_forecast", limit: 5, excluding: nil) == [1])
        #expect(HistorySearchText.scan(entries, for: "weather__get_forecast", limit: 5, excluding: nil) == [1])
        #expect(HistorySearchText.scan(entries, for: "five days", limit: 5, excluding: nil).isEmpty)
        // What search_history and read_episode give the model is literal.
        let line = HistoryText(timeZone: .gmt).line(entries[1], limit: 280)
        #expect(line.contains("weather__get_forecast"))
        #expect(!line.contains("Five Days"))
    }

    @Test func theGoAheadCardNamesTheToolForAPersonAndKeepsTheLiteralCall() async throws {
        let folder = try Folder()
        defer { folder.remove() }
        let pool = weatherPool(folder)
        try pool.settings.setServerDisplayName("Forecasts", server: "weather")
        try pool.settings.setToolDisplayName("Warn Me", server: "weather", tool: "add_alert")
        let alert = try #require(pool.makeTools().first { $0.definition.name == "weather__add_alert" })
        let asked = Mutex<[ConfirmationRequest]>([])
        _ = await alert.run(arguments: ["city": "Lisbon"], context: ToolRunContext(callID: "call_1") { request in
            asked.withLock { $0.append(request) }
            return false
        })
        let request = try #require(asked.withLock { $0.first })
        #expect(request.body == .toolCall(server: "weather", tool: "add_alert", arguments: JSONValue.object(["city": "Lisbon"]).prettyEncodedString()))
        #expect(request.displayNames == ConfirmationRequest.DisplayNames(server: "Forecasts", tool: "Warn Me"))
        #expect(request.toolCallDisplayNames(server: "weather", tool: "add_alert").tool == "Warn Me")
        #expect(request.waitingText == "waiting for your go-ahead to call Warn Me")
        // A request with no names, such as one a test makes, reads by the literal names made readable.
        let plain = ConfirmationRequest(
            callID: "call_2", kind: .mcpToolCall, body: .toolCall(server: "calendar-sync", tool: "sync_now", arguments: "{}"), reason: "asks")
        #expect(plain.toolCallDisplayNames(server: "calendar-sync", tool: "sync_now") == .init(server: "Calendar Sync", tool: "Sync Now"))
        #expect(plain.waitingText == "waiting for your go-ahead to call Sync Now")
    }
}
