import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// Replies "ok" to every request and records what it was sent. With `holds` set, each reply
/// waits until the task is cancelled, as a slow request would.
final class EchoProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []
    var holds = false

    var requests: [ModelRequest] { lock.withLock { recorded } }

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        lock.withLock { recorded.append(request) }
        let holds = holds
        return AsyncThrowingStream { continuation in
            let task = Task {
                if holds {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    continuation.finish(throwing: CancellationError())
                    return
                }
                continuation.yield(.item(.assistantMessage(.init(text: "ok", provider: "test", model: "test-model"))))
                continuation.yield(.usage(TokenUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 1), provider: "test", model: "test-model"))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The main panel session's episodes, against a kept thread in a temporary folder.
@MainActor
@Suite(.serialized) struct EpisodeSessionTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let provider = EchoProvider()

    private func makeSession(timeout: TimeInterval = 1800) throws -> (AgentSession, ThreadStore) {
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"), searchIndexURL: folder.appending(path: "history-index.sqlite"))
        let provider = provider
        let loop = AgentLoop(provider: provider, thread: thread, tools: [], episodeTimeout: { timeout })
        let session = AgentSession(loop: loop, authenticator: nil, episodeTimeout: { timeout }, signedIn: true)
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
        let rowsBefore = session.transcript.rows.count

        await send("/new", in: session)
        #expect(session.draft.isEmpty)
        #expect(session.transcript.hasPendingEpisode)
        #expect(session.transcript.currentEpisodeStartRow == rowsBefore)
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
        #expect(!session.transcript.hasPendingEpisode)

        session.clock = { Date().addingTimeInterval(31 * 60) }
        session.panelDidAppear()
        #expect(session.transcript.hasPendingEpisode)
    }

    @Test func slashIncognitoOpensTheWindowAndLeavesThePanelAsItWas() async throws {
        let (session, thread) = try makeSession()
        await send("kept message", in: session)
        let rows = session.transcript.rows
        var opened = 0
        session.openIncognito = { opened += 1 }

        await send("/incognito", in: session)
        #expect(opened == 1)
        #expect(session.kind == .kept)
        #expect(session.transcript.rows == rows)
        #expect(!session.transcript.hasPendingEpisode)
        #expect(session.draft.isEmpty)
        #expect(await thread.entries.count == 2)
        #expect(provider.requests.count == 1)
    }
}
