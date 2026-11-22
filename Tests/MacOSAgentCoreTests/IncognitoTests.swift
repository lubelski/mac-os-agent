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
    private static let maps = InstalledApplication(
        name: "Maps", bundleIdentifier: "com.apple.Maps",
        url: URL(filePath: "/System/Applications/Maps.app", directoryHint: .isDirectory))

    @Test func theIncognitoToolListIsExactlyTheThreeApplicationTools() {
        let names = BuiltInTools.makeIncognito(applicationWorkspace: FakeApplicationWorkspace(installed: [])).map(\.definition.name)
        #expect(names == ["search_applications", "open_application", "list_running_applications"])
        #expect(names == BuiltInTools.incognitoNames)
        // The same definitions as the main panel's, so each reads the same wherever it is sent.
        let main = BuiltInTools.make(applicationWorkspace: FakeApplicationWorkspace(installed: []), system: FakeSystemControl())
        let shared = main.filter { names.contains($0.definition.name) }.map(\.definition)
        #expect(shared == BuiltInTools.makeIncognito(applicationWorkspace: FakeApplicationWorkspace(installed: [])).map(\.definition))
    }

    @Test func anIncognitoConversationWritesNothingAndCannotReachTheHistory() async throws {
        // The kept thread, its index, and the usage log, as in Application Support.
        let file = try writeLegacyThread()
        let folder = file.deletingLastPathComponent()
        let history = try ThreadStore(fileURL: file, searchIndexURL: folder.appending(path: "history-index.sqlite"))
        let usageLog = UsageLog(fileURL: folder.appending(path: "usage.jsonl"))
        let before = try snapshot(of: folder)

        let incognito = InMemoryThreadStore()
        let secret = "the surprise party is on saturday"
        let workspace = FakeApplicationWorkspace(installed: [Self.maps])
        let provider = FakeProvider(replies: [
            [.item(toolCall("s", name: SearchHistoryTool.name, arguments: ["query": "dark mode", "limit": .null])),
             .item(toolCall("r", name: ShellCommandTool.name, arguments: ["command": .string("echo '\(secret)' > ~/note.txt"), "destructive": false])),
             .item(toolCall("o", name: OpenApplicationTool.name, arguments: ["bundle_identifier_or_path": "com.apple.Maps"])),
             .usage(TokenUsage(inputTokens: 100, cachedInputTokens: 0, outputTokens: 10), provider: "test", model: "test-model")],
            [.item(assistant("Maps is open. I cannot search earlier conversations from here."))],
        ])
        let instructions = AgentInstructions.assembleIncognito(editable: "")
        let loop = AgentLoop(
            provider: provider, thread: incognito,
            tools: BuiltInTools.makeIncognito(applicationWorkspace: workspace),
            instructions: { instructions },
            usageLog: usageLog)

        try await loop.run(secret, onEvent: { _ in }, confirm: { _ in
            Issue.record("the incognito tools never ask")
            return false
        })

        // The model was sent the three application tools and the incognito instructions.
        #expect(provider.requests.first?.tools.map(\.name) == BuiltInTools.incognitoNames)
        #expect(provider.requests.first?.instructions == AgentInstructions.incognitoFixed)
        // The episode is all in memory. History search and the shell are not there to call.
        let results = await incognito.entries.compactMap { entry -> ThreadItem.ToolResult? in
            if case .toolResult(let result) = entry.item { return result }
            return nil
        }
        #expect(results.map(\.callID) == ["s", "r", "o"])
        #expect(results[0].output == "Error: there is no tool named search_history.")
        #expect(results[1].output == "Error: there is no tool named run_shell_command.")
        #expect(results[2].output.hasPrefix("Opened Maps (com.apple.Maps)."))
        #expect(workspace.opened == [Self.maps.url])

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
