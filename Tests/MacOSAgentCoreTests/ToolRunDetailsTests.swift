import Foundation
import Testing
@testable import MacOSAgentCore

/// A thread written before results had run details, with a shell call, a declined one, and a
/// native tool call in it. It must load unchanged, and the file must never be rewritten.
let threadBeforeRunDetails = """
    {"date":"2026-11-20T09:00:00Z","id":"00000000-0000-0000-0000-0000000000B1","item":{"type":"user_message","value":{"text":"what's in Downloads"}}}
    {"date":"2026-11-20T09:00:02Z","id":"00000000-0000-0000-0000-0000000000B2","item":{"type":"tool_call","value":{"arguments":"{\\"command\\":\\"ls ~/Downloads\\",\\"destructive\\":false}","callID":"call_ls","model":"gpt-6-luna","name":"run_shell_command","provider":"openai","providerID":"fc_1"}}}
    {"date":"2026-11-20T09:00:03Z","id":"00000000-0000-0000-0000-0000000000B3","item":{"type":"tool_result","value":{"callID":"call_ls","output":"a.pdf\\nb.zip\\n[exit status 0]"}}}
    {"date":"2026-11-20T09:00:05Z","id":"00000000-0000-0000-0000-0000000000B4","item":{"type":"tool_call","value":{"arguments":"{\\"command\\":\\"rm ~/Downloads/b.zip\\",\\"destructive\\":true}","callID":"call_rm","model":"gpt-6-luna","name":"run_shell_command","provider":"openai","providerID":"fc_2"}}}
    {"date":"2026-11-20T09:00:09Z","id":"00000000-0000-0000-0000-0000000000B5","item":{"type":"tool_result","value":{"callID":"call_rm","output":"The person declined to run this command. It did not run."}}}
    {"date":"2026-11-20T09:00:10Z","id":"00000000-0000-0000-0000-0000000000B6","item":{"type":"tool_call","value":{"arguments":"{\\"query\\":\\"safari\\"}","callID":"call_apps","model":"gpt-6-luna","name":"search_applications","provider":"openai","providerID":"fc_3"}}}
    {"date":"2026-11-20T09:00:11Z","id":"00000000-0000-0000-0000-0000000000B7","item":{"type":"tool_result","value":{"callID":"call_apps","output":"Best match first, as name | bundle identifier | path:\\nSafari | com.apple.Safari | /Applications/Safari.app"}}}
    {"date":"2026-11-20T09:00:12Z","id":"00000000-0000-0000-0000-0000000000B8","item":{"type":"assistant_message","value":{"model":"gpt-6-luna","provider":"openai","text":"Two files. I left b.zip alone."}}}

    """

@Suite struct ToolRunDetailsTests {
    private func writeOldThread() throws -> URL {
        let file = temporaryThreadFile()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(threadBeforeRunDetails.utf8).write(to: file)
        return file
    }

    private func result(_ store: ThreadStore, _ callID: String) async -> ThreadItem.ToolResult? {
        await store.entries.lazy.compactMap { entry -> ThreadItem.ToolResult? in
            if case .toolResult(let result) = entry.item, result.callID == callID { return result }
            return nil
        }.first
    }

    // MARK: - Old threads

    @Test func aThreadFromBeforeRunDetailsLoadsUnchangedAndIsNeverRewritten() async throws {
        let file = try writeOldThread()
        let before = try Data(contentsOf: file)
        let store = try ThreadStore(fileURL: file)
        #expect(await store.unreadableLineCount == 0)
        #expect(await store.entries.count == 8)
        #expect(await result(store, "call_ls") == .init(callID: "call_ls", output: "a.pdf\nb.zip\n[exit status 0]"))
        #expect(await result(store, "call_ls")?.details == nil)
        #expect(try Data(contentsOf: file) == before)

        // A new result with details goes on the end, and the old lines stay byte for byte.
        try await store.append(.toolResult(.init(callID: "new", output: "x", details: ToolRunDetails(seconds: 0.5))))
        let after = try Data(contentsOf: file)
        #expect(after.prefix(before.count) == before)
        let reloaded = try ThreadStore(fileURL: file)
        #expect(await reloaded.entries.count == 9)
        #expect(await result(reloaded, "new")?.details?.seconds == 0.5)
    }

    @Test func anOldThreadShowsWhatItCanInTheInspector() throws {
        let entries = try JSONDecoder.thread.decodeLines(threadBeforeRunDetails)
        let transcript = Transcript(entries: entries)

        let listing = try #require(transcript.toolCall("call_ls"))
        #expect(listing.status == .succeeded)
        #expect(listing.exitStatus == 0)
        #expect(listing.command == "ls ~/Downloads")
        #expect(listing.goAheadText == nil)
        // Without stored details, the time comes from the thread's own dates.
        #expect(listing.started == ISO8601DateFormatter().date(from: "2026-11-20T09:00:02Z"))
        #expect(listing.seconds(now: Date()) == 1)

        let removal = try #require(transcript.toolCall("call_rm"))
        #expect(removal.status == .declined)
        #expect(removal.goAheadText == "Asked, declined")
        #expect(removal.exitStatus == nil)

        let apps = try #require(transcript.toolCall("call_apps"))
        #expect(apps.status == .succeeded)
        #expect(apps.name == "search_applications")
        let labels = apps.metadata(now: Date(), timeText: { _ in "then" }).map(\.label)
        #expect(labels == ["Tool", "Status", "Started", "Took", "Output", "Call ID"])
    }

    // MARK: - Encoding

    @Test func aResultWithoutDetailsEncodesExactlyAsBefore() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let item = ThreadItem.toolResult(.init(callID: "c", output: "o"))
        let text = String(decoding: try encoder.encode(item), as: UTF8.self)
        #expect(text == #"{"type":"tool_result","value":{"callID":"c","output":"o"}}"#)
    }

    @Test func detailsRoundTrip() throws {
        let details = ToolRunDetails(
            started: Date(timeIntervalSince1970: 1_800_000_000), seconds: 1.25, waitedSeconds: 0.75, goAhead: .approved,
            source: "Built In", exitStatus: 3, timedOut: true, stopped: nil, fullCharacters: 40_000)
        let item = ThreadItem.toolResult(.init(callID: "c", output: "o", details: details))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ThreadItem.self, from: encoder.encode(item)) == item)
    }

    @Test func theModelNeverSeesTheDetails() {
        let call = ThreadEntry(item: toolCall("c", name: "record", arguments: [:]))
        let plain = ThreadEntry(item: .toolResult(.init(callID: "c", output: "done")))
        var detailed = plain
        detailed.item = .toolResult(.init(callID: "c", output: "done", details: ToolRunDetails(
            started: Date(), seconds: 2, goAhead: .declined, source: "Built In", exitStatus: 1, fullCharacters: 99)))
        let without = OpenAIResponses.input(for: ModelRequest(instructions: "i", entries: [call, plain], tools: []), model: "test-model")
        let with = OpenAIResponses.input(for: ModelRequest(instructions: "i", entries: [call, detailed], tools: []), model: "test-model")
        #expect(with == without)
    }

    // MARK: - What the loop stores

    @Test func theLoopStoresTimingSourceAndExitStatusForAShellCommand() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [
            [.item(toolCall("s", name: ShellCommandTool.name, arguments: ["command": "echo hi; exit 4", "destructive": false]))],
            [.item(assistant("ok"))],
        ])
        let before = Date()
        let loop = AgentLoop(provider: provider, thread: store, tools: [ShellCommandTool()])
        try await loop.run("go", onEvent: { _ in }, confirm: { _ in true })

        let details = try #require(await result(store, "s")?.details)
        #expect(details.exitStatus == 4)
        #expect(details.source == "Built In")
        #expect(details.goAhead == nil)
        #expect(details.fullCharacters == nil)
        #expect(details.timedOut == nil)
        #expect((details.seconds ?? -1) >= 0)
        #expect((details.started ?? .distantPast) >= before.addingTimeInterval(-1))
        // The second request carries the result as the model always saw it.
        let sent = provider.requests[1].entries.compactMap { entry -> String? in
            if case .toolResult(let result) = entry.item { return result.output }
            return nil
        }
        #expect(sent == ["hi\n\n[exit status 4]"])
    }

    @Test func theLoopNotesTheGoAheadAndHowLongItTook() async throws {
        for answer in [true, false] {
            let store = try ThreadStore(fileURL: temporaryThreadFile())
            let provider = FakeProvider(replies: [
                [.item(toolCall("s", name: ShellCommandTool.name, arguments: ["command": "true", "destructive": true]))],
                [.item(assistant("ok"))],
            ])
            let loop = AgentLoop(provider: provider, thread: store, tools: [ShellCommandTool()])
            try await loop.run("go", onEvent: { _ in }, confirm: { _ in
                try? await Task.sleep(for: .milliseconds(50))
                return answer
            })
            let details = try #require(await result(store, "s")?.details)
            #expect(details.goAhead == (answer ? .approved : .declined))
            #expect((details.waitedSeconds ?? 0) >= 0.04)
            #expect(details.exitStatus == (answer ? 0 : nil))
        }
    }

    @Test func theShellToolNotesShorteningAndTheTimeLimit() async {
        let report = ToolRunReport()
        let tool = ShellCommandTool(timeout: .seconds(20), outputLimit: 100)
        let output = await tool.run(
            arguments: ["command": "printf 'x%.0s' {1..500}", "destructive": false],
            context: ToolRunContext(callID: "c", report: report, confirm: { _ in true }))
        #expect(report.details.fullCharacters == 500)
        #expect(ToolOutputTrailer(output).omittedCharacters == 400)

        let slow = ToolRunReport()
        let timed = await ShellCommandTool(timeout: .milliseconds(200), killGracePeriod: .milliseconds(200)).run(
            arguments: ["command": "sleep 5", "destructive": false],
            context: ToolRunContext(callID: "c", report: slow, confirm: { _ in true }))
        #expect(slow.details.timedOut == true)
        #expect(ToolOutputTrailer(timed).timeLimitSeconds == 0)
    }
}

extension JSONDecoder {
    static var thread: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func decodeLines(_ text: String) throws -> [ThreadEntry] {
        try text.split(separator: "\n").map { try decode(ThreadEntry.self, from: Data($0.utf8)) }
    }
}
