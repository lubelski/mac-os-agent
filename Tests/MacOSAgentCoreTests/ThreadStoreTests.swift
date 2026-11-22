import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct ThreadStoreTests {
    @Test func entriesSurviveAReload() async throws {
        let file = temporaryThreadFile()
        let items: [ThreadItem] = [
            .userMessage(text: "change the wallpaper"),
            .providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: [
                "type": "reasoning", "id": "rs_1", "encrypted_content": "abc", "summary": [],
            ])),
            toolCall("call_1", name: "run_shell_command", arguments: ["command": "ls", "destructive": false]),
            .toolResult(.init(callID: "call_1", output: "a\nb\n[exit status 0]")),
            .assistantMessage(.init(text: "Done", provider: "openai", model: "gpt-6-luna", providerID: "msg_1", providerData: ["phase": "final_answer"])),
        ]
        do {
            let store = try ThreadStore(fileURL: file)
            for item in items { try await store.append(item) }
        }
        let reloaded = try ThreadStore(fileURL: file)
        #expect(await reloaded.entries.map(\.item) == items)
        #expect(await reloaded.unreadableLineCount == 0)
    }

    @Test func eachEntryIsOneJSONLine() async throws {
        let file = temporaryThreadFile()
        let store = try ThreadStore(fileURL: file)
        try await store.append(.userMessage(text: "line one\nline two"))
        try await store.append(assistant("ok"))

        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(text.hasSuffix("\n"))
        let first = try #require(JSONValue.parse(String(lines[0])))
        #expect(first["item"]?["type"] == "user_message")
        #expect(first["item"]?["value"]?["text"] == "line one\nline two")
    }

    @Test func appendingNeverRewritesEarlierBytes() async throws {
        let file = temporaryThreadFile()
        let store = try ThreadStore(fileURL: file)
        try await store.append(.userMessage(text: "first"))
        let before = try Data(contentsOf: file)
        try await store.append(assistant("second"))
        let after = try Data(contentsOf: file)
        #expect(after.prefix(before.count) == before)
    }

    @Test func aCutOffLastLineIsSkippedAndTheNextEntryStartsOnItsOwnLine() async throws {
        let file = temporaryThreadFile()
        do {
            let store = try ThreadStore(fileURL: file)
            try await store.append(.userMessage(text: "kept"))
        }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"date":"2026-11-21T10:00:00Z","id":"#.utf8))
        try handle.close()

        let store = try ThreadStore(fileURL: file)
        #expect(await store.entries.map(\.item) == [.userMessage(text: "kept")])
        #expect(await store.unreadableLineCount == 1)

        try await store.append(.userMessage(text: "after the crash"))
        let reloaded = try ThreadStore(fileURL: file)
        #expect(await reloaded.entries.map(\.item) == [.userMessage(text: "kept"), .userMessage(text: "after the crash")])
    }

    @Test func unansweredCallsAreFound() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        try await store.append(toolCall("a", name: "t", arguments: [:]))
        try await store.append(toolCall("b", name: "t", arguments: [:]))
        try await store.append(.toolResult(.init(callID: "a", output: "x")))
        #expect(await store.unansweredToolCalls().map(\.callID) == ["b"])
    }

    @Test func theThreadLivesInApplicationSupport() {
        #expect(AgentPaths.threadFile.path.hasSuffix("Library/Application Support/mac-os-agent/thread.jsonl"))
    }

    @Test func theInstallationIDIsKept() throws {
        let file = temporaryThreadFile().deletingLastPathComponent().appending(path: "installation-id")
        let first = AgentPaths.installationID(file: file)
        #expect(AgentPaths.installationID(file: file) == first)
    }
}
