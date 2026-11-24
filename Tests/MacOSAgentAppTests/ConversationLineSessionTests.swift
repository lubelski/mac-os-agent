import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// A stand-in step that returns a fixed result and never runs anything.
private final class FixedStepTool: AgentTool, @unchecked Sendable {
    let result: String
    init(result: String) { self.result = result }

    var definition: ToolDefinition {
        ToolDefinition(name: "open_application", description: "A stand-in.", parameters: [
            "type": "object", "properties": ["bundle_identifier_or_path": ["type": "string"]],
            "required": ["bundle_identifier_or_path"], "additionalProperties": false,
        ])
    }

    func summary(arguments: JSONValue) -> String { "Open \(arguments["bundle_identifier_or_path"]?.stringValue ?? "")" }
    func run(arguments: JSONValue, context: ToolRunContext) async -> String { result }
}

/// The lines in the conversation with the panel with bars experiment on, in the main panel's
/// session against a kept thread in a temporary folder: an opened app is logged and shown, a
/// quick action is one line, the switch off writes and draws as before, and the incognito
/// window writes nothing.
@MainActor
@Suite(.serialized) struct ConversationLineSessionTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-lines-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private static let lights = QuickAction(
        id: "balcony-lights-on", name: "Balcony Lights On", description: "Turns the balcony lights on.", phrases: ["balcony"],
        steps: [.init(tool: "open_application", arguments: ["bundle_identifier_or_path": "/Applications/Lights.app"])])

    final class Recorder {
        var opened: [String] = []
        var shows = 0
    }

    private func makeSession(
        panelWithBars: Bool, provider: EchoProvider = EchoProvider(), stepResult: String = "Opened Lights."
    ) async throws -> (AgentSession, ThreadStore, Recorder) {
        let thread = try ThreadStore(fileURL: root.appending(path: "thread.jsonl"))
        let tools: [any AgentTool] = [FixedStepTool(result: stepResult)]
        let loop = AgentLoop(provider: provider, thread: thread, tools: tools, episodeTimeout: { 1800 })
        let session = AgentSession(loop: loop, authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.forcedPanelWithBars = panelWithBars
        await session.start()
        let recorder = Recorder()
        let library = QuickActionLibrary(folder: root.appending(path: "quick-actions", directoryHint: .isDirectory))
        try library.save(Self.lights)
        session.instantActions = InstantActions(
            applications: InstantActionPreview.applications, open: { recorder.opened.append($0.name) },
            quickActionLibrary: library, summaries: ToolCallSummaries(tools))
        session.hidePanel = {}
        session.showPanel = { recorder.shows += 1 }
        return (session, thread, recorder)
    }

    /// Waits for the opening's log, which runs after the app opens.
    private func settle(_ thread: ThreadStore, count: Int) async throws {
        for _ in 0..<200 where await thread.entries.count < count {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func lines(_ session: AgentSession) -> [TranscriptLine] {
        session.transcript.rows.compactMap { if case .line(let line) = $0.kind { line } else { nil } }
    }

    @Test func anOpenedAppIsLoggedAndShownAndGoesWithTheNextMessage() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = EchoProvider()
        let (session, thread, recorder) = try await makeSession(panelWithBars: true, provider: provider)
        session.draft = "safari"
        session.submit()
        try await settle(thread, count: 1)

        #expect(recorder.opened == ["Safari"])
        #expect(provider.requests.isEmpty, "nothing is sent when it happens")
        let entries = await thread.entries
        guard case .appOpened(let opening) = entries.last?.item else { Issue.record("not logged"); return }
        #expect(opening.name == "Safari")
        #expect(lines(session).map(\.spokenText) == ["Opened Safari"])
        #expect(session.recallHistory.isEmpty, "an opening is not recalled")

        session.draft = "what did I open?"
        session.submitToAgent()
        await session.waitUntilIdle()
        let sent = try #require(provider.requests.first)
        #expect(sent.entries.map(\.item).first == .appOpened(opening))
        #expect(sent.entries.map(\.item).last == .userMessage(text: "what did I open?"))
    }

    @Test func withTheSwitchOffOpeningAnAppWritesNothing() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, thread, recorder) = try await makeSession(panelWithBars: false)
        session.draft = "safari"
        session.submit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(recorder.opened == ["Safari"])
        #expect(await thread.entries.isEmpty)
        #expect(lines(session).isEmpty)
    }

    @Test func aQuickActionIsOneLineAndItsTextIsStillRecalled() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, thread, _) = try await makeSession(panelWithBars: true)
        session.draft = "balcony"
        session.submit()
        await session.waitUntilIdle()
        #expect(lines(session).map(\.spokenText) == ["Ran Balcony Lights On"])
        #expect(!session.transcript.rows.contains { $0.isTool || $0.isUser })
        #expect(session.recallHistory == ["balcony"])
        // What is stored is as before.
        guard case .userMessage("balcony", nil, let record?) = await thread.entries.last?.item else { Issue.record("no record"); return }
        #expect(record.failedStep == nil)
    }

    @Test func aFailedQuickActionIsARedLineAndThePanelComesBackWithTheText() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, recorder) = try await makeSession(panelWithBars: true, stepResult: "Error: no shortcut by that name.")
        session.draft = "balcony"
        session.submit()
        await session.waitUntilIdle()
        let line = try #require(lines(session).last)
        #expect(line.isFailure)
        #expect(line.trailingText == "Balcony Lights On failed: no shortcut by that name")
        #expect(recorder.shows == 1)
        #expect(session.draft == "balcony")
    }

    @Test func turningTheSwitchOffDrawsTheThreadAsBefore() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, thread, _) = try await makeSession(panelWithBars: true)
        session.draft = "balcony"
        session.submit()
        await session.waitUntilIdle()
        session.draft = "safari"
        session.submit()
        try await settle(thread, count: 2)
        #expect(lines(session).count == 2)

        session.forcedPanelWithBars = false
        session.followPanelWithBarsSwitch()
        for _ in 0..<200 where session.transcript.showsLines { try await Task.sleep(for: .milliseconds(5)) }
        #expect(lines(session).isEmpty)
        #expect(session.transcript.rows.contains { if case .user("balcony", _, _) = $0.kind { true } else { false } })
        #expect(session.transcript.rows.contains { $0.isTool })
    }

    @Test func theIncognitoWindowWritesNothingForAnOpening() async throws {
        let store = InMemoryThreadStore()
        let provider = EchoProvider()
        final class Opened { var names: [String] = [] }
        let opened = Opened()
        let session = AgentSession(incognito: { AgentLoop(provider: provider, thread: store, tools: []) }, signedIn: true)
        session.forcedPanelWithBars = true
        session.instantActions = InstantActions(
            applications: InstantActionPreview.applications, open: { opened.names.append($0.name) }, learns: false)
        session.draft = "xcode"
        session.submit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(opened.names == ["Xcode"])
        #expect(await store.entries.isEmpty)
        #expect(session.transcript.rows.allSatisfy { $0.isEpisodeStart })
        #expect(provider.requests.isEmpty)
    }
}
