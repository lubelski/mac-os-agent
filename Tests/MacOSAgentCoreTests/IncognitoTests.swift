import Foundation
import Testing
@testable import MacOSAgentCore

/// Every file in a flat folder with its bytes, to show that nothing changed.
func snapshot(of folder: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        files[url.lastPathComponent] = try Data(contentsOf: url)
    }
    return files
}

@Suite struct IncognitoTests {
    @Test func anIncognitoEpisodeWritesNothingAndCanStillSearch() async throws {
        // The kept thread, its index, and the usage log, as in Application Support.
        let file = try writeLegacyThread()
        let folder = file.deletingLastPathComponent()
        let history = try ThreadStore(fileURL: file, searchIndexURL: folder.appending(path: "history-index.sqlite"))
        let usageLog = UsageLog(fileURL: folder.appending(path: "usage.jsonl"))
        let before = try snapshot(of: folder)

        let incognito = InMemoryThreadStore()
        let secret = "the surprise party is on saturday"
        let provider = FakeProvider(replies: [
            [.item(toolCall("s", name: SearchHistoryTool.name, arguments: ["query": "dark mode", "limit": .null])),
             .item(toolCall("r", name: "record", arguments: ["note": .string(secret)])),
             .usage(TokenUsage(inputTokens: 100, cachedInputTokens: 0, outputTokens: 10), provider: "test", model: "test-model")],
            [.item(assistant("Noted, and dark mode came up on Nov 18."))],
        ])
        let instructions = AgentInstructions.assemble(editable: "", skills: [], skillsFolder: folder, incognito: true)
        let loop = AgentLoop(
            provider: provider, thread: incognito,
            tools: [SearchHistoryTool(history: history), RecordingTool()],
            instructions: { instructions },
            usageLog: usageLog)

        try await loop.run(secret, onEvent: { _ in }, confirm: { _ in true })

        // The episode is all in memory.
        let items = await incognito.entries.map(\.item)
        #expect(items.first == .userMessage(text: secret))
        #expect(items.count == 6)
        // The search found the kept past, with nothing left out.
        guard case .toolResult(let found) = items[3] else {
            Issue.record("expected the search result, got \(items[3])")
            return
        }
        #expect(found.output.contains("dark mode"))

        // On disk, only the usage log changed, and it holds counts without content.
        var after = try snapshot(of: folder)
        let removed = after.removeValue(forKey: "usage.jsonl")
        let usage = try #require(removed)
        #expect(before["usage.jsonl"] == nil)
        #expect(!String(decoding: usage, as: UTF8.self).contains("surprise"))
        #expect(after == before)
        #expect(await history.entries.count == 10)
        #expect(await history.search("surprise party").isEmpty)
        // Nothing else in the whole folder mentions it either.
        for (_, data) in after { #expect(data.range(of: Data("surprise".utf8)) == nil) }
    }

    @Test func theInMemoryStoreFollowsTheSameEpisodeRules() async throws {
        let store = InMemoryThreadStore()
        let provider = FakeProvider(replies: [[.item(assistant("one"))], [.item(assistant("two"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [])
        try await loop.run("first", onEvent: { _ in }, confirm: { _ in true })
        try await loop.run("second", onEvent: { _ in }, confirm: { _ in true })
        #expect(provider.requests[1].entries.map(\.item) == [.userMessage(text: "first"), assistant("one"), .userMessage(text: "second")])
        #expect(await store.episodes.count == 1)
    }
}
