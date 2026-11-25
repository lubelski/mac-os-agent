import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// The task links row's list in the main panel's session, against a kept thread in a
/// temporary folder.
@MainActor
@Suite(.serialized) struct TaskLinksSessionTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var store: TaskLinkStore { TaskLinkStore(fileURL: folder.appending(path: "task-links.json")) }

    private func makeSession() throws -> (AgentSession, ThreadStore) {
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"), searchIndexURL: folder.appending(path: "history-index.sqlite"))
        let loop = AgentLoop(provider: EchoProvider(), thread: thread, tools: [])
        let session = AgentSession(loop: loop, authenticator: nil, signedIn: true)
        session.taskLinkStore = store
        return (session, thread)
    }

    private func settle(_ session: AgentSession, until condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theSessionShowsTheEpisodesLinksAfterALaunchAndNoneOnAFreshPage() async throws {
        let (first, thread) = try makeSession()
        first.draft = "hello"
        first.submit()
        await first.waitUntilIdle()
        let episode = await thread.currentEpisode?.id
        try store.set([TaskLink(label: "Spec", url: "https://example.com/spec")], episode: episode)

        // A relaunch: a new session over the same folder.
        let (session, _) = try makeSession()
        await session.start()
        await settle(session) { !session.taskLinks.isEmpty }
        #expect(session.taskLinks.map(\.label) == ["Spec"])

        session.perform(.new)
        #expect(session.taskLinks == [])

        session.clearTaskLinks()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func withoutAStoreTheRowStaysEmpty() async throws {
        let (session, thread) = try makeSession()
        session.taskLinkStore = nil
        try store.set([TaskLink(label: "Spec", url: "https://example.com/spec")], episode: await thread.currentEpisode?.id)
        await session.start()
        session.reloadTaskLinks()
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.taskLinks == [])
    }
}
