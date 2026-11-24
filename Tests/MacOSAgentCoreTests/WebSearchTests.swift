import Foundation
import Testing
@testable import MacOSAgentCore

private let utc = TimeZone(identifier: "UTC")!

private func folder() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-web-search-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func body(_ request: ModelRequest) -> JSONValue {
    OpenAIResponses.body(for: request, model: "gpt-6-luna", reasoningEffort: "low", promptCacheKey: "k", timeZone: utc)
}

private func webSearchItem(_ id: String, status: String = "completed", action: JSONValue? = nil) -> JSONValue {
    var item: [String: JSONValue] = ["type": "web_search_call", "id": .string(id), "status": .string(status)]
    if let action { item["action"] = action }
    return .object(item)
}

// MARK: - The setting

@Suite struct WebSearchSettingTests {
    @Test func itIsOffUntilSetAndKeepsWhatIsSet() throws {
        let defaults = try #require(UserDefaults(suiteName: "web-search-\(UUID().uuidString)"))
        #expect(WebSearchSetting.current(defaults) == .off)
        WebSearchSetting.set(.brave, defaults)
        #expect(WebSearchSetting.current(defaults) == .brave)
        #expect(defaults.string(forKey: "webSearch") == "brave")
        WebSearchSetting.set(.openAI, defaults)
        #expect(WebSearchSetting.current(defaults) == .openAI)
        defaults.set("something-else", forKey: WebSearchSetting.key)
        #expect(WebSearchSetting.current(defaults) == .off)
    }

    @Test func onlyOpenAIUsesTheHostedSearch() {
        #expect(!WebSearchSetting.off.usesHostedSearch)
        #expect(WebSearchSetting.openAI.usesHostedSearch)
        #expect(!WebSearchSetting.brave.usesHostedSearch)
    }

    @Test func theStatusSaysWhetherAKeyIsSetAndWhatTheNextLaunchUses() {
        #expect(WebSearchStatus(launched: .off, stored: .off, braveKeySet: false).text == "off")
        #expect(WebSearchStatus(launched: .openAI, stored: .openAI, braveKeySet: true).text == "OpenAI")
        #expect(WebSearchStatus(launched: .brave, stored: .brave, braveKeySet: true).text == "Brave, key set")
        #expect(WebSearchStatus(launched: .brave, stored: .brave, braveKeySet: false).text == "Brave, key not set")
        #expect(WebSearchStatus(launched: .off, stored: .openAI, braveKeySet: false).text == "off, OpenAI from the next launch")
    }

    @Test func diagnosticsNeverHoldTheKey() throws {
        let root = folder()
        let secrets = MemorySecrets()
        let key = BraveSearchKey(secrets: secrets)
        try key.save("BSA-very-secret-key-123")
        let report = DiagnosticsReport(
            build: BuildInfo(version: "0.1", build: "1", commit: "abc", signing: "Signed"),
            dataFolder: root, model: "gpt-6-luna", signIn: nil, instructions: "", tools: [], skills: [],
            threadFile: root.appending(path: "thread.jsonl"), usageLog: UsageLog(fileURL: root.appending(path: "usage.jsonl")),
            problems: [],
            webSearch: WebSearchStatus(launched: .brave, stored: .brave, braveKeySet: key.isSet))
        let text = report.plainText()
        #expect(text.contains("- Web search: Brave, key set"))
        #expect(!text.contains("BSA-very-secret-key-123"))
        #expect(!"\(report)".contains("BSA-very-secret-key-123"))
    }
}

// MARK: - Off is as before

@Suite struct WebSearchOffTests {
    private let tools = [ShellCommandTool().definition]

    @Test func withSearchOffTheRequestIsByteForByteAsBefore() {
        let entries = [ThreadEntry(date: Date(timeIntervalSince1970: 1_795_000_000), item: .userMessage(text: "hi"))]
        let before = ModelRequest(instructions: "Be brief.", entries: entries, tools: tools)
        let off = ModelRequest(instructions: "Be brief.", entries: entries, tools: tools, webSearch: false)
        #expect(!before.webSearch)
        #expect(body(off).encodedString() == body(before).encodedString())
        let sent = body(off)["tools"]?.arrayValue ?? []
        #expect(sent.count == 1)
        #expect(!body(off).encodedString().contains("web_search"))
        // A request with no tools and no search still has no tools key.
        #expect(body(ModelRequest(instructions: "x", entries: entries, tools: [], webSearch: false))["tools"] == nil)
    }

    @Test func withSearchOffTheFingerprintIsAsBefore() {
        #expect(PromptFingerprint.make(instructions: "Be brief.", tools: tools)
                == PromptFingerprint.make(instructions: "Be brief.", tools: tools, webSearch: false))
        #expect(PromptFingerprint.make(instructions: "Be brief.", tools: tools)
                != PromptFingerprint.make(instructions: "Be brief.", tools: tools, webSearch: true))
    }

    @Test func withSearchOffTheBuiltInListIsAsBefore() {
        let names = BuiltInTools.make().map(\.definition.name)
        #expect(names == BuiltInTools.names)
        #expect(!names.contains(SearchWebTool.name))
        #expect(BuiltInTools.names(webSearch: false) == BuiltInTools.names)
    }

    @Test func aLoopWithoutSearchSendsNone() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [[.item(assistant("hi"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [RecordingTool()], instructions: "x")
        try await loop.run("hello", onEvent: { _ in }, confirm: { _ in true })
        #expect(provider.requests.map(\.webSearch) == [false])
    }
}

// MARK: - OpenAI's hosted search

@Suite struct HostedWebSearchTests {
    private let tools = [ShellCommandTool().definition]

    @Test func theHostedToolGoesLastAfterTheFunctionTools() {
        let entries = [ThreadEntry(date: Date(timeIntervalSince1970: 1_795_000_000), item: .userMessage(text: "hi"))]
        let off = body(ModelRequest(instructions: "Be brief.", entries: entries, tools: tools))
        let on = body(ModelRequest(instructions: "Be brief.", entries: entries, tools: tools, webSearch: true))
        let offTools = off["tools"]?.arrayValue ?? []
        let onTools = on["tools"]?.arrayValue ?? []
        #expect(onTools.count == offTools.count + 1)
        #expect(Array(onTools.dropLast()) == offTools)
        #expect(onTools.last == ["type": "web_search"])
        // Nothing else in the body changes.
        var rest = on
        if case .object(var object) = rest { object["tools"] = off["tools"]; rest = .object(object) }
        #expect(rest == off)
    }

    @Test func theParserShowsASearchAsItStartsAndKeepsTheFinishedItem() throws {
        var parser = OpenAIResponses.StreamParser(model: "gpt-6-luna")
        let started = try parser.consume([
            "type": "response.output_item.added", "output_index": 0,
            "item": webSearchItem("ws_1", status: "in_progress"),
        ])
        guard case .hostedToolStarted(let call) = started.first else {
            Issue.record("Expected a hosted call, got \(started)")
            return
        }
        #expect(call.callID == "ws_1")
        #expect(call.summary == "Search the web")
        #expect(call.status == .running)

        let finished = webSearchItem("ws_1", action: ["type": "search", "query": "swift 6.2 release date"])
        let done = try parser.consume(["type": "response.output_item.done", "output_index": 0, "item": finished])
        #expect(done == [.item(.providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: finished)))])
    }

    @Test func aKeptSearchIsSentBackToTheSameModelAsItCame() {
        let item = webSearchItem("ws_1", action: ["type": "search", "query": "weather seattle"])
        let request = ModelRequest(
            instructions: "Be brief.",
            entries: [
                ThreadEntry(date: Date(timeIntervalSince1970: 1_795_000_000), item: .userMessage(text: "weather?")),
                ThreadEntry(item: .providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: item))),
                ThreadEntry(item: .assistantMessage(.init(text: "Rain.", provider: "openai", model: "gpt-6-luna", providerID: "msg_1"))),
            ],
            tools: tools, webSearch: true)
        let input = OpenAIResponses.input(for: request, model: "gpt-6-luna", timeZone: utc)
        #expect(input.count == 4)
        #expect(input[2] == item)
        // Another model gets no item it did not make.
        let other = OpenAIResponses.input(for: request, model: "gpt-6-sol", timeZone: utc)
        #expect(other.count == 3)
        #expect(!other.contains(item))
    }

    @Test func theLoopShowsTheSearchKeepsItAndSendsItOnTheNextRequest() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let finished = webSearchItem("ws_9", action: ["type": "search", "query": "swift 6.2"])
        let started = try #require(HostedWebSearch.call(fromOpenAIItem: webSearchItem("ws_9", status: "in_progress")))
        let provider = FakeProvider(replies: [
            [
                .hostedToolStarted(started),
                .item(.providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: finished))),
                .item(assistant("It shipped in September.")),
            ],
            [.item(assistant("You're welcome."))],
        ])
        let tool = RecordingTool()
        let log = UsageLog(fileURL: folder().appending(path: "usage.jsonl"))
        let loop = AgentLoop(
            provider: provider, thread: store, tools: [tool], instructions: { "Be brief." }, usageLog: log, webSearch: true)
        let events = EventLog()
        try await loop.run("when is swift 6.2", onEvent: { events.record($0) }, confirm: { _ in
            Issue.record("A hosted search never asks")
            return false
        })
        #expect(events.events.contains(.toolCallStarted(callID: "ws_9", name: "web_search")))
        #expect(events.events.contains(.toolRunning(callID: "ws_9", summary: "Search the web")))
        #expect(tool.received.isEmpty)
        // One request: a hosted call is not a function call, so no second request follows.
        #expect(provider.requests.count == 1)
        #expect(provider.requests[0].webSearch)

        try await loop.run("thanks", onEvent: { _ in }, confirm: { _ in true })
        let second = provider.requests[1]
        let replayed = second.entries.contains { entry in
            if case .providerItem(let item) = entry.item { item.payload == finished } else { false }
        }
        #expect(replayed)
        #expect(OpenAIResponses.input(for: second, model: "gpt-6-luna", timeZone: utc).contains(finished))
    }

    @Test func theFingerprintRecordedChangesWithHostedSearch() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let usage = TokenUsage(inputTokens: 50, cachedInputTokens: 0, outputTokens: 5)
        let provider = FakeProvider(replies: [[.item(assistant("done")), .usage(usage, provider: "test", model: "m")]])
        let log = UsageLog(fileURL: folder().appending(path: "usage.jsonl"))
        let tool = RecordingTool()
        let loop = AgentLoop(
            provider: provider, thread: store, tools: [tool], instructions: { "Be brief." }, usageLog: log, webSearch: true)
        try await loop.run("go", onEvent: { _ in }, confirm: { _ in true })
        let record = try #require(log.records().first)
        #expect(record.prompt == PromptFingerprint.make(instructions: "Be brief.", tools: [tool.definition], webSearch: true))
        #expect(record.prompt != PromptFingerprint.make(instructions: "Be brief.", tools: [tool.definition]))
    }

    @Test func eachActionReadsInTheRowStyle() {
        #expect(HostedWebSearch.summary(action: ["type": "search", "query": "swift 6.2 release date"]) == "Search the web swift 6.2 release date")
        #expect(HostedWebSearch.summary(action: ["type": "search", "queries": ["a", "b"]]) == "Search the web a; b")
        #expect(HostedWebSearch.summary(action: nil) == "Search the web")
        #expect(HostedWebSearch.summary(action: ["type": "open_page", "url": "https://swift.org"]) == "Open page https://swift.org")
        #expect(HostedWebSearch.summary(action: ["type": "find_in_page", "pattern": "6.2", "url": "https://swift.org"]) == "Find 6.2 in https://swift.org")
    }

    @Test func aRebuiltRowReadsTheSameAsTheLiveOne() throws {
        let finished = webSearchItem("ws_1", action: [
            "type": "search", "query": "swift 6.2 release date",
            "sources": [["type": "url", "url": "https://swift.org/blog"]],
        ])
        let entries = [
            ThreadEntry(item: .userMessage(text: "when")),
            ThreadEntry(item: .providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: finished))),
            ThreadEntry(item: .assistantMessage(.init(text: "September.", provider: "openai", model: "gpt-6-luna"))),
        ]

        var live = Transcript()
        live.apply(entries[0])
        let started = try #require(HostedWebSearch.call(fromOpenAIItem: webSearchItem("ws_1", status: "in_progress")))
        live.toolStarted(started.callID)
        live.toolRunning(started.callID, command: started.summary)
        #expect(live.toolCall("ws_1")?.summary == "Search the web")
        #expect(live.toolCall("ws_1")?.rowStatus == .running)
        live.apply(entries[1])
        live.apply(entries[2])

        let rebuilt = Transcript(entries: entries)
        #expect(live.rows.map(\.kind) == rebuilt.rows.map(\.kind))
        let call = try #require(rebuilt.toolCall("ws_1"))
        #expect(call.summary == "Search the web swift 6.2 release date")
        #expect(call.status == .succeeded)
        #expect(call.name == "web_search")
        #expect(call.output?.contains("https://swift.org/blog") == true)
        #expect(JSONValue.parse(call.arguments ?? "")?["query"] == "swift 6.2 release date")
        #expect(rebuilt.toolCallIDs == ["ws_1"])
    }

    @Test func aFailedSearchReadsAsFailedAndReasoningShowsNothing() {
        let entries = [
            ThreadEntry(item: .providerItem(.init(provider: "openai", model: "m", payload: ["type": "reasoning", "id": "rs_1"]))),
            ThreadEntry(item: .providerItem(.init(provider: "openai", model: "m", payload: webSearchItem("ws_2", status: "failed")))),
        ]
        let transcript = Transcript(entries: entries)
        #expect(transcript.toolCallIDs == ["ws_2"])
        #expect(transcript.toolCall("ws_2")?.status == .failed)
    }

    @Test func olderThreadLinesLoadUnchanged() throws {
        let line = #"{"date":0,"id":"9A3C2E1D-0000-4000-8000-000000000001","item":{"type":"provider_item","value":{"model":"m","payload":{"id":"rs_1","type":"reasoning"},"provider":"openai"}}}"#
        let entry = try JSONDecoder().decode(ThreadEntry.self, from: Data(line.utf8))
        guard case .providerItem(let item) = entry.item else {
            Issue.record("Expected a provider item")
            return
        }
        #expect(item.hostedToolCall == nil)
        #expect(Transcript(entries: [entry]).toolCallIDs.isEmpty)
    }
}

// MARK: - Brave Search

/// Stands in for the network. It never reaches Brave.
private final class StandInBrave: HTTPTransport, @unchecked Sendable {
    enum Answer {
        case status(Int, JSONValue)
        case raw(Int, String)
        case error(Error)
    }

    private let lock = NSLock()
    private var sent: [URLRequest] = []
    let answer: Answer

    init(_ answer: Answer) {
        self.answer = answer
    }

    var requests: [URLRequest] { lock.withLock { sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        }
        switch answer {
        case .status(let status, let body): return (Data(body.encodedString().utf8), response(status))
        case .raw(let status, let text): return (Data(text.utf8), response(status))
        case .error(let error): throw error
        }
    }
}

@Suite struct BraveSearchTests {
    private let results: JSONValue = [
        "type": "search",
        "web": ["results": [
            [
                "title": "Swift 6.2 <strong>Released</strong>", "url": "https://www.swift.org/blog/swift-6.2-released/",
                "description": "Swift 6.2 is <strong>available</strong> &amp; ships with Xcode&#39;s 26 &quot;release&quot;.",
                "age": "September 15, 2025",
            ],
            ["title": "Forums", "url": "https://forums.swift.org/", "description": "Talk about &lt;Swift&gt;"],
        ]],
    ]

    private func tool(_ answer: StandInBrave.Answer, key: String? = "test-key") -> (SearchWebTool, StandInBrave, MemorySecrets) {
        let secrets = MemorySecrets()
        if let key { try? secrets.write(key, for: BraveSearchKey.secretKey) }
        let transport = StandInBrave(answer)
        return (SearchWebTool(key: BraveSearchKey(secrets: secrets), transport: transport), transport, secrets)
    }

    private func run(_ tool: SearchWebTool, _ arguments: JSONValue) async -> String {
        await tool.run(arguments: arguments, context: ToolRunContext(callID: "call_1", confirm: { _ in
            Issue.record("search_web never asks")
            return false
        }))
    }

    @Test func resultsAreANumberedListWithoutMarkup() async {
        let (tool, transport, _) = tool(.status(200, results))
        let text = await run(tool, ["query": "swift 6.2", "count": .null, "freshness": .null])
        #expect(text == """
            1. Swift 6.2 Released
               https://www.swift.org/blog/swift-6.2-released/
               Swift 6.2 is available & ships with Xcode's 26 "release".
               Age: September 15, 2025

            2. Forums
               https://forums.swift.org/
               Talk about <Swift>
            """)
        let request = try! #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == "test-key")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.timeoutInterval == 15)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "q" }?.value == "swift 6.2")
        #expect(items.first { $0.name == "count" }?.value == "5")
        #expect(!items.contains { $0.name == "freshness" })
        #expect(request.url?.host == "api.search.brave.com")
        #expect(request.url?.path == "/res/v1/web/search")
    }

    @Test func theCountIsHeldBetweenOneAndTen() async {
        #expect(BraveSearch.clampedCount(nil) == 5)
        #expect(BraveSearch.clampedCount(.null) == 5)
        #expect(BraveSearch.clampedCount(3) == 3)
        #expect(BraveSearch.clampedCount(0) == 1)
        #expect(BraveSearch.clampedCount(-4) == 1)
        #expect(BraveSearch.clampedCount(50) == 10)
        let (tool, transport, _) = tool(.status(200, results))
        _ = await run(tool, ["query": "x", "count": 40, "freshness": "pw"])
        let items = URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "count" }?.value == "10")
        #expect(items.first { $0.name == "freshness" }?.value == "pw")
    }

    @Test func aLongResultIsCut() {
        let many: [JSONValue] = (1...400).map { index in
            ["title": .string("Result \(index)"), "url": .string("https://example.com/\(index)"),
             "description": .string(String(repeating: "word ", count: 20))]
        }
        let text = BraveSearch.resultText(from: ["web": ["results": .array(many)]], query: "x")
        #expect(text.hasSuffix("characters.]"))
        #expect(text.contains("[Cut at 16000 of "))
        #expect(text.count < 16_100)
    }

    @Test func noResultsIsOnePlainSentence() async {
        let (tool, _, _) = tool(.status(200, ["type": "search", "web": ["results": []]]))
        #expect(await run(tool, ["query": "zzqx", "count": .null, "freshness": .null]) == "Brave Search found no results for \"zzqx\".")
        let (bare, _, _) = self.tool(.status(200, ["type": "search"]))
        #expect(await run(bare, ["query": "zzqx", "count": .null, "freshness": .null]) == "Brave Search found no results for \"zzqx\".")
    }

    @Test func withNoKeyItSaysWhereToAddOneAndSendsNothing() async {
        let (tool, transport, _) = tool(.status(200, results), key: nil)
        let text = await run(tool, ["query": "x", "count": .null, "freshness": .null])
        #expect(text == BraveSearch.noKeyError)
        #expect(text.contains("Settings, General"))
        #expect(transport.requests.isEmpty)
        let blank = SearchWebTool(key: BraveSearchKey(secrets: MemorySecrets()), transport: transport)
        #expect(await run(blank, ["query": "x", "count": .null, "freshness": .null]) == BraveSearch.noKeyError)
    }

    @Test func theKeyIsReadAtEachCall() async throws {
        let (tool, transport, secrets) = tool(.status(200, results), key: nil)
        #expect(await run(tool, ["query": "x", "count": .null, "freshness": .null]) == BraveSearch.noKeyError)
        try BraveSearchKey(secrets: secrets).save("  added-later \n")
        _ = await run(tool, ["query": "x", "count": .null, "freshness": .null])
        #expect(transport.requests.last?.value(forHTTPHeaderField: "X-Subscription-Token") == "added-later")
    }

    @Test func eachFailureIsOnePlainSentence() async {
        let cases: [(StandInBrave.Answer, String)] = [
            (.status(401, [:]), "Error: Brave Search refused the API key (status 401). The owner can check the key in Settings, General."),
            (.status(403, [:]), "Error: Brave Search refused the API key (status 403). The owner can check the key in Settings, General."),
            (.status(429, [:]), "Error: Brave Search's rate limit was reached, so the search did not run. Try again in a little while."),
            (.status(500, [:]), "Error: Brave Search answered with status 500, so the search did not run."),
            (.raw(200, "<html>not json"), "Error: Brave Search's answer could not be read."),
            (.error(URLError(.timedOut)), "Error: Brave Search did not answer within 15 seconds."),
        ]
        for (answer, expected) in cases {
            let (tool, _, _) = tool(answer)
            #expect(await run(tool, ["query": "x", "count": .null, "freshness": .null]) == expected)
        }
        let (offline, _, _) = tool(.error(URLError(.notConnectedToInternet)))
        let text = await run(offline, ["query": "x", "count": .null, "freshness": .null])
        #expect(text.hasPrefix("Error: the search could not reach Brave Search: "))
        #expect(!text.contains("\n"))
    }

    @Test func anEmptyQueryDoesNotSearch() async {
        let (tool, transport, _) = tool(.status(200, results))
        #expect(await run(tool, ["query": "  ", "count": .null, "freshness": .null]) == "Error: the call did not include a query.")
        #expect(transport.requests.isEmpty)
    }

    @Test func itReadsLikeTheHostedSearchAndNeverAsks() {
        let tool = SearchWebTool(key: nil)
        #expect(tool.summary(arguments: ["query": "swift 6.2 release date"]) == "Search the web swift 6.2 release date")
        #expect(tool.goAhead == .never)
        #expect(tool.source == .webSearch)
        #expect(tool.definition.strict)
        #expect(Set(ToolParameter.list(from: tool.definition.parameters).map(\.name)) == ["query", "count", "freshness"])
        #expect(ToolCallSummaries.builtIn.summary(name: "search_web", arguments: #"{"query":"tides"}"#) == "Search the web tides")
        // A run without it in the list still reads its old rows.
        #expect(ToolCallSummaries([]).summary(name: "search_web", arguments: #"{"query":"tides"}"#) == "Search the web tides")
    }

    @Test func itGoesLastAndIsNotAQuickActionStep() throws {
        let tools = BuiltInTools.make(webSearch: SearchWebTool(key: nil))
        #expect(tools.map(\.definition.name) == BuiltInTools.names + ["search_web"])
        #expect(Array(tools.map(\.definition.name).dropLast()) == BuiltInTools.make().map(\.definition.name))
        let change = try #require(tools.first { $0.definition.name == ChangeQuickActionTool.name } as? ChangeQuickActionTool)
        #expect(!change.tools().map(\.name).contains("search_web"))
        // It is a group of its own in Settings, after the built-in groups.
        let groups = ToolRegistry(builtIn: tools).groups
        #expect(groups.last?.source == .webSearch)
        #expect(groups.last?.tools.map(\.name) == ["search_web"])
    }

    /// The characters `search_web` adds to every request, for decided.md.
    @Test func itsDefinitionStaysShort() {
        let definition = SearchWebTool(key: nil).definition
        let encoded: JSONValue = [
            "type": "function", "name": .string(definition.name), "description": .string(definition.description),
            "parameters": definition.parameters, "strict": true,
        ]
        let characters = encoded.encodedString().count
        print("search_web adds \(characters) characters to every request")
        #expect(characters < 800)
    }
}

// MARK: - The key beside the sign-in

@Suite struct BraveKeyStorageTests {
    @Test func theKeyIsTrimmedAndABlankKeyRemovesIt() throws {
        let secrets = MemorySecrets()
        let key = BraveSearchKey(secrets: secrets)
        #expect(!key.isSet)
        try key.save("  abc  ")
        #expect(key.read() == "abc")
        try key.save("   ")
        #expect(!key.isSet)
        try key.save("abc")
        key.remove()
        #expect(secrets.read(BraveSearchKey.secretKey) == nil)
    }

    @Test func aBraveKeyInTheKeychainDoesNotHideASignInToMove() throws {
        let file = FileSecrets(fileURL: folder().appending(path: "secrets.json"))
        try file.write("refresh-1", for: ChatGPTAuthenticator.refreshTokenKey)
        try file.write("client-1", for: ChatGPTAuthenticator.clientIDKey)
        try file.write("dev-brave", for: BraveSearchKey.secretKey)
        let keychain = MemoryKeychain([BraveSearchKey.secretKey: "release-brave"])
        let (store, status) = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(status.migration == .moved(count: 2, fileProblem: nil))
        #expect(store.read(ChatGPTAuthenticator.refreshTokenKey) == "refresh-1")
        // The Keychain's own key wins, and the file keeps the development build's.
        #expect(store.read(BraveSearchKey.secretKey) == "release-brave")
        #expect(file.all() == [BraveSearchKey.secretKey: "dev-brave"])
    }

    @Test func aBraveKeyAloneInTheFileIsNotASignIn() throws {
        let file = FileSecrets(fileURL: folder().appending(path: "secrets.json"))
        try file.write("dev-brave", for: BraveSearchKey.secretKey)
        let keychain = MemoryKeychain([
            ChatGPTAuthenticator.refreshTokenKey: "refresh-1", ChatGPTAuthenticator.clientIDKey: "client-1",
        ])
        let (_, status) = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(status.migration == .alreadyInKeychain(fileHasSecrets: false))
        #expect(!status.explanation.contains("also has a sign-in"))
    }

    @Test func aKeyWithNoSignInStillMovesOnce() throws {
        let file = FileSecrets(fileURL: folder().appending(path: "secrets.json"))
        try file.write("dev-brave", for: BraveSearchKey.secretKey)
        let keychain = MemoryKeychain()
        let (store, status) = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(status.migration == .moved(count: 1, fileProblem: nil))
        #expect(store.read(BraveSearchKey.secretKey) == "dev-brave")
        // The next launch has nothing new to move.
        let next = SecretStorage.resolve(
            hasFeed: true, usesAnotherDataFolder: false, file: file, keychain: { KeychainSecrets(items: keychain) })
        #expect(next.status.migration == .nothingToMove)
    }
}

// MARK: - Incognito

@Suite struct WebSearchIncognitoTests {
    @Test func theIncognitoListHasNoSearchAndItsLoopOffersNone() async throws {
        #expect(BuiltInTools.makeIncognito().map(\.definition.name) == BuiltInTools.incognitoNames)
        let provider = FakeProvider(replies: [[.item(assistant("hi"))]])
        let loop = AgentLoop(
            provider: provider, thread: InMemoryThreadStore(), tools: BuiltInTools.makeIncognito(),
            instructions: { "x" }, episodeTimeout: { .infinity })
        #expect(!loop.webSearch)
        try await loop.run("hello", onEvent: { _ in }, confirm: { _ in true })
        #expect(provider.requests.map(\.webSearch) == [false])
        #expect(!provider.requests[0].tools.map(\.name).contains("search_web"))
    }
}
