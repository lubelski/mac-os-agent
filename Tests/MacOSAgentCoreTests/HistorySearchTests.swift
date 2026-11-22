import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct HistorySearchTests {
    /// A kept thread with an index, holding the legacy episodes plus a current one.
    private func history(index: Bool = true) async throws -> (ThreadStore, URL) {
        let file = try writeLegacyThread()
        let indexURL = file.deletingLastPathComponent().appending(path: "history-index.sqlite")
        let store = try ThreadStore(fileURL: file, searchIndexURL: index ? indexURL : nil)
        try await store.append(.episodeStart(.init(reason: .requested)))
        try await store.append(.userMessage(text: "find the dark mode thing from before"))
        if index { await store.waitForSearchIndex() }
        return (store, indexURL)
    }

    @Test func messagesRepliesAndCommandsAreFound() async throws {
        let (store, _) = try await history()
        #expect(await store.waitForSearchIndex())
        #expect(await store.search("eating disk").map(\.position) == [0])
        #expect(await store.search("Movies").map(\.position).contains(3))
        #expect(await store.search("du").map(\.position) == [1])
        // Stems and prefixes match: "Downloading" finds "Downloads".
        #expect(await store.search("downloading").map(\.position).contains(4))
        // Output is not searched.
        #expect(await store.search("exit status").isEmpty)
    }

    @Test func theEpisodeInViewIsLeftOut() async throws {
        let (store, _) = try await history()
        let current = try #require(await store.currentEpisode)
        let all = await store.search("dark mode")
        #expect(all.contains { $0.episode.id == current.id })
        let past = await store.search("dark mode", excludingEpisode: current.id)
        #expect(past.map(\.position) == [6, 7] || past.map(\.position) == [7, 6])
        #expect(past.allSatisfy { $0.episode.number == 2 })
    }

    @Test func withoutAnIndexSearchReadsTheEntries() async throws {
        let (store, _) = try await history(index: false)
        #expect(await !store.hasSearchIndex)
        #expect(await store.search("dark mode").map(\.position) == [11, 7, 6])
        #expect(await store.search("nothing like this").isEmpty)
    }

    @Test func theIndexCatchesUpAndRebuildsFromTheThread() async throws {
        let (store, indexURL) = try await history()
        let file = store.fileURL
        // Entries added while the index was not open are picked up on the next open.
        do {
            let unindexed = try ThreadStore(fileURL: file)
            try await unindexed.append(assistant("The wallpaper is a sunset now."))
        }
        let reopened = try ThreadStore(fileURL: file, searchIndexURL: indexURL)
        #expect(await reopened.waitForSearchIndex())
        #expect(await reopened.search("wallpaper").map(\.position) == [12])

        // An index that belongs to another thread is rebuilt.
        let other = try ThreadStore(fileURL: temporaryThreadFile(), searchIndexURL: indexURL)
        #expect(await other.waitForSearchIndex())
        try await other.append(.userMessage(text: "unrelated"))
        let rebuilt = try ThreadStore(fileURL: file, searchIndexURL: indexURL)
        #expect(await rebuilt.waitForSearchIndex())
        #expect(await rebuilt.search("unrelated").isEmpty)
        #expect(await rebuilt.search("wallpaper").map(\.position) == [12])

        // A deleted index is rebuilt too.
        try FileManager.default.removeItem(at: indexURL)
        let fresh = try ThreadStore(fileURL: file, searchIndexURL: indexURL)
        #expect(await fresh.waitForSearchIndex())
        #expect(await fresh.search("battery").map(\.position) == [8])
    }

    @Test func theSearchToolReportsDatedMatchesWithContext() async throws {
        let (store, _) = try await history()
        let tool = SearchHistoryTool(history: store, timeZone: TimeZone(identifier: "UTC")!)
        let current = await store.currentEpisode?.id
        let output = await tool.run(arguments: ["query": "Downloads", "limit": .null], context: ToolRunContext(callID: "c", episodeID: current, confirm: { _ in true }))
        #expect(output.hasPrefix("2 matches for \"Downloads\""))
        #expect(output.contains("Episode 1, 2026-11-18 17:41 GMT to 2026-11-18 17:55 GMT, 4 messages and 1 command."))
        #expect(output.contains("> [2026-11-18 17:55 GMT] person: and Downloads?"))
        #expect(output.contains("  [2026-11-18 17:41 GMT] you: Movies is the big one at 38 GB."))
        #expect(output.contains("> [2026-11-18 17:55 GMT] you: Downloads is 12 GB."))

        let none = await tool.run(arguments: ["query": "zebra", "limit": 3], context: ToolRunContext(callID: "c", confirm: { _ in true }))
        #expect(none == "Nothing in earlier episodes matches \"zebra\".")
        let empty = await tool.run(arguments: ["query": " ?! ", "limit": .null], context: ToolRunContext(callID: "c", confirm: { _ in true }))
        #expect(empty.hasPrefix("Error:"))
    }

    @Test func theReadToolPagesThroughAnEpisode() async throws {
        let (store, _) = try await history()
        let tool = ReadEpisodeTool(history: store, timeZone: TimeZone(identifier: "UTC")!)
        let context = ToolRunContext(callID: "c", confirm: { _ in true })
        let whole = await tool.run(arguments: ["episode": 1, "from_line": .null], context: context)
        #expect(whole == """
            Episode 1, 2026-11-18 17:41 GMT to 2026-11-18 17:55 GMT, 4 messages and 1 command.
            [2026-11-18 17:41 GMT] person: what's eating my disk space
            [2026-11-18 17:41 GMT] command: du -sh ~/Movies
            [2026-11-18 17:41 GMT] output:  38G\t/Users/owner/Movies / [exit status 0]
            [2026-11-18 17:41 GMT] you: Movies is the big one at 38 GB.
            [2026-11-18 17:55 GMT] person: and Downloads?
            [2026-11-18 17:55 GMT] you: Downloads is 12 GB.
            """)
        let rest = await tool.run(arguments: ["episode": 1, "from_line": 5], context: context)
        #expect(rest.hasSuffix("person: and Downloads?\n[2026-11-18 17:55 GMT] you: Downloads is 12 GB."))
        #expect(await tool.run(arguments: ["episode": 9, "from_line": .null], context: context)
            == "Error: there is no episode 9. Episodes are numbered 1 to 4.")
    }

    @Test func longEpisodesComeInPages() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        for index in 1...70 { try await store.append(.userMessage(text: "message \(index)")) }
        let tool = ReadEpisodeTool(history: store)
        let first = await tool.run(arguments: ["episode": 1, "from_line": .null], context: ToolRunContext(callID: "c", confirm: { _ in true }))
        #expect(first.hasSuffix("Lines 1 to 60 of 70. Call read_episode with from_line 61 for more."))
        let second = await tool.run(arguments: ["episode": 1, "from_line": 61], context: ToolRunContext(callID: "c", confirm: { _ in true }))
        #expect(second.hasSuffix("message 70"))
    }

    @Test func openingALargeThreadDoesNotWaitForTheIndex() async throws {
        let file = temporaryThreadFile()
        try writeLargeThread(count: 40_000, to: file)
        let indexURL = file.deletingLastPathComponent().appending(path: "history-index.sqlite")
        let clock = ContinuousClock()

        // Loading the thread alone is the floor. Opening with an index to build is about the same.
        var plain: ThreadStore?
        let loadOnly = try clock.measure { plain = try ThreadStore(fileURL: file) }
        var store: ThreadStore?
        let withIndex = try clock.measure { store = try ThreadStore(fileURL: file, searchIndexURL: indexURL) }
        let opened = try #require(store)
        #expect(await plain?.entries.count == 40_000)
        #expect(await opened.entries.count == 40_000)
        // It returned before the index was built, and took about as long as loading alone.
        #expect(await !opened.hasSearchIndex)
        #expect(withIndex < loadOnly * 2 + .milliseconds(100), "loading took \(loadOnly), with the index \(withIndex)")

        // Search works before the index is ready, by reading the entries.
        let early = await opened.search("report 39996")
        #expect(early.map(\.position) == [39_996])

        // Once it is ready, every match is found through it.
        #expect(await opened.waitForSearchIndex())
        let all = await opened.search("garden", limit: 20_000)
        #expect(all.count == 10_000)
        #expect(Set(all.map(\.position)) == Set(stride(from: 0, to: 40_000, by: 4)))
        #expect(await opened.search("report 39996").map(\.position) == [39_996])
    }

    @Test func anAppendDuringARebuildIsIndexedOnce() async throws {
        let file = temporaryThreadFile()
        try writeLargeThread(count: 40_000, to: file)
        let indexURL = file.deletingLastPathComponent().appending(path: "history-index.sqlite")
        let store = try ThreadStore(fileURL: file, searchIndexURL: indexURL)
        // The rebuild of 40,000 entries is still running when these arrive.
        #expect(await !store.hasSearchIndex)
        try await store.append(.userMessage(text: "the zucchini harvest"))
        try await store.append(assistant("Zucchini noted for the harvest."))
        #expect(await store.search("zucchini").map(\.position).sorted() == [40_000, 40_001])

        #expect(await store.waitForSearchIndex())
        #expect(await store.search("zucchini").map(\.position).sorted() == [40_000, 40_001])
        try await store.append(.userMessage(text: "one more zucchini"))
        #expect(await store.search("zucchini", limit: 10).map(\.position).sorted() == [40_000, 40_001, 40_002])

        // The file holds each entry once and matches the thread, so the next open only checks it.
        let reopened = try ThreadStore(fileURL: file, searchIndexURL: indexURL)
        #expect(await reopened.waitForSearchIndex())
        #expect(await reopened.search("zucchini", limit: 10).map(\.position).sorted() == [40_000, 40_001, 40_002])
        #expect(await reopened.search("garden", limit: 20_000).count == 10_000)
    }

    @Test func searchStaysFastOnALongThread() async throws {
        let file = temporaryThreadFile()
        let indexURL = file.deletingLastPathComponent().appending(path: "history-index.sqlite")
        let store = try ThreadStore(fileURL: file, searchIndexURL: indexURL)
        for index in 0..<3_000 {
            try await store.append(.userMessage(text: "open the report number \(index) in Preview"), date: Date().addingTimeInterval(Double(index) * 60))
        }
        let clock = ContinuousClock()
        let elapsed = await clock.measure { _ = await store.search("report 2999") }
        #expect(elapsed < .milliseconds(200))
        #expect(await store.search("2999").first?.position == 2_999)
    }
}

@Suite struct EpisodeListTests {
    @Test func theListIsNewestFirstAndSearchGroupsByEpisode() async throws {
        let store = try ThreadStore(fileURL: try writeLegacyThread())
        let contents = await store.contents
        #expect(EpisodeListItem.all(in: contents).map(\.episode.number) == [3, 2, 1])
        let found = EpisodeListItem.matching(await store.search("downloads", limit: 50))
        #expect(found.map(\.episode.number) == [1])
        #expect(found[0].match == "and Downloads?" || found[0].match == "Downloads is 12 GB.")
    }

    @Test func linesShowMessagesCommandsAndReplies() async throws {
        let store = try ThreadStore(fileURL: try writeLegacyThread())
        let contents = await store.contents
        let lines = EpisodeLine.lines(of: try #require(contents.episode(numbered: 1)), in: contents)
        #expect(lines.map(\.kind) == [.owner, .command(.succeeded), .agent, .owner, .agent])
        // History shows a command as the panel's row does.
        #expect(lines[1].text == "Bash du -sh ~/Movies")
    }
}
