import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// Replies "ok" to every request and records what it was sent.
private final class EchoProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []

    var requests: [ModelRequest] { lock.withLock { recorded } }

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        lock.withLock { recorded.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.item(.assistantMessage(.init(text: "ok", provider: "test", model: "test-model"))))
            continuation.finish()
        }
    }
}

/// The session's episode and incognito behavior, against a kept thread in a temporary folder.
@MainActor
@Suite(.serialized) struct EpisodeSessionTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let provider = EchoProvider()

    private func makeSession(timeout: TimeInterval = 1800) throws -> (AgentSession, ThreadStore) {
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"), searchIndexURL: folder.appending(path: "history-index.sqlite"))
        let provider = provider
        let loop = AgentLoop(provider: provider, thread: thread, tools: [], episodeTimeout: { timeout })
        let session = AgentSession(
            loop: loop, authenticator: nil,
            makeIncognitoLoop: { AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { timeout }) },
            episodeTimeout: { timeout }, signedIn: true)
        return (session, thread)
    }

    private func send(_ text: String, in session: AgentSession) async {
        session.draft = text
        session.submit()
        await session.waitUntilIdle()
    }

    private func threadBytes() throws -> Data {
        try Data(contentsOf: folder.appending(path: "thread.jsonl"))
    }

    @Test func slashNewStartsAFreshPageAndTheNextMessageANewEpisode() async throws {
        let (session, thread) = try makeSession()
        await send("first", in: session)
        let rowsBefore = session.visibleTranscript.rows.count

        await send("/new", in: session)
        #expect(session.draft.isEmpty)
        #expect(session.visibleTranscript.hasPendingEpisode)
        #expect(session.visibleTranscript.currentEpisodeStartRow == rowsBefore)
        #expect(await thread.entries.count == 2)

        await send("second", in: session)
        #expect(await thread.episodes.count == 2)
        #expect(provider.requests.last?.entries.map(\.item) == [.userMessage(text: "second")])
        // The command itself was never written or sent.
        #expect(await !thread.entries.contains { $0.item == .userMessage(text: "/new") })
    }

    @Test func anUnknownSlashIsSentAsAMessage() async throws {
        let (session, thread) = try makeSession()
        await send("/usr/local is full", in: session)
        #expect(await thread.entries.first?.item == .userMessage(text: "/usr/local is full"))
    }

    @Test func summoningAfterTheTimeoutOpensFresh() async throws {
        let (session, _) = try makeSession()
        await send("first", in: session)
        session.panelDidAppear()
        #expect(!session.visibleTranscript.hasPendingEpisode)

        session.clock = { Date().addingTimeInterval(31 * 60) }
        session.panelDidAppear()
        #expect(session.visibleTranscript.hasPendingEpisode)
    }

    @Test func incognitoLeavesNoTraceAndEndsWithANewPage() async throws {
        let (session, thread) = try makeSession()
        await send("kept message", in: session)
        let before = try threadBytes()
        let indexBefore = try Data(contentsOf: folder.appending(path: "history-index.sqlite"))

        await send("/incognito", in: session)
        #expect(session.isIncognito)
        await send("a secret plan", in: session)
        // It started fresh: the model saw only the incognito message.
        #expect(provider.requests.last?.entries.map(\.item) == [.userMessage(text: "a secret plan")])
        #expect(session.visibleTranscript.rows.contains { $0.kind == .assistant("ok") })
        #expect(!session.transcript.rows.contains { if case .user(let text, _, _) = $0.kind { text == "a secret plan" } else { false } })

        await send("/new", in: session)
        #expect(!session.isIncognito)
        #expect(session.incognitoTranscript == nil)
        #expect(session.transcript.hasPendingEpisode)

        #expect(try threadBytes() == before)
        #expect(try Data(contentsOf: folder.appending(path: "history-index.sqlite")) == indexBefore)
        #expect(await thread.search("secret").isEmpty)
    }

    @Test func incognitoEndsByTheTimeoutWithoutSendingIntoTheKeptThread() async throws {
        let (session, thread) = try makeSession()
        await send("/incognito", in: session)
        #expect(session.isIncognito)
        session.clock = { Date().addingTimeInterval(31 * 60) }

        await send("still secret", in: session)
        #expect(!session.isIncognito)
        #expect(session.draft == "still secret")
        #expect(await thread.entries.isEmpty)
        #expect(session.transcript.rows.contains { if case .notice(let text) = $0.kind { text.hasPrefix("Incognito ended after 30 minutes") } else { false } })
    }

    @Test func slashIncognitoTogglesIt() async throws {
        let (session, _) = try makeSession()
        await send("/incognito", in: session)
        #expect(session.isIncognito)
        await send("/incognito", in: session)
        #expect(!session.isIncognito)
    }
}
