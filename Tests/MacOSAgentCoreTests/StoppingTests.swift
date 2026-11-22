import Foundation
import Testing
@testable import MacOSAgentCore

/// A tool that runs until its task is cancelled, as a long command would.
private struct WaitingTool: AgentTool {
    var definition: ToolDefinition {
        ToolDefinition(name: "wait", description: "Waits.", parameters: ["type": "object"])
    }

    func summary(arguments: JSONValue) -> String { "Wait" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return "Stopped while waiting."
    }
}

/// A provider whose reply sends some events and then hangs until the request is cancelled,
/// ending with the error a cancelled URLSession request throws.
private final class HangingProvider: ModelProvider, @unchecked Sendable {
    let events: [ModelStreamEvent]
    private let lock = NSLock()
    private var terminated = false
    var wasTerminated: Bool { lock.withLock { terminated } }

    init(events: [ModelStreamEvent]) {
        self.events = events
    }

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let events = events
        return AsyncThrowingStream { continuation in
            let task = Task {
                for event in events { continuation.yield(event) }
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                continuation.finish(throwing: URLError(.cancelled))
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.terminated = true }
                task.cancel()
            }
        }
    }
}

/// Stopping a task leaves the thread so that the next request is valid: every call the model
/// made has a result, and a call that never ran says it was stopped, not declined.
@Suite struct StoppingTests {
    private func results(_ store: ThreadStore) async -> [String: ThreadItem.ToolResult] {
        var results: [String: ThreadItem.ToolResult] = [:]
        for entry in await store.entries {
            if case .toolResult(let result) = entry.item { results[result.callID] = result }
        }
        return results
    }

    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("the condition never held")
    }

    @Test func stoppingDuringTheFirstOfTwoCallsAnswersTheSecond() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [[
            .item(toolCall("first", name: "wait", arguments: [:])),
            .item(toolCall("second", name: "wait", arguments: [:])),
        ]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [WaitingTool()])
        let log = EventLog()
        let task = Task { try await loop.run("go", onEvent: { log.record($0) }, confirm: { _ in true }) }
        await waitUntil { log.events.contains(.toolRunning(callID: "first", summary: "Wait")) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }

        let results = await results(store)
        #expect(results["first"]?.output == "Stopped while waiting.")
        #expect(results["first"]?.details?.stopped == true)
        #expect(results["second"]?.output == AgentLoop.stoppedBeforeRunningOutput)
        #expect(await store.unansweredToolCalls().isEmpty)
        #expect(log.events.contains(.toolFinished(callID: "second")))
        #expect(TranscriptRow.outcome(ofOutput: AgentLoop.stoppedBeforeRunningOutput) == .stopped)
    }

    @Test func stoppingWhileTheReplyStreamsCancelsTheRequestAndAnswersItsCalls() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = HangingProvider(events: [.item(toolCall("written", name: "wait", arguments: [:]))])
        let loop = AgentLoop(provider: provider, thread: store, tools: [WaitingTool()])
        let log = EventLog()
        let task = Task { try await loop.run("go", onEvent: { log.record($0) }, confirm: { _ in true }) }
        await waitUntil { log.events.contains { if case .entryAdded(let entry) = $0, case .toolCall = entry.item { true } else { false } } }
        task.cancel()
        // The provider's own cancellation error still reads as stopping.
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(provider.wasTerminated)
        #expect(await results(store)["written"]?.output == AgentLoop.stoppedBeforeRunningOutput)
        #expect(await store.unansweredToolCalls().isEmpty)
    }

    @Test func aProviderErrorWithoutStoppingIsStillAnError() async throws {
        struct Broken: ModelProvider {
            func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
                AsyncThrowingStream { $0.finish(throwing: URLError(.cancelled)) }
            }
        }
        let loop = AgentLoop(provider: Broken(), thread: try ThreadStore(fileURL: temporaryThreadFile()), tools: [])
        await #expect(throws: URLError.self) { try await loop.run("go", onEvent: { _ in }, confirm: { _ in true }) }
    }

    /// Stopping answers the waiting go-ahead with no. The tool reads that as a stop, so the model
    /// is not told the owner declined, and no answer is noted for the inspector.
    @Test func stoppingDuringAGoAheadIsAStopNotADecline() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [[
            .item(toolCall("rm", name: ShellCommandTool.name, arguments: ["command": "rm /nonexistent/mac-os-agent-test", "destructive": true])),
        ]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [ShellCommandTool()])
        let asked = EventLog()
        let task = Task {
            try await loop.run("go", onEvent: { _ in }, confirm: { request in
                asked.record(.toolRunning(callID: request.callID, summary: ""))
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                return false
            })
        }
        await waitUntil { !asked.events.isEmpty }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let result = try #require(await results(store)["rm"])
        #expect(result.output == ShellCommandTool.stoppedBeforeRunningOutput)
        #expect(result.details?.goAhead == nil)
        #expect(result.details?.stopped == true)
    }

    @Test(arguments: [
        "The task was stopped before anything was changed.",
        "The task was stopped before Safari was quit.",
        AgentLoop.unfinishedOutput,
    ])
    func everyStoppedOutputReadsAsStopped(output: String) {
        #expect(TranscriptRow.outcome(ofOutput: output) == .stopped)
        #expect(ToolCallState(status: .finished, output: output) == .stopped)
    }

    @Test func rowsLeftUnfinishedReadAsStopped() {
        var transcript = Transcript()
        transcript.apply(ThreadEntry(date: Date(), item: .userMessage(text: "go")))
        transcript.toolStarted("cut-off")
        transcript.stopUnfinishedTools()
        guard case .tool(_, let status, let output) = transcript.rows.last?.kind else {
            Issue.record("expected a tool row")
            return
        }
        #expect(status == .finished)
        #expect(ToolCallState(status: status, output: output) == .stopped)
    }
}
