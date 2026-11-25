import AppKit
import Foundation
import MacOSAgentCore
import Synchronization
import Testing
@testable import mac_os_agent

/// A stand-in for an MCP tool: asks with an MCP card and keeps the answer it got.
private final class AskingTool: AgentTool, Sendable {
    static let name = "tasks__create_task"
    let answers = Mutex<[ConfirmationAnswer]>([])

    var definition: ToolDefinition {
        ToolDefinition(name: Self.name, description: "Creates a task.", parameters: ["type": "object", "properties": [:]])
    }

    func summary(arguments: JSONValue) -> String { "create_task on tasks" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let answer = await context.answer(ConfirmationRequest(
            callID: context.callID, kind: .mcpToolCall,
            body: .toolCall(server: "tasks", tool: "create_task", arguments: "{}"),
            reason: "comes from an MCP server and is set to ask before each call"))
        answers.withLock { $0.append(answer) }
        return answer.allows ? "done" : MCPTool.declinedOutput
    }
}

/// Calls the asking tool once, then replies "ok".
private final class OneCallProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let first = lock.withLock {
            count += 1
            return count == 1
        }
        return AsyncThrowingStream { continuation in
            let item: ThreadItem = first
                ? .toolCall(.init(callID: "call_task", name: AskingTool.name, arguments: "{}", provider: "test", model: "test-model"))
                : .assistantMessage(.init(text: "ok", provider: "test", model: "test-model"))
            continuation.yield(.item(item))
            continuation.finish()
        }
    }
}

private struct NoPrivacyAccess: PrivacyAccessGate {
    func status(_ kind: PrivacyAccessKind) -> PrivacyAccessStatus { .notDetermined }
    func requestAccess(_ kind: PrivacyAccessKind) async -> PrivacyAccessStatus { .notDetermined }
}

/// Always Allow and Always Deny on an MCP tool's go-ahead card: each answer reaches the tool,
/// and Settings > Tools shows a change made from the card while it is open.
@MainActor
@Suite(.serialized) struct GoAheadAlwaysTests {
    init() { _ = NSApplication.shared }

    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-go-ahead-always-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    /// Runs one call that asks, answers its card, and returns what the tool got and its result.
    private func answer(_ answer: ConfirmationAnswer) async throws -> ([ConfirmationAnswer], ThreadItem.ToolResult?) {
        defer { try? FileManager.default.removeItem(at: folder) }
        let tool = AskingTool()
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        let loop = AgentLoop(provider: OneCallProvider(), thread: thread, tools: [tool], episodeTimeout: { 1800 })
        let session = AgentSession(loop: loop, authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.draft = "add a task"
        session.submit()
        #expect(await eventually { session.pendingConfirmation != nil })
        #expect(session.pendingConfirmation?.offersAlways == true)
        session.resolveConfirmation(answer)
        #expect(session.pendingConfirmation == nil)
        await session.waitUntilIdle()
        let result = await thread.entries.compactMap { entry -> ThreadItem.ToolResult? in
            if case .toolResult(let result) = entry.item { result } else { nil }
        }.first
        return (tool.answers.withLock { $0 }, result)
    }

    @Test func alwaysAllowReachesTheToolAsItsOwnAnswer() async throws {
        let (answers, result) = try await answer(.alwaysAllow)
        #expect(answers == [.alwaysAllow])
        #expect(result?.output == "done")
        #expect(result?.details?.goAhead == .approved)
    }

    @Test func alwaysDenyReachesTheToolAsItsOwnAnswer() async throws {
        let (answers, result) = try await answer(.alwaysDeny)
        #expect(answers == [.alwaysDeny])
        #expect(result?.details?.goAhead == .declined)
    }

    @Test func theToolsPaneShowsAChangeMadeFromTheCard() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MCPSettingsStore(file: folder.appending(path: "mcp-settings.json"))
        let model = ToolsSettingsModel(registry: ToolRegistry(builtIn: []), access: NoPrivacyAccess(), mcpSettings: store)
        let before = model.goAheadRevision
        // As MCPTool does after Always Deny, off the main thread.
        try await Task.detached {
            try store.setGoAhead(.deny, server: "tasks", tool: "create_task", readOnly: false)
        }.value
        #expect(await eventually { model.goAheadRevision > before })
    }

    @Test func theToolListRowShowsAnMCPToolsSavedChoice() {
        var mcp = ToolSummary(AskingTool())
        mcp.mcp = MCPToolReference(server: "tasks", tool: "create_task", readOnly: false)
        #expect(ToolRow(tool: mcp, goAhead: .always).mark?.text == "Asks each time")
        #expect(ToolRow(tool: mcp, goAhead: .never).mark?.text == "Always allowed")
        #expect(ToolRow(tool: mcp, goAhead: .denied).mark?.symbol == "nosign")
        #expect(ToolRow(tool: mcp, goAhead: .denied).mark?.text == "Always denied")
        // A built-in tool that never asks has no mark, as before.
        let builtIn = ToolSummary(AskingTool())
        #expect(ToolRow(tool: builtIn, goAhead: .never).mark == nil)
        #expect(ToolRow(tool: builtIn, goAhead: .always).mark?.text == "Can ask for a go-ahead")
    }

    @Test func theToolsPaneSetsEachOfTheThreeChoices() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MCPSettingsStore(file: folder.appending(path: "mcp-settings.json"))
        let model = ToolsSettingsModel(registry: ToolRegistry(builtIn: []), access: NoPrivacyAccess(), mcpSettings: store)
        var tool = ToolSummary(AskingTool())
        tool.mcp = MCPToolReference(server: "tasks", tool: "create_task", readOnly: false)
        #expect(model.mcpGoAhead(of: tool) == .ask)
        for value in [MCPGoAhead.deny, .allow, .ask] {
            model.setGoAhead(value, tool)
            #expect(model.mcpGoAhead(of: tool) == value)
            #expect(model.goAhead(of: tool) == value.toolGoAhead)
        }
        #expect(model.errorMessage == nil)
    }
}
