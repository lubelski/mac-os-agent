import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Settings, History, with the pane stack experiment off and on, checked on the window's views,
/// model, and key handling, since screen capture is not available.
@MainActor
@Suite(.serialized) struct HistoryPaneStackAppTests {
    /// A History window over two placeholder episodes: one with a command, then, after a
    /// requested start, one of messages only.
    private func harness(paneStack: Bool) async throws -> SettingsWindowHarness {
        let harness = try SettingsWindowHarness(section: .history, experiments: paneStack ? [.settingsPaneStack] : [])
        let store = try #require(harness.controller.models.history.history)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        func append(_ item: ThreadItem) async throws {
            clock = clock.addingTimeInterval(20)
            _ = try await store.append(item, date: clock)
        }
        let arguments: JSONValue = ["command": "du -sh ~/Movies", "destructive": false]
        try await append(.userMessage(text: "what's eating my disk space"))
        try await append(.toolCall(.init(
            callID: "call_1", name: "run_shell_command", arguments: arguments.encodedString(), provider: "openai", model: "test-model")))
        try await append(.toolResult(.init(callID: "call_1", output: "38G\t/Users/someone/Movies\n[exit status 0]")))
        try await append(.assistantMessage(.init(text: "Movies is the big one.", provider: "openai", model: "test-model")))
        try await append(.episodeStart(.init(reason: .requested)))
        try await append(.userMessage(text: "turn on dark mode"))
        try await append(.assistantMessage(.init(text: "Dark mode is on.", provider: "openai", model: "test-model")))
        // The window read the thread when it opened, before these were written.
        let history = harness.controller.models.history
        history.reload()
        await settle(harness) { history.items.count == 2 }
        return harness
    }

    /// Waits for the model's tasks until a condition holds, for up to five seconds, since a
    /// search is slower in a full test run.
    private func settle(_ harness: SettingsWindowHarness, until condition: () -> Bool) async {
        for _ in 0..<50 where !condition() {
            await settle(harness)
        }
    }

    /// Lays the window out and lets the model's own tasks run: reading the thread, and a
    /// search, which waits for a pause in typing. An async test holds the main actor while the
    /// run loop spins, so the tasks run only when the test waits.
    private func settle(_ harness: SettingsWindowHarness) async {
        harness.layOut()
        try? await Task.sleep(for: .milliseconds(400))
        harness.layOut()
    }

    private func escape() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    /// The tables in the window, other than the sidebar's, which is the leftmost: History's own
    /// list, when it has one.
    private func historyTables(in harness: SettingsWindowHarness) -> [NSTableView] {
        var found: [NSTableView] = []
        func walk(_ view: NSView) {
            if let table = view as? NSTableView { found.append(table) }
            view.subviews.forEach(walk)
        }
        if let content = harness.window.contentView { walk(content) }
        let sidebar = found.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        return found.filter { $0 !== sidebar }
    }

    @Test func withTheExperimentOffHistoryIsTheListBesideTheEpisode() async throws {
        let harness = try await harness(paneStack: false)
        defer { harness.tearDown() }
        let history = harness.controller.models.history
        await settle(harness)
        #expect(history.items.map(\.episode.number) == [2, 1])
        // The list beside the episode, as before: a table of the episodes, the newest selected.
        let tables = historyTables(in: harness).map(\.numberOfRows)
        #expect(tables == [2], "tables: \(tables)")
        #expect(history.selectedItem != nil)
        history.selection = history.items.last?.id
        await settle(harness)
        #expect(history.lines.map(\.kind) == [.owner, .command(.succeeded), .agent])
        // History does not take Escape, and the stack is never touched.
        #expect(!harness.window.performKeyEquivalent(with: try escape()))
        #expect(history.stack.path.isAtBase)
    }

    @Test func withTheExperimentOnHistoryIsAStackAndEscapeClosesOnePane() async throws {
        let harness = try await harness(paneStack: true)
        defer { harness.tearDown() }
        let history = harness.controller.models.history
        await settle(harness)
        // No table: the episodes are the stack's base pane.
        let tables = historyTables(in: harness).map(\.numberOfRows)
        #expect(tables.isEmpty, "tables: \(tables)")
        #expect(!harness.window.performKeyEquivalent(with: try escape()))

        history.showInStack("call_1")
        await settle(harness)
        #expect(history.stack.path.entries == ["1", "call_1"])
        #expect(harness.window.performKeyEquivalent(with: try escape()))
        await settle(harness)
        #expect(history.stack.path.entries == ["1"])
        #expect(harness.window.performKeyEquivalent(with: try escape()))
        await settle(harness)
        #expect(history.stack.path.isAtBase)
        #expect(!harness.window.performKeyEquivalent(with: try escape()))
    }

    @Test func aSearchListsWhatMatchedAndItsEpisodeOpensAtTheMatch() async throws {
        let harness = try await harness(paneStack: true)
        defer { harness.tearDown() }
        let history = harness.controller.models.history
        history.query = "dark mode"
        await settle(harness) { history.items.count == 1 }
        #expect(history.items.map(\.episode.number) == [2])
        let panes = history.panes
        let episode = try #require(panes.episode("2"))
        let matched = try #require(panes.matchedLineID(in: episode))
        // The line that matched is one the episode's pane shows, to mark and scroll to.
        let line = try #require(panes.lines(of: episode).first { $0.id == matched })
        #expect(line.text.localizedCaseInsensitiveContains("dark mode"))

        // An episode that is open stays open when the search changes and no longer lists it.
        history.showInStack("2")
        history.query = "movies"
        await settle(harness) { history.items.first?.episode.number == 1 }
        #expect(history.items.map(\.episode.number) == [1])
        #expect(history.stack.path.entries == ["2"])
    }

    @Test func leavingHistoryAndComingBackKeepsTheStack() async throws {
        let harness = try await harness(paneStack: true)
        defer { harness.tearDown() }
        let history = harness.controller.models.history
        history.showInStack("call_1")
        await settle(harness)
        harness.controller.models.navigation.section = .general
        await settle(harness)
        harness.controller.models.navigation.section = .history
        await settle(harness)
        #expect(history.stack.path.entries == ["1", "call_1"])
    }

    @Test func aPathToSomethingGoneFallsBackWhenHistoryShows() async throws {
        let harness = try await harness(paneStack: true)
        defer { harness.tearDown() }
        let history = harness.controller.models.history
        history.stack.path = PaneStackPath(["1", "call_gone"])
        await settle(harness)
        #expect(history.stack.path.entries == ["1"])
        history.stack.path = PaneStackPath(["9"])
        await settle(harness)
        #expect(history.stack.path.isAtBase)
    }
}
