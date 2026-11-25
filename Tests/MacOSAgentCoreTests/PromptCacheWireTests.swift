import Foundation
import Synchronization
import Testing
@testable import MacOSAgentCore

/// The prompt cache, tested where it is decided: in the bytes the OpenAI provider sends. Each
/// test drives the real loop and provider against `StubResponsesServer`, which keeps a fake
/// cache with OpenAI's rules, so a change that breaks the cached prefix fails here instead of
/// showing up as uncached tokens later.
@Suite struct PromptCacheWireTests {
    @Test func everyRequestStartsWithTheOneBeforeIt() async throws {
        let run = try await WireEpisode.run()
        let received = run.server.received
        #expect(received.count == WireEpisode.requestCount)

        for (index, pair) in zip(received, received.dropFirst()).enumerated() {
            let (previous, current) = pair
            guard previous.body["model"] == current.body["model"] else { continue }
            #expect(previous.body["tools"] == current.body["tools"], "request \(index + 2) changed the tool list")
            let difference = RequestDigest.firstDifference(
                previous: previous.input.map { $0.encodedString() }, current: current.input.map { $0.encodedString() })
            #expect(difference == nil, "request \(index + 2) differs from request \(index + 1) at input item \(difference ?? -1): \(WireEpisode.describe(previous.input, current.input, at: difference))")
        }
    }

    @Test func eachRequestReadsThePreviousOneFromTheCache() async throws {
        let run = try await WireEpisode.run()
        let received = run.server.received
        let reported = run.server.reported

        for index in received.indices.dropFirst() {
            let previous = received[index - 1]
            guard previous.body["model"] == received[index].body["model"] else {
                // A new model has a cache of its own, so its first request reads nothing.
                #expect(reported[index].cachedTokens == 0)
                continue
            }
            let boundaries = StubResponsesServer.boundaries(tools: previous.body["tools"] ?? .array([]), input: previous.input)
            let expected = StubResponsesServer.tokens(boundaries.prompt.prefix(boundaries.ends.last ?? 0))
            #expect(reported[index].cachedTokens == expected, "request \(index + 1) read \(reported[index].cachedTokens) cached tokens, not the \(expected) the request before it wrote")
        }
        #expect(reported.allSatisfy { $0.removedReasoning.isEmpty }, "the model withheld replayed reasoning: \(reported.map(\.removedReasoning))")
    }

    @Test func theHeadersStayTheSameAcrossARelaunch() async throws {
        let run = try await WireEpisode.run()
        let headers = run.server.received.map(\.headers)
        #expect(headers.allSatisfy { $0["session-id"] == WireEpisode.cacheKey })
        #expect(headers.allSatisfy { $0["x-client-request-id"] == WireEpisode.cacheKey })
        #expect(headers.allSatisfy { $0["Authorization"] == "Bearer test-access" })
        #expect(run.server.received.allSatisfy { $0.body["prompt_cache_key"] == .string(WireEpisode.cacheKey) })
    }

    @Test func theUsageLogSaysWhereEachRequestStoppedMatching() async throws {
        let run = try await WireEpisode.run()
        let records = run.usageLog.records()
        #expect(records.count == WireEpisode.requestCount)
        #expect(records.allSatisfy { $0.diverged == nil })
        #expect(records.allSatisfy { $0.device == "0123abcd" && $0.machine == "TestMac1,1" && $0.build == "9.9 (99)" })
        #expect(zip(records, run.server.reported).allSatisfy { $0.cached == $1.cachedTokens && $0.written == $1.cacheWriteTokens })
        // One digest for the tools, then one per input item, the same as what was sent.
        for (record, request) in zip(records, run.server.received) {
            #expect(record.items == RequestDigest.make(tools: request.body["tools"], input: request.input))
        }
    }

    /// The harness itself: a request whose earlier input changes must fail every check above.
    /// Here the time zone changes after the first message, so its timestamp is sent differently,
    /// as it would be after the Mac moved time zones partway through an episode.
    @Test func aChangedEarlierItemIsCaughtWithWhereItChanged() async throws {
        let server = StubResponsesServer(replies: [
            [.reasoning, .call(name: "record", arguments: ["q": "calendar"])],
            [.reasoning, .message("Two meetings.")],
            [.message("Nothing tomorrow.")],
        ])
        let file = temporaryThreadFile()
        let usageLog = UsageLog(fileURL: file.deletingLastPathComponent().appending(path: "usage.jsonl"))
        let thread = try ThreadStore(fileURL: file)

        let first = try WireEpisode.loop(server: server, thread: thread, usageLog: usageLog, timeZone: WireEpisode.utc)
        try await WireEpisode.send(first, "what's on my calendar", at: WireEpisode.start)
        let moved = try WireEpisode.loop(
            server: server, thread: thread, usageLog: usageLog, timeZone: TimeZone(identifier: "America/New_York")!)
        try await WireEpisode.send(moved, "and tomorrow?", at: WireEpisode.start.addingTimeInterval(60))

        let reported = server.reported
        let last = try #require(reported.last)
        // The model withholds the reasoning written after the old timestamp, and the cache
        // only holds as far as the instructions.
        #expect(last.removedReasoning == ["rs_1", "rs_3"])
        let developerEnd = StubResponsesServer.boundaries(
            tools: server.received[2].body["tools"] ?? .array([]), input: server.received[2].input).developerEnd ?? 0
        let expected = StubResponsesServer.tokens(
            (StubResponsesServer.boundaries(tools: server.received[2].body["tools"] ?? .array([]), input: server.received[2].input).prompt)
                .prefix(developerEnd))
        #expect(last.cachedTokens == expected)

        let record = try #require(usageLog.records().last)
        #expect(record.removed == ["prefix_mismatch": 2])
        // 0 is the tool list, 1 the instructions, 2 the first message: the one that changed.
        // The loop compares with the request it last sent, so a second loop starts fresh;
        // the digests still show it against the line before.
        let lines = usageLog.records()
        let difference = RequestDigest.firstDifference(previous: lines[1].items ?? [], current: lines[2].items ?? [])
        #expect(difference == 2)
    }

    /// The whole episode's requests, compared with a file in the repository, so any change to
    /// what goes over the wire shows up as a diff in review. To accept a change on purpose,
    /// run the tests with `MAC_OS_AGENT_UPDATE_GOLDEN=1` and commit the file it writes.
    @Test func theEpisodeSendsWhatTheGoldenFileHolds() async throws {
        let run = try await WireEpisode.run()
        let requests: [JSONValue] = run.server.received.map { request in
            let kept = request.headers.filter { WireEpisode.goldenHeaders.contains($0.key) }
            return [
                "headers": .object(kept.mapValues { .string($0) }),
                "body": WireEpisode.shortenInstructions(request.body),
            ]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let actual = try encoder.encode(JSONValue.array(requests)) + Data("\n".utf8)
        let golden = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/openai-wire-episode.json")

        if ProcessInfo.processInfo.environment["MAC_OS_AGENT_UPDATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: golden.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: golden)
        }
        let expected = try Data(contentsOf: golden)
        #expect(actual == expected, "The requests differ from \(golden.lastPathComponent). If the change is meant, run with MAC_OS_AGENT_UPDATE_GOLDEN=1 and commit the file.")
    }
}

/// One episode that touches each kind of item the cache has to survive: a tool call with
/// reasoning, a plain follow-up, a skill message, a relaunch partway through, and a model
/// change. Every step is fixed, so the requests come out the same on any Mac.
enum WireEpisode {
    static let cacheKey = "mac-os-agent-wire-test"
    static let utc = TimeZone(identifier: "UTC")!
    static let start = Date(timeIntervalSince1970: 1_795_000_000)
    static let requestCount = 9
    static let goldenHeaders: Set<String> = ["Accept", "Content-Type", "User-Agent", "session-id", "x-client-request-id"]
    static let device = UsageDevice(device: "0123abcd", machine: "TestMac1,1", build: "9.9 (99)")

    /// Long enough to pass the 1,024-token minimum on its own, as the real instructions do.
    static let instructions = (1...60).map {
        "Rule \($0): answer in plain sentences, and say what you did and what you found before anything else."
    }.joined(separator: "\n")

    struct Run {
        var server: StubResponsesServer
        var usageLog: UsageLog
    }

    static func run() async throws -> Run {
        let server = StubResponsesServer(replies: [
            // 1: a tool call, then the answer.
            [.reasoning, .call(name: "record", arguments: ["q": "calendar"])],
            [.reasoning, .message("Two meetings today.")],
            // 2: a plain follow-up.
            [.message("Nothing tomorrow.")],
            // 3: a skill message with a tool call.
            [.reasoning, .call(name: "record", arguments: ["q": "downloads"])],
            [.message("Tidied 4 files.")],
            // 4: after a relaunch.
            [.message("You're welcome.")],
            // 5 and 6: after a model change.
            [.reasoning, .message("Still here.")],
            [.message("Done.")],
            [.message("Bye.")],
        ])
        let file = temporaryThreadFile()
        let usageLog = UsageLog(
            fileURL: file.deletingLastPathComponent().appending(path: "usage.jsonl"), device: { device })
        let model = ModelSwitch()

        var thread = try ThreadStore(fileURL: file)
        var loop = try self.loop(server: server, thread: thread, usageLog: usageLog, model: model)
        try await send(loop, "what's on my calendar", at: start)
        try await send(loop, "and tomorrow?", at: start.addingTimeInterval(60))
        try await send(
            loop, "/tidy downloads", at: start.addingTimeInterval(120),
            skill: .init(name: "tidy", message: "<skill name=\"tidy\">Move old files to a dated folder.</skill>"))

        // A relaunch: the thread is read back from its file, and the loop and provider are new.
        thread = try ThreadStore(fileURL: file)
        loop = try self.loop(server: server, thread: thread, usageLog: usageLog, model: model)
        try await send(loop, "thanks", at: start.addingTimeInterval(180))

        model.set("gpt-6.2-sol")
        try await send(loop, "are you there", at: start.addingTimeInterval(240))
        try await send(loop, "ok", at: start.addingTimeInterval(300))
        try await send(loop, "bye", at: start.addingTimeInterval(360))
        return Run(server: server, usageLog: usageLog)
    }

    static func loop(
        server: StubResponsesServer, thread: ThreadStore, usageLog: UsageLog,
        model: ModelSwitch = ModelSwitch(), timeZone: TimeZone = utc,
        instructionsForNewEpisode: (@Sendable () async -> String)? = nil
    ) throws -> AgentLoop {
        let secrets = MemorySecrets([ChatGPTAuthenticator.refreshTokenKey: "r", ChatGPTAuthenticator.clientIDKey: "c"])
        let transport = FakeTransport(body: [
            "access_token": "test-access", "refresh_token": "r2", "expires_in": 3600,
            "scope": .string(ChatGPTSignIn.scope),
        ])
        let authenticator = ChatGPTAuthenticator(secrets: secrets, installationID: UUID(), transport: transport)
        let provider = OpenAIResponsesProvider(
            access: .signIn(authenticator), model: { model.current }, promptCacheKey: cacheKey,
            session: server.session(), timeZone: timeZone)
        return AgentLoop(
            provider: provider, thread: thread, tools: [RecordingTool()],
            instructionsForEpisode: { _ in instructions }, usageLog: usageLog,
            instructionsForNewEpisode: instructionsForNewEpisode)
    }

    static func send(
        _ loop: AgentLoop, _ text: String, at date: Date, skill: ThreadItem.SkillInvocation? = nil
    ) async throws {
        try await loop.run(text, skill: skill, now: date, onEvent: { _ in }, confirm: { _ in true })
    }

    /// The body with the instructions replaced by their length and digest, so the golden file
    /// stays short enough to read in a diff and a change to them still shows.
    static func shortenInstructions(_ body: JSONValue) -> JSONValue {
        guard case .object(var object) = body, var input = body["input"]?.arrayValue, !input.isEmpty,
              case .object(var first) = input[0], let text = first["content"]?.stringValue
        else { return body }
        first["content"] = .string("<instructions: \(text.count) characters, \(RequestDigest.digest(.string(text)))>")
        input[0] = .object(first)
        object["input"] = .array(input)
        return .object(object)
    }

    /// The two items at a difference, for a failure message.
    static func describe(_ previous: [JSONValue], _ current: [JSONValue], at index: Int?) -> String {
        guard let index else { return "" }
        let before = previous.indices.contains(index) ? previous[index].encodedString() : "nothing"
        let after = current.indices.contains(index) ? current[index].encodedString() : "nothing"
        return "was \(before.prefix(200)), now \(after.prefix(200))"
    }

    /// The model setting, which the provider reads at the start of each reply.
    final class ModelSwitch: Sendable {
        private let value: Mutex<String>
        init(_ model: String = "gpt-6.2-astra") { value = Mutex(model) }
        var current: String { value.withLock { $0 } }
        func set(_ model: String) { value.withLock { $0 = model } }
    }
}

@Suite struct RequestDigestTests {
    @Test func aPrefixHasNoDifferenceAndAChangeIsFoundWhereItIs() {
        #expect(RequestDigest.firstDifference(previous: ["a", "b"], current: ["a", "b", "c"]) == nil)
        #expect(RequestDigest.firstDifference(previous: ["a", "b"], current: ["a", "x", "c"]) == 1)
        #expect(RequestDigest.firstDifference(previous: ["a", "b", "c"], current: ["a", "b"]) == 2)
        #expect(RequestDigest.firstDifference(previous: [], current: ["a"]) == nil)
    }

    @Test func digestsFollowTheBytesSent() {
        let items: [JSONValue] = [["role": "developer", "content": "x"], ["b": 1, "a": 2]]
        let digests = RequestDigest.make(tools: nil, input: items)
        #expect(digests.count == 3)
        #expect(digests.allSatisfy { $0.count == 6 })
        // Keys are sorted before hashing, as they are in the body.
        #expect(RequestDigest.make(tools: nil, input: [["a": 2, "b": 1]])[1] == digests[2])
        #expect(RequestDigest.make(tools: nil, input: [["a": 3, "b": 1]])[1] != digests[2])
    }

    @Test func thisMacHasAHardwareModel() {
        #expect(UsageDevice.hardwareModel().hasPrefix("Mac") || UsageDevice.hardwareModel().contains(","))
    }
}
