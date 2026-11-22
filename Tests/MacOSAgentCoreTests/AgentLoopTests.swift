import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct AgentLoopTests {
    /// The items without the inspector's run details, which hold timings that differ every run.
    /// The tests in `ToolRunDetailsTests` check those.
    private func items(_ store: ThreadStore) async -> [ThreadItem] {
        await store.entries.map(\.item).map { item in
            guard case .toolResult(var result) = item else { return item }
            result.details = nil
            return .toolResult(result)
        }
    }

    @Test func plainReplyEndsTheLoop() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [[.textDelta("Hel"), .textDelta("lo"), .item(assistant("Hello"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [RecordingTool()])
        let log = EventLog()

        try await loop.run("hi", onEvent: { log.record($0) }, confirm: { _ in true })

        #expect(await items(store) == [.userMessage(text: "hi"), assistant("Hello")])
        #expect(provider.requests.count == 1)
        #expect(provider.requests[0].tools.map(\.name) == ["record"])
        #expect(log.events.contains(.textDelta("Hel")))
    }

    @Test func toolCallsRunAndTheirResultsGoBackToTheModel() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [
            [.toolCallStarted(callID: "a", name: "record"), .item(toolCall("a", name: "record", arguments: ["x": 1]))],
            [.item(assistant("All done"))],
        ])
        let tool = RecordingTool(result: "recorded")
        let loop = AgentLoop(provider: provider, thread: store, tools: [tool])
        let log = EventLog()

        try await loop.run("do it", onEvent: { log.record($0) }, confirm: { _ in true })

        #expect(tool.received == [["x": 1]])
        #expect(await items(store) == [
            .userMessage(text: "do it"),
            toolCall("a", name: "record", arguments: ["x": 1]),
            .toolResult(.init(callID: "a", output: "recorded")),
            assistant("All done"),
        ])
        #expect(log.events.contains(.toolRunning(callID: "a", summary: "record")))
        #expect(log.events.contains(.toolFinished(callID: "a")))

        // The second request starts with exactly the first one's entries: the prefix never changes.
        let first = provider.requests[0].entries
        let second = provider.requests[1].entries
        #expect(Array(second.prefix(first.count)) == first)
        #expect(second.count == 3)
    }

    @Test func everyRunAppendsToTheSameThread() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [[.item(assistant("one"))], [.item(assistant("two"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [])

        try await loop.run("first", onEvent: { _ in }, confirm: { _ in true })
        try await loop.run("second", onEvent: { _ in }, confirm: { _ in true })

        #expect(provider.requests[1].entries.map(\.item) == [
            .userMessage(text: "first"), assistant("one"), .userMessage(text: "second"),
        ])
        #expect(provider.requests[0].instructions == provider.requests[1].instructions)
    }

    @Test func unknownToolsAndBadArgumentsBecomeErrorResults() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        var badArguments = toolCall("b", name: "record", arguments: [:])
        if case .toolCall(var call) = badArguments {
            call.arguments = "not json"
            badArguments = .toolCall(call)
        }
        let provider = FakeProvider(replies: [
            [.item(toolCall("a", name: "missing", arguments: [:])), .item(badArguments)],
            [.item(assistant("ok"))],
        ])
        let tool = RecordingTool()
        let loop = AgentLoop(provider: provider, thread: store, tools: [tool])

        try await loop.run("go", onEvent: { _ in }, confirm: { _ in true })

        let results = await items(store).compactMap { item -> ThreadItem.ToolResult? in
            if case .toolResult(let result) = item { return result }
            return nil
        }
        #expect(results.map(\.callID) == ["a", "b"])
        #expect(results[0].output.contains("no tool named missing"))
        #expect(results[1].output.contains("not a JSON object"))
        #expect(tool.received.isEmpty)
    }

    @Test func aCallLeftWithoutAResultIsAnsweredOnTheNextRun() async throws {
        let file = temporaryThreadFile()
        do {
            let store = try ThreadStore(fileURL: file)
            try await store.append(.userMessage(text: "earlier"))
            try await store.append(toolCall("lost", name: "record", arguments: [:]))
        }
        let store = try ThreadStore(fileURL: file)
        let provider = FakeProvider(replies: [[.item(assistant("ok"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [RecordingTool()])

        try await loop.run("again", onEvent: { _ in }, confirm: { _ in true })

        let sent = provider.requests[0].entries.map(\.item)
        #expect(sent.count == 4)
        guard case .toolResult(let result) = sent[2] else {
            Issue.record("expected a tool result, got \(sent[2])")
            return
        }
        #expect(result.callID == "lost")
        #expect(sent[3] == .userMessage(text: "again"))
    }

    @Test func stoppingTheTaskThrowsCancellation() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [[.item(assistant("too late"))]])
        provider.delay = .seconds(30)
        let loop = AgentLoop(provider: provider, thread: store, tools: [])

        let task = Task { try await loop.run("wait", onEvent: { _ in }, confirm: { _ in true }) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await items(store) == [.userMessage(text: "wait")])
    }

    @Test func theLoopGivesUpAfterTooManyReplies() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: (0..<5).map { index in
            [.item(toolCall("c\(index)", name: "record", arguments: [:]))]
        })
        let loop = AgentLoop(provider: provider, thread: store, tools: [RecordingTool()], maximumModelReplies: 3)

        await #expect(throws: AgentLoopError.tooManySteps(3)) {
            try await loop.run("loop", onEvent: { _ in }, confirm: { _ in true })
        }
        #expect(provider.requests.count == 3)
    }

    @Test func aDeclinedShellCommandDoesNotRun() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let marker = FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-marker-\(UUID().uuidString)")
        // Harmless, but marked destructive, so it must ask first.
        let command = "touch '\(marker.path)'"
        let provider = FakeProvider(replies: [
            [.item(toolCall("s", name: ShellCommandTool.name, arguments: ["command": .string(command), "destructive": true]))],
            [.item(assistant("Understood"))],
        ])
        let loop = AgentLoop(provider: provider, thread: store, tools: [ShellCommandTool()])
        let asked = EventLog()

        try await loop.run("touch it", onEvent: { _ in }, confirm: { request in
            asked.record(.toolRunning(callID: request.callID, summary: request.text))
            return false
        })

        #expect(asked.events == [.toolRunning(callID: "s", summary: command)])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let result = await items(store)[2]
        #expect(result == .toolResult(.init(callID: "s", output: "The person declined to run this command. It did not run.")))
    }

    @Test func anApprovedShellCommandRuns() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [
            [.item(toolCall("s", name: ShellCommandTool.name, arguments: ["command": "echo hello from the loop", "destructive": false]))],
            [.item(assistant("It said hello"))],
        ])
        let loop = AgentLoop(provider: provider, thread: store, tools: [ShellCommandTool()])
        let asked = EventLog()

        try await loop.run("say hello", onEvent: { _ in }, confirm: { request in
            asked.record(.toolRunning(callID: request.callID, summary: request.text))
            return true
        })

        #expect(asked.events.isEmpty)
        guard case .toolResult(let result) = await items(store)[2] else {
            Issue.record("expected a tool result")
            return
        }
        #expect(result.output.contains("hello from the loop"))
        #expect(result.output.hasSuffix("[exit status 0]"))
    }
}
