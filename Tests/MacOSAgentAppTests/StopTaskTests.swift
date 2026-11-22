import AppKit
import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// Asks for a command that needs a go-ahead, then replies "ok" to anything after it.
private final class GoAheadProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let first = lock.withLock {
            count += 1
            return count == 1
        }
        return AsyncThrowingStream { continuation in
            let item: ThreadItem = first
                ? .toolCall(.init(
                    callID: "rm", name: ShellCommandTool.name,
                    arguments: #"{"command":"rm /nonexistent/mac-os-agent-test","destructive":true}"#,
                    provider: "test", model: "test-model"))
                : .assistantMessage(.init(text: "ok", provider: "test", model: "test-model"))
            continuation.yield(.item(item))
            continuation.finish()
        }
    }
}

/// Stopping a task from the panel: Stop in the main menu with Command-Period, and what a stop
/// during a go-ahead leaves in the thread and the conversation.
@MainActor
@Suite(.serialized) struct StopTaskTests {
    init() { _ = NSApplication.shared }

    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-stop-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private func commandPeriod() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: ".", charactersIgnoringModifiers: ".", isARepeat: false, keyCode: 47))
    }

    private func makePanel() throws -> (SummonPanel, AgentSession, ThreadStore, WindowRecorder) {
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        let loop = AgentLoop(provider: GoAheadProvider(), thread: thread, tools: [ShellCommandTool()], episodeTimeout: { 1800 })
        let session = AgentSession(loop: loop, authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        let standIn = StandInScreens()
        let recorder = WindowRecorder()
        let panel = SummonPanel(
            session: session, remembersFrame: false, placementDefaults: nil,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        panel.orderIn = { _, makeKey in recorder.orderedIn.append(makeKey) }
        panel.orderAway = { _ in recorder.orderedAway += 1 }
        panel.drivesSlidesWithTheDisplay = false
        return (panel, session, thread, recorder)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func theMainMenuHasStopOnCommandPeriod() throws {
        let menu = MainMenu.make()
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        let stop = try #require(items.first { $0.action == MainMenu.stopTaskAction })
        #expect(stop.title == "Stop")
        #expect(stop.keyEquivalent == ".")
        #expect(stop.keyEquivalentModifierMask == .command)
        #expect(MainMenu.isStopShortcut(try commandPeriod()))
    }

    @Test func stopIsEnabledOnlyWhileTheWindowsTaskRuns() async throws {
        let (panel, session, _, _) = try makePanel()
        let item = NSMenuItem(title: "Stop", action: MainMenu.stopTaskAction, keyEquivalent: ".")
        #expect(!panel.validateMenuItem(item))
        session.draft = "clean up"
        session.submit()
        #expect(panel.validateMenuItem(item))
        session.stop()
        await session.waitUntilIdle()
        #expect(!panel.validateMenuItem(item))
    }

    /// With no task, Command-Period does nothing: the disabled Stop takes the press, so it never
    /// reaches the window as Escape and hides the panel.
    @Test func commandPeriodWithNoTaskLeavesThePanelUp() throws {
        let (panel, _, _, recorder) = try makePanel()
        let previous = NSApp.mainMenu
        NSApp.mainMenu = MainMenu.make()
        defer { NSApp.mainMenu = previous }
        panel.summon()
        #expect(panel.performKeyEquivalent(with: try commandPeriod()))
        #expect(recorder.orderedAway == 0)
        #expect(panel.isPresented)
    }

    /// Stop during a go-ahead: the command never runs, the model reads that the task stopped
    /// rather than that the owner declined, and the conversation says Stopped.
    @Test func stoppingDuringAGoAheadReadsAsStopped() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let (panel, session, thread, _) = try makePanel()
        let previous = NSApp.mainMenu
        NSApp.mainMenu = MainMenu.make()
        defer { NSApp.mainMenu = previous }
        session.draft = "clean up"
        session.submit()
        #expect(await eventually { session.pendingConfirmation != nil })

        // Command-Period goes to the main menu first, never to the card's Don't Run.
        _ = panel.performKeyEquivalent(with: try commandPeriod())
        #expect(session.pendingConfirmation != nil, "Command-Period did not answer the go-ahead")

        panel.stopTask(nil)
        await session.waitUntilIdle()
        #expect(!session.isRunning)
        #expect(session.pendingConfirmation == nil)

        let result = await thread.entries.compactMap { entry -> ThreadItem.ToolResult? in
            if case .toolResult(let result) = entry.item { result } else { nil }
        }.first
        #expect(result?.output == ShellCommandTool.stoppedBeforeRunningOutput)
        #expect(result?.details?.goAhead == nil)
        #expect(await thread.unansweredToolCalls().isEmpty)

        let row = try #require(session.transcript.rows.first { $0.id == "rm" })
        guard case .tool(let summary, let status, let output) = row.kind else {
            Issue.record("expected a tool row")
            return
        }
        #expect(summary == "Bash rm /nonexistent/mac-os-agent-test")
        #expect(ToolCallState(status: status, output: output) == .stopped)
        #expect(session.transcript.rows.last?.kind == .notice("Stopped."))
        #expect(session.transcript.toolCall("rm")?.status == .stopped)
    }
}
