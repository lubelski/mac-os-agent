import Foundation
import SQLite3
import Testing
@testable import MacOSAgentCore

/// History has whatever happened: every kind of entry the thread records shows in Settings,
/// History, in order, or folds into one that does for a stated reason. Search and the agent's
/// two history tools read the same record.
@Suite struct HistoryHasWhateverHappenedTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)
    static let runID = UUID()

    static let slack = ThreadItem.AppOpening(
        name: "Slack", bundleIdentifier: "com.example.slack", path: "/Applications/Slack.app",
        message: ThreadItem.AppOpening.message(name: "Slack", bundleIdentifier: "com.example.slack"))
    static let notes = ThreadItem.AppOpening(
        name: "Notes", bundleIdentifier: "com.example.notes", path: "/Applications/Notes.app",
        message: ThreadItem.AppOpening.message(name: "Notes", bundleIdentifier: "com.example.notes"))

    static func focusRun(failed: Bool) -> ThreadItem.QuickActionRun {
        let action = QuickAction(
            id: "focus-mode", name: "Focus Mode", description: "Quits Mail and turns on Do Not Disturb.",
            steps: [.init(tool: "quit_or_hide_application", arguments: ["application": "Mail", "action": "quit"]),
                    .init(tool: "run_shell_command", arguments: ["command": "shortcuts run focus", "destructive": false])])
        let steps = [
            ThreadItem.QuickActionRun.Step(
                callID: QuickActionRunStart.callID(entryID: runID, index: 0), tool: "quit_or_hide_application",
                arguments: action.steps[0].arguments.encodedString(), output: "Mail quit."),
            ThreadItem.QuickActionRun.Step(
                callID: QuickActionRunStart.callID(entryID: runID, index: 1), tool: "run_shell_command",
                arguments: action.steps[1].arguments.encodedString(),
                output: failed ? "Error: no shortcut named focus.\n[exit status 1]" : "[exit status 0]"),
        ]
        return ThreadItem.QuickActionRun(
            id: action.id, name: action.name, stepCount: 2, steps: steps, failedStep: failed ? 1 : nil,
            message: ThreadItem.QuickActionRun.message(typed: "focus", action: action, steps: steps, failedStep: failed ? 1 : nil))
    }

    static let search: ThreadItem = .providerItem(.init(provider: OpenAIResponses.providerName, model: "test-model", payload: [
        "type": "web_search_call", "id": "ws_1", "status": "completed",
        "action": ["type": "search", "query": "Lisbon weather tomorrow"],
    ]))
    static let reasoning: ThreadItem = .providerItem(.init(provider: OpenAIResponses.providerName, model: "test-model", payload: [
        "type": "reasoning", "id": "rs_1", "encrypted_content": "opaque",
    ]))

    /// A thread holding every kind of entry: a first episode of messages, a command, and its
    /// result; then, after the timeout, one with a hosted search, reasoning, a reply that only
    /// called a tool, a quick action, and an app opened; then one of apps opened only.
    static func everyKind() -> [ThreadEntry] {
        var clock = start
        func at(_ item: ThreadItem, id: UUID = UUID()) -> ThreadEntry {
            clock = clock.addingTimeInterval(20)
            return ThreadEntry(id: id, date: clock, item: item)
        }
        var entries = [
            at(.userMessage(text: "what's eating my disk")),
            at(toolCall("call_1", name: "run_shell_command", arguments: ["command": "du -sh ~/Movies", "destructive": false])),
            at(.toolResult(.init(callID: "call_1", output: "38G\t/Users/someone/Movies\n[exit status 0]"))),
            at(assistant("Movies, at 38 GB.")),
        ]
        clock = clock.addingTimeInterval(3_600)
        entries += [
            at(.episodeStart(.init(reason: .timeout))),
            at(.userMessage(text: "will it rain in Lisbon")),
            at(reasoning),
            at(search),
            at(.assistantMessage(.init(text: "", provider: "openai", model: "test-model"))),
            at(assistant("Light rain after 3 PM.")),
            at(.userMessage(text: "focus", action: focusRun(failed: true)), id: runID),
            at(.appOpened(slack)),
        ]
        clock = clock.addingTimeInterval(3_600)
        entries += [
            at(.episodeStart(.init(reason: .requested))),
            at(.appOpened(slack)),
            at(.appOpened(notes)),
        ]
        return entries
    }

    @Test func everyKindOfEntryHasALineOrAStatedReasonForNone() throws {
        let entries = Self.everyKind()
        // The thread above holds every kind there is, so a kind added later fails here until
        // it is decided in `HistoryReading` and added to the thread.
        #expect(Set(entries.map(\.item.kind)) == Set(ThreadItem.Kind.allCases))

        let contents = ThreadContents(entries: entries)
        var lined = Set<String>()
        for episode in contents.episodes {
            for line in EpisodeLine.lines(of: episode, in: contents) { lined.insert(line.id) }
        }
        for entry in entries {
            switch HistoryReading.of(entry.item) {
            case .owner, .agent, .command, .hostedCommand, .quickAction, .appOpened:
                #expect(lined.contains(entry.id.uuidString), "no line for \(entry.item.kind)")
            case .episodeStart:
                // The marker is the episode's caption, not a line.
                #expect(!lined.contains(entry.id.uuidString))
            case .folded(let reason):
                #expect(!lined.contains(entry.id.uuidString))
                switch (entry.item, reason) {
                case (.toolResult, .toolResult), (.providerItem, .providerOnly), (.assistantMessage, .emptyReply): break
                default: Issue.record("\(entry.item.kind) folds for the wrong reason: \(reason)")
                }
            }
        }
    }

    @Test func linesReadInOrderInThePanelsWords() throws {
        let contents = ThreadContents(entries: Self.everyKind())
        let second = try #require(contents.episode(numbered: 2))
        let lines = EpisodeLine.lines(of: second, in: contents)
        #expect(lines.map(\.text) == [
            "will it rain in Lisbon",
            "Search the web Lisbon weather tomorrow",
            "Light rain after 3 PM.",
            "Focus Mode failed: step 2 of 2: no shortcut named focus",
            "Opened Slack",
        ])
        #expect(lines[1].kind == .command(.unknown))
        // The quick action carries its steps as commands, and the one that failed says so.
        #expect(lines[3].steps.map(\.text) == ["Quit Mail", "Bash shortcuts run focus"])
        #expect(lines[3].steps.map(\.kind) == [.command(.unknown), .command(.failed)])
        if case .event(let line) = lines[3].kind { #expect(line.isFailure) } else { Issue.record("not an event") }
        // The same words the panel's line uses.
        if case .event(let line) = lines[4].kind {
            #expect(line == TranscriptLine.opened(Self.slack, date: line.date))
        } else {
            Issue.record("not an event")
        }
        #expect(second.startCaption == "Started after the episode before it went idle")
        #expect(contents.episode(numbered: 3)?.startCaption == "Started fresh, as asked")
        #expect(contents.episode(numbered: 1)?.startCaption == nil)
    }

    @Test func aCommandTakesItsOutcomeFromAnAnswerInTheNextEpisode() throws {
        let entries = [
            ThreadEntry(date: Self.start, item: .userMessage(text: "list files")),
            ThreadEntry(date: Self.start, item: toolCall("call_1", name: "run_shell_command", arguments: ["command": "ls"])),
            ThreadEntry(date: Self.start.addingTimeInterval(7_200), item: .episodeStart(.init(reason: .timeout))),
            ThreadEntry(date: Self.start.addingTimeInterval(7_200), item: .toolResult(.init(callID: "call_1", output: AgentLoop.unfinishedOutput))),
            ThreadEntry(date: Self.start.addingTimeInterval(7_200), item: .userMessage(text: "hello again")),
        ]
        let contents = ThreadContents(entries: entries)
        let lines = EpisodeLine.lines(of: try #require(contents.episode(numbered: 1)), in: contents)
        #expect(lines.map(\.kind) == [.owner, .command(.stopped)])
    }

    @Test func theSummaryNeverReadsZeroMessagesForAnEpisodeThatHoldsSomething() throws {
        let contents = ThreadContents(entries: Self.everyKind())
        #expect(contents.episodes.map(\.summary) == [
            "2 messages, 1 command",
            "2 messages, 1 command, 1 quick action, 1 app opened",
            "Opened 2 apps",
        ])
        // The list says what an app-only episode holds, and shows its first one.
        #expect(contents.episodes[2].preview == "Opened Slack")
        #expect(contents.episodes[1].preview == "will it rain in Lisbon")

        var episode = contents.episodes[2]
        episode.appOpenedCount = 1
        #expect(episode.summary == "Opened 1 app")
        episode.quickActionCount = 2
        #expect(episode.summary == "Ran 2 quick actions, opened 1 app")
        episode.appOpenedCount = 0
        episode.quickActionCount = 1
        #expect(episode.summary == "Ran 1 quick action")
        episode.messageCount = 1
        episode.appOpenedCount = 3
        #expect(episode.summary == "1 message, 1 quick action, 3 apps opened")
    }

    @Test func aQuickActionAloneIsNotAMessage() throws {
        let contents = ThreadContents(entries: [
            ThreadEntry(id: Self.runID, date: Self.start, item: .userMessage(text: "focus", action: Self.focusRun(failed: false))),
        ])
        let episode = try #require(contents.episodes.first)
        #expect(episode.messageCount == 0)
        #expect(episode.summary == "Ran 1 quick action")
        #expect(episode.preview == "Ran Focus Mode")
    }

    @Test func anEpisodeWithNothingToShowIsNotListed() throws {
        // A marker, then only the answer to the episode before's open call, then nothing: what
        // the thread holds when the message after the marker failed to be written.
        let entries = [
            ThreadEntry(date: Self.start, item: .userMessage(text: "list files")),
            ThreadEntry(date: Self.start, item: toolCall("call_1", name: "run_shell_command", arguments: ["command": "ls"])),
            ThreadEntry(date: Self.start.addingTimeInterval(7_200), item: .episodeStart(.init(reason: .timeout))),
            ThreadEntry(date: Self.start.addingTimeInterval(7_200), item: .toolResult(.init(callID: "call_1", output: AgentLoop.unfinishedOutput))),
            ThreadEntry(date: Self.start.addingTimeInterval(9_000), item: .episodeStart(.init(reason: .requested))),
        ]
        let contents = ThreadContents(entries: entries)
        #expect(contents.episodes.count == 3)
        #expect(contents.episodes[1].hasActivity)
        #expect(!contents.episodes[1].hasSomethingToShow)
        #expect(EpisodeListItem.all(in: contents).map(\.episode.number) == [1])
    }

    private func store(_ entries: [ThreadEntry], index: Bool = true) async throws -> (ThreadStore, URL) {
        let file = temporaryThreadFile()
        let indexURL = file.deletingLastPathComponent().appending(path: "history-index.sqlite")
        let store = try ThreadStore(fileURL: file, searchIndexURL: index ? indexURL : nil)
        for entry in entries { try await store.append(entry.item, date: entry.date, id: entry.id) }
        if index { #expect(await store.waitForSearchIndex()) }
        return (store, indexURL)
    }

    @Test(arguments: [true, false]) func searchFindsWhatHistoryShows(indexed: Bool) async throws {
        let (store, _) = try await store(Self.everyKind(), index: indexed)
        // An opened app's name finds its episodes.
        #expect(Set(await store.search("slack", limit: 20).map(\.episode.number)) == [2, 3])
        #expect(await store.search("notes").map(\.episode.number) == [3])
        // A hosted search, a quick action's name, and one of its steps.
        #expect(await store.search("lisbon weather").map(\.episode.number) == [2])
        #expect(await store.search("focus mode").map(\.episode.number) == [2])
        #expect(await store.search("shortcuts").map(\.episode.number) == [2])
        // Output is still not searched.
        #expect(await store.search("exit status").isEmpty)
        // The list shows a match as its line reads.
        let found = EpisodeListItem.matching(await store.search("notes"))
        #expect(found.map(\.match) == ["Opened Notes"])
    }

    @Test func anIndexFromBeforeTheseLinesIsRebuiltOnce() async throws {
        let (first, indexURL) = try await store(Self.everyKind())
        let file = first.fileURL

        // Make the index look like one an earlier version wrote: its own version, and no
        // passage for an opened app, since that version did not index them.
        func rewind(to version: String) throws {
            var database: OpaquePointer?
            #expect(sqlite3_open(indexURL.path, &database) == SQLITE_OK)
            defer { sqlite3_close(database) }
            #expect(sqlite3_exec(database, "DELETE FROM passages WHERE body LIKE '%opened%instant row%';", nil, nil, nil) == SQLITE_OK)
            #expect(sqlite3_exec(database, "UPDATE state SET value = '\(version)' WHERE key = 'version';", nil, nil, nil) == SQLITE_OK)
        }

        // With the current version the index is trusted as it is, so the missing rows stay
        // missing: the version is what tells an old index apart.
        try rewind(to: HistoryIndex.formatVersion)
        let trusted = try ThreadStore(fileURL: file, searchIndexURL: indexURL)
        #expect(await trusted.waitForSearchIndex())
        #expect(await trusted.search("slack").isEmpty)

        // An index from version 1 is rebuilt on open, with no step by the owner.
        try rewind(to: "1")
        #expect(HistoryIndex.formatVersion != "1")
        let reopened = try ThreadStore(fileURL: file, searchIndexURL: indexURL)
        #expect(await reopened.waitForSearchIndex())
        #expect(Set(await reopened.search("slack", limit: 20).map(\.episode.number)) == [2, 3])
    }

    @Test func theAgentsHistoryToolsSeeTheSameThings() async throws {
        var entries = Self.everyKind()
        // A current episode, so the others are earlier ones.
        entries.append(ThreadEntry(date: Self.start.addingTimeInterval(20_000), item: .episodeStart(.init(reason: .requested))))
        entries.append(ThreadEntry(date: Self.start.addingTimeInterval(20_000), item: .userMessage(text: "what did I open")))
        let (store, _) = try await store(entries)
        let current = try #require(await store.currentEpisode)
        let context = ToolRunContext(callID: "c", episodeID: current.id, confirm: { _ in true })
        let gmt = try #require(TimeZone(identifier: "GMT"))

        let found = await SearchHistoryTool(history: store, timeZone: gmt).run(arguments: ["query": "slack", "limit": .null], context: context)
        #expect(found.contains("person: [opened Slack from the instant row]"))

        let read = await ReadEpisodeTool(history: store, timeZone: gmt).run(arguments: ["episode": 2, "from_line": .null], context: context)
        #expect(read.contains("2 messages and 1 command. Also 1 quick action the person ran and 1 app the person opened."))
        #expect(read.contains("Started after the episode before it went idle."))
        #expect(read.contains("command: Search the web Lisbon weather tomorrow"))
        #expect(read.contains("[ran the quick action Focus Mode]"))
        #expect(read.contains("person: [opened Slack from the instant row]"))

        let appsOnly = await ReadEpisodeTool(history: store, timeZone: gmt).run(arguments: ["episode": 3, "from_line": .null], context: context)
        #expect(appsOnly.contains("0 messages and 0 commands. Also 2 apps the person opened."))
        #expect(appsOnly.contains("[opened Notes from the instant row]"))
    }
}
