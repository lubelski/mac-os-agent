import Foundation
import Testing
@testable import MacOSAgentCore

/// A development build reaches its models through inference-gateway, with no sign-in of its
/// own. A release build signs in and calls OpenAI and Ollama directly, as before.
@Suite struct InferenceGatewayTests {
    private static let local = "ollama/inkling-2-mini"

    @Test func aBuildWithAFeedSignsInAndOneWithoutUsesTheGateway() {
        #expect(ModelAccess.forBuild(hasFeed: true) == .signIn)
        #expect(ModelAccess.forBuild(hasFeed: false) == .gateway)
        // The same signal as the update feed. A release build's Info.plist has both keys.
        let release: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "a-public-key"]
        #expect(ModelAccess.forBuild(hasFeed: AppUpdates.hasFeed(release)) == .signIn)
        #expect(ModelAccess.forBuild(hasFeed: AppUpdates.hasFeed([:])) == .gateway)
        // The test runner's bundle has no feed, like a development build.
        #expect(ModelAccess.forThisRun() == .gateway)
    }

    @Test func anOpenAIRequestGoesToTheGatewayWithNoSignIn() async throws {
        let server = StubResponsesServer(replies: [[.message("Hi.")]])
        let loop = try Self.loop(server: server, model: "gpt-6.2-astra")
        try await WireEpisode.send(loop, "hello", at: WireEpisode.start)

        let request = try #require(server.received.first)
        #expect(request.url == URL(string: "http://127.0.0.1:47811/openai/responses"))
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["X-Client-App"] == "mac-os-agent")
        // The session headers still go, so OpenAI routes the thread to the same cache.
        #expect(request.headers["session-id"] == WireEpisode.cacheKey)
        #expect(request.headers["x-client-request-id"] == WireEpisode.cacheKey)
        #expect(request.body["model"] == "gpt-6.2-astra")
        #expect(request.body["prompt_cache_key"] == .string(WireEpisode.cacheKey))
    }

    @Test func anOllamaRequestGoesToTheGatewayOnTheSamePath() async throws {
        let server = StubResponsesServer(replies: [[.message("Hi.")]])
        let loop = try Self.loop(server: server, model: Self.local)
        try await WireEpisode.send(loop, "hello", at: WireEpisode.start)

        let request = try #require(server.received.first)
        #expect(request.url == URL(string: "http://127.0.0.1:47811/ollama/v1/responses"))
        #expect(request.headers["Authorization"] == nil)
        #expect(request.headers["X-Client-App"] == "mac-os-agent")
        #expect(request.headers["session-id"] == nil)
        #expect(request.body["model"] == "inkling-2-mini")
    }

    @Test func directAccessStillSignsInAtOpenAIAndNamesNoClient() async throws {
        let server = StubResponsesServer(replies: [[.message("Hi.")]])
        let loop = try WireEpisode.loop(
            server: server, thread: ThreadStore(fileURL: temporaryThreadFile()),
            usageLog: UsageLog(fileURL: temporaryThreadFile()))
        try await WireEpisode.send(loop, "hello", at: WireEpisode.start)

        let request = try #require(server.received.first)
        #expect(request.url == URL(string: "https://api.openai.com/v1/responses"))
        #expect(request.headers["Authorization"] == "Bearer test-access")
        #expect(request.headers["X-Client-App"] == nil)
        #expect(request.headers["session-id"] == WireEpisode.cacheKey)
    }

    @Test(arguments: ["gpt-6.2-astra", local])
    func aGatewayThatIsNotRunningSaysHowItStarts(_ model: String) async throws {
        // Nothing listens on port 1, so the connection is refused at once.
        let provider = OpenAIResponsesProvider(
            access: .gateway(URL(string: "http://127.0.0.1:1")!), model: { model }, promptCacheKey: "k")
        let message = await Self.errorMessage(provider)
        #expect(message.hasPrefix("inference-gateway is not running on 127.0.0.1:1."))
        #expect(message.contains("dev.lubelski.inference-gateway"))
        #expect(message.contains("scripts/install.sh in ~/dev/inference-gateway"))
        #expect(InferenceGateway.notRunningMessage().hasPrefix("inference-gateway is not running on 127.0.0.1:47811."))
    }

    @Test func aGatewayWithNoSignInShowsItsOwnMessage() async throws {
        let body = #"{"error":{"type":"authentication_error","message":"Not signed in to OpenAI. Run `inference-gateway sign-in chatgpt` or `inference-gateway set-key openai`."}}"#
        let provider = OpenAIResponsesProvider(
            access: .gateway(InferenceGateway.baseURL), model: { "gpt-6.2-astra" }, promptCacheKey: "k",
            session: FixedReplyProtocol.session(status: 503, body: body))
        let message = await Self.errorMessage(provider)
        #expect(message == "inference-gateway: Not signed in to OpenAI. Run `inference-gateway sign-in chatgpt` or `inference-gateway set-key openai`.")
    }

    @Test func anErrorFromOpenAIPassesThroughTheGatewayUnchanged() async throws {
        let body = #"{"error":{"type":"server_error","message":"The server is overloaded."}}"#
        let provider = OpenAIResponsesProvider(
            access: .gateway(InferenceGateway.baseURL), model: { "gpt-6.2-astra" }, promptCacheKey: "k",
            session: FixedReplyProtocol.session(status: 503, body: body))
        #expect(await Self.errorMessage(provider) == "OpenAI API error (503): \(body)")
    }

    @Test func diagnosticsSayTheModelsGoThroughTheGateway() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func report(_ access: ModelAccess) -> String {
            DiagnosticsReport(
                build: BuildInfo(version: "0.1", build: "1", commit: "abc", signing: "Signed"),
                dataFolder: root, model: "gpt-6-luna", signIn: nil, instructions: "", tools: [], skills: [],
                threadFile: root.appending(path: "thread.jsonl"),
                usageLog: UsageLog(fileURL: root.appending(path: "usage.jsonl")), problems: [],
                secretStorage: SecretStorage.Status(location: .file, reason: .developmentBuild, migration: nil),
                modelAccess: access
            ).plainText()
        }
        let gateway = report(.gateway)
        #expect(gateway.contains("Models\n- Through inference-gateway at http://127.0.0.1:47811. This build has no sign-in of its own."))
        #expect(gateway.contains("- Other secrets, such as a Brave Search key, kept in: secrets.json in the data folder"))
        #expect(!gateway.contains("Sign-in\n"))
        let signIn = report(.signIn)
        #expect(signIn.contains("Sign-in\n- Not available"))
        #expect(!signIn.contains("inference-gateway"))
    }

    private static func loop(server: StubResponsesServer, model: String) throws -> AgentLoop {
        let provider = OpenAIResponsesProvider(
            access: .gateway(InferenceGateway.baseURL), model: { model }, promptCacheKey: WireEpisode.cacheKey,
            session: server.session(), timeZone: WireEpisode.utc)
        return AgentLoop(
            provider: provider, thread: try ThreadStore(fileURL: temporaryThreadFile()), tools: [RecordingTool()],
            instructionsForEpisode: { _ in WireEpisode.instructions }, usageLog: UsageLog(fileURL: temporaryThreadFile()))
    }

    private static func errorMessage(_ provider: OpenAIResponsesProvider) async -> String {
        do {
            for try await _ in provider.streamReply(to: ModelRequest(instructions: "x", entries: [], tools: [])) {}
            return "no error"
        } catch {
            return error.localizedDescription
        }
    }
}

/// Answers every request with one status and body, as the gateway does when it has no sign-in.
final class FixedReplyProtocol: URLProtocol, @unchecked Sendable {
    private static let statusHeader = "X-Fixed-Reply-Status"
    private static let bodyHeader = "X-Fixed-Reply-Body"

    static func session(status: Int, body: String) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixedReplyProtocol.self]
        configuration.httpAdditionalHeaders = [
            statusHeader: String(status), bodyHeader: Data(body.utf8).base64EncodedString(),
        ]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = request.value(forHTTPHeaderField: Self.statusHeader).flatMap(Int.init) ?? 500
        let body = request.value(forHTTPHeaderField: Self.bodyHeader).flatMap { Data(base64Encoded: $0) } ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
