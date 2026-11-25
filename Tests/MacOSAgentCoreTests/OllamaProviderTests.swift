import Foundation
import Testing
@testable import MacOSAgentCore

/// A local model through Ollama: the same provider and request format as OpenAI, sent to this
/// Mac with no sign-in, behind the local models experiment.
@Suite struct OllamaProviderTests {
    private static let local = "ollama/inkling-2-mini"

    @Test func aLocalModelGoesToOllamaWithoutSigningIn() async throws {
        let server = StubResponsesServer(replies: [
            [.reasoning, .call(name: "record", arguments: ["q": "battery"])],
            [.reasoning, .message("82%, discharging.")],
            [.message("About 4 hours.")],
        ])
        let file = temporaryThreadFile()
        let usageLog = UsageLog(fileURL: file.deletingLastPathComponent().appending(path: "usage.jsonl"))
        let loop = try WireEpisode.loop(
            server: server, thread: ThreadStore(fileURL: file), usageLog: usageLog,
            model: WireEpisode.ModelSwitch(Self.local))
        try await WireEpisode.send(loop, "battery?", at: WireEpisode.start)
        try await WireEpisode.send(loop, "how long left?", at: WireEpisode.start.addingTimeInterval(30))

        let received = server.received
        #expect(received.count == 3)
        #expect(received.allSatisfy { $0.url == URL(string: "http://localhost:11434/v1/responses") })
        #expect(received.allSatisfy { $0.headers["Authorization"] == nil && $0.headers["session-id"] == nil })
        #expect(received.allSatisfy { $0.body["model"] == "inkling-2-mini" })
        // The local model's reasoning and calls are replayed to it, as OpenAI's are to OpenAI.
        #expect(received[2].input.contains { $0["type"] == "reasoning" })
        #expect(received[2].input.contains { $0["type"] == "function_call" && $0["id"] != nil })
        #expect(server.reported.allSatisfy { $0.removedReasoning.isEmpty })
        for (previous, current) in zip(received, received.dropFirst()) {
            #expect(RequestDigest.firstDifference(
                previous: previous.input.map { $0.encodedString() }, current: current.input.map { $0.encodedString() }) == nil)
        }

        let records = usageLog.records()
        #expect(records.allSatisfy { $0.provider == "ollama" && $0.model == "inkling-2-mini" })
        #expect(records.allSatisfy { $0.diverged == nil })
    }

    @Test func switchingToOpenAILeavesTheLocalModelsItemsOut() async throws {
        let server = StubResponsesServer(replies: [[.reasoning, .message("Local.")], [.message("Remote.")]])
        let model = WireEpisode.ModelSwitch(Self.local)
        let loop = try WireEpisode.loop(
            server: server, thread: ThreadStore(fileURL: temporaryThreadFile()),
            usageLog: UsageLog(fileURL: temporaryThreadFile()), model: model)
        try await WireEpisode.send(loop, "one", at: WireEpisode.start)
        model.set("gpt-6.2-astra")
        try await WireEpisode.send(loop, "two", at: WireEpisode.start.addingTimeInterval(30))

        let second = try #require(server.received.last)
        #expect(second.url?.host() == "api.openai.com")
        #expect(second.headers["Authorization"] == "Bearer test-access")
        #expect(!second.input.contains { $0["type"] == "reasoning" })
        // The local model's answer is still there as text, without its id.
        let answer = try #require(second.input.first { $0["role"] == "assistant" })
        #expect(answer["id"]?.stringValue?.hasPrefix("msg_mac_os_agent_") == true)
    }

    @Test func openingThePanelWarmsTheNextRequestOnce() async throws {
        let server = StubResponsesServer(replies: [[.message("Hi.")]])
        let file = temporaryThreadFile()
        let loop = try WireEpisode.loop(
            server: server, thread: ThreadStore(fileURL: file), usageLog: UsageLog(fileURL: temporaryThreadFile()),
            model: WireEpisode.ModelSwitch(Self.local), instructionsForNewEpisode: { WireEpisode.instructions })

        await loop.warm()
        await loop.warm()
        #expect(server.received.count == 1)
        let warm = try #require(server.received.first)
        #expect(warm.body["stream"] == false)
        #expect(warm.body["max_output_tokens"] == 1)
        #expect(warm.input.count == 1)
        #expect(warm.input.first?["role"] == "developer")

        // The real request then reads what the warming wrote.
        try await WireEpisode.send(loop, "hello", at: Date())
        let real = try #require(server.received.last)
        #expect(Array(real.input.prefix(1)) == warm.input)
        #expect(real.body["tools"] == warm.body["tools"])
        let boundaries = StubResponsesServer.boundaries(tools: real.body["tools"] ?? .array([]), input: real.input)
        let developerTokens = StubResponsesServer.tokens(boundaries.prompt.prefix(boundaries.developerEnd ?? 0))
        #expect(server.reported.last?.cachedTokens == developerTokens)
    }

    @Test func anOpenAIModelIsNeverWarmed() async throws {
        let server = StubResponsesServer(replies: [])
        let loop = try WireEpisode.loop(
            server: server, thread: ThreadStore(fileURL: temporaryThreadFile()),
            usageLog: UsageLog(fileURL: temporaryThreadFile()), instructionsForNewEpisode: { WireEpisode.instructions })
        await loop.warm()
        #expect(server.received.isEmpty)
    }

    @Test func withTheExperimentOffALocalModelFallsBackToTheDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "ollama-tests-\(UUID().uuidString)"))
        ModelSetting.set(Self.local, defaults)
        #expect(ModelSetting.effective(defaults) == OpenAIModel.defaultID)
        Experiment.localModelsThroughOllama.set(true, defaults)
        #expect(ModelSetting.effective(defaults) == Self.local)
        // The setting itself is kept either way.
        #expect(ModelSetting.current(defaults) == Self.local)
        #expect(ModelSetting.displayName(id: Self.local) == "inkling-2-mini (Ollama)")
        #expect(ModelSetting.displayName(id: "gpt-6.2-astra") == "GPT-6.2 Astra")
    }

    @Test func theInstalledModelsComeFromTheTagsList() async {
        let tags = FakeTransport(body: ["models": [["name": "qwen4:14b"], ["name": "inkling-2-mini:latest"]]])
        #expect(await Ollama.installedModels(transport: tags) == ["inkling-2-mini:latest", "qwen4:14b"])
        #expect(tags.requests.first?.url == URL(string: "http://localhost:11434/api/tags"))
        #expect(await Ollama.installedModels(transport: FakeTransport(status: 500, body: [:])) == [])
        #expect(Ollama.displayName("inkling-2-mini:latest") == "inkling-2-mini (Ollama)")
        #expect(Ollama.modelName(fromID: "gpt-6-luna") == nil)
    }

    @Test func ollamaNotRunningSaysSo() async throws {
        // Nothing listens on port 1, so the connection is refused at once.
        let secrets = MemorySecrets()
        let provider = OpenAIResponsesProvider(
            access: .signIn(ChatGPTAuthenticator(secrets: secrets, installationID: UUID(), transport: FakeTransport(body: [:]))),
            model: { Self.local }, promptCacheKey: "k", ollamaBaseURL: URL(string: "http://127.0.0.1:1")!)
        let request = ModelRequest(instructions: "x", entries: [], tools: [])
        await #expect(throws: OpenAIResponsesProvider.ProviderError.self) {
            for try await _ in provider.streamReply(to: request) {}
        }
        do {
            for try await _ in provider.streamReply(to: request) {}
        } catch {
            #expect(error.localizedDescription.hasPrefix("Ollama is not running at 127.0.0.1:1."))
        }
    }
}

/// Against the Ollama running on this Mac, so it is skipped unless
/// `MAC_OS_AGENT_LIVE_OLLAMA=<model>` names an installed model, as in
/// `MAC_OS_AGENT_LIVE_OLLAMA=inkling-2-mini:latest swift test --filter OllamaLiveTests`.
/// It prints the timings and cache counts it saw.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_LIVE_OLLAMA"] != nil))
struct OllamaLiveTests {
    @Test func aWarmedEpisodeCallsAToolAndAnswers() async throws {
        let name = try #require(ProcessInfo.processInfo.environment["MAC_OS_AGENT_LIVE_OLLAMA"])
        let file = temporaryThreadFile()
        let usageLog = UsageLog(fileURL: file.deletingLastPathComponent().appending(path: "usage.jsonl"))
        let provider = OpenAIResponsesProvider(
            access: .signIn(ChatGPTAuthenticator(secrets: MemorySecrets(), installationID: UUID(), transport: FakeTransport(body: [:]))),
            model: { Ollama.modelID(name) }, promptCacheKey: "mac-os-agent-live-test")
        let tool = RecordingTool(result: "Now drawing from 'Battery Power'\n -InternalBattery-0\t82%; discharging; 4:51 remaining\n[exit status 0]")
        // About as long as the app's real prompt with its tools, around 9,000 tokens. Ollama
        // reuses its cache in blocks of 4,096 tokens, so a shorter one never shows a hit.
        let padding = (1...330).map { "Guideline \($0): check with a tool first when the owner asks about this Mac, then answer in one plain sentence with the numbers." }
        let instructions = AgentInstructions.defaultPrompt + "\n\nTo check the battery, call `record` with {\"what\": \"battery\"}.\n"
            + padding.joined(separator: "\n")
        let loop = AgentLoop(
            provider: provider, thread: try ThreadStore(fileURL: file), tools: [tool],
            instructionsForEpisode: { _ in instructions }, usageLog: usageLog,
            instructionsForNewEpisode: { instructions })

        let warmStart = ContinuousClock.now
        await loop.warm()
        print("live: warmed in \(ContinuousClock.now - warmStart)")
        try await loop.run("What's my battery level?", onEvent: { _ in }, confirm: { _ in true })

        let records = usageLog.records()
        for record in records {
            print("live: \(record.model) input \(record.input) cached \(record.cached) seconds \(record.seconds ?? 0)")
        }
        #expect(!tool.received.isEmpty, "the model never called the tool")
        let answer = await loop.thread.entries.reversed().compactMap { entry -> String? in
            if case .assistantMessage(let message) = entry.item { return message.text }
            return nil
        }.first
        print("live: answer \(answer ?? "none")")
        #expect(answer?.contains("82") == true)
        #expect(records.first.map { $0.cached >= 4096 } == true, "the first request did not read the warmed prefix")
    }
}
