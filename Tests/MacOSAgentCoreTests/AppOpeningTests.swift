import Foundation
import Testing
@testable import MacOSAgentCore

private let calendarApp = InstalledApplication(
    name: "Calendar", bundleIdentifier: "com.apple.iCal",
    url: URL(filePath: "/System/Applications/Calendar.app", directoryHint: .isDirectory))

private func reply(_ text: String) -> [ModelStreamEvent] {
    [.item(assistant(text))]
}

private let noEvents: @Sendable (AgentEvent) async -> Void = { _ in }
private let noConfirm: @Sendable (ConfirmationRequest) async -> Bool = { _ in false }

/// An app the owner opened, logged with the panel with bars experiment on: nothing is sent when
/// it happens, and it joins the next request of its episode at the end, so the earlier request
/// is a prefix of the next. Older builds and the switch off read the thread as before.
@Suite struct AppOpeningTests {
    @Test func nothingIsSentWhenAnAppIsOpened() async throws {
        let url = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(replies: [reply("Hi.")])
        let thread = try ThreadStore(fileURL: url)
        let loop = AgentLoop(provider: provider, thread: thread, tools: [])

        try await loop.run("hello", onEvent: noEvents, confirm: noConfirm)
        #expect(provider.requests.count == 1)
        let entry = try await loop.logAppOpening(ThreadItem.AppOpening(calendarApp), onEvent: noEvents)

        #expect(provider.requests.count == 1, "opening an app makes no request")
        #expect(await thread.entries.last == entry)
        guard case .appOpened(let opening) = entry.item else { Issue.record("not an opening"); return }
        #expect(opening.name == "Calendar")
        #expect(opening.bundleIdentifier == "com.apple.iCal")
        #expect(opening.path == "/System/Applications/Calendar.app")
        #expect(opening.message.hasPrefix("<app_opened>\nThe person opened Calendar (com.apple.iCal) from the instant row."))
        #expect(opening.message.hasSuffix("</app_opened>"))
    }

    @Test func theOpeningJoinsTheNextRequestAndTheEarlierPrefixHolds() async throws {
        let url = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(replies: [reply("Hi."), reply("You opened Calendar.")])
        let thread = try ThreadStore(fileURL: url)
        let loop = AgentLoop(provider: provider, thread: thread, tools: [])
        let start = Date()

        try await loop.run("hello", now: start, onEvent: noEvents, confirm: noConfirm)
        try await loop.logAppOpening(ThreadItem.AppOpening(calendarApp), now: start.addingTimeInterval(30), onEvent: noEvents)
        try await loop.logAppOpening(
            ThreadItem.AppOpening(InstalledApplication(name: "Notes", bundleIdentifier: nil, url: URL(filePath: "/System/Applications/Notes.app"))),
            now: start.addingTimeInterval(40), onEvent: noEvents)
        try await loop.run("what did I just open?", now: start.addingTimeInterval(60), onEvent: noEvents, confirm: noConfirm)

        #expect(provider.requests.count == 2)
        let first = provider.requests[0]
        let second = provider.requests[1]
        // The second request is the first, then the reply, then each opening, then the message.
        #expect(Array(second.entries.prefix(first.entries.count)) == first.entries)
        let rest = second.entries.dropFirst(first.entries.count).map(\.item)
        #expect(rest.count == 4)
        if case .assistantMessage = rest[0] {} else { Issue.record("the reply comes first") }
        if case .appOpened(let opening) = rest[1] { #expect(opening.name == "Calendar") } else { Issue.record("no Calendar") }
        if case .appOpened(let opening) = rest[2] { #expect(opening.name == "Notes") } else { Issue.record("no Notes") }
        #expect(rest[3] == .userMessage(text: "what did I just open?"))

        // What OpenAI is sent: the first request's input is a prefix of the second's, and each
        // opening is its note, stamped like a message.
        let utc = TimeZone(identifier: "UTC")!
        let firstInput = OpenAIResponses.input(for: first, model: "test-model", timeZone: utc)
        let secondInput = OpenAIResponses.input(for: second, model: "test-model", timeZone: utc)
        #expect(Array(secondInput.prefix(firstInput.count)) == firstInput)
        let calendarItem = secondInput[firstInput.count + 1]
        #expect(calendarItem["role"]?.stringValue == "user")
        let text = try #require(calendarItem["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(text.hasPrefix("["))
        #expect(text.contains("] <app_opened>\nThe person opened Calendar (com.apple.iCal)"))
        let notesText = try #require(secondInput[firstInput.count + 2]["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(notesText.contains("The person opened Notes from the instant row."), "no bundle id, no parentheses")
    }

    @Test func itIsStoredAsAnEntryOfItsOwnAndReadBack() async throws {
        let url = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let thread = try ThreadStore(fileURL: url)
        try await thread.append(.userMessage(text: "hello"))
        let opening = ThreadItem.AppOpening(calendarApp)
        try await thread.append(.appOpened(opening))

        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let line = String(lines[1])
        #expect(line.contains(#""type":"app_opened""#))
        #expect(line.contains(#""name":"Calendar""#))
        #expect(line.contains(#""path":"/System/Applications/Calendar.app""#))

        let reloaded = try ThreadStore(fileURL: url)
        #expect(await reloaded.unreadableLineCount == 0)
        #expect(await reloaded.entries.last?.item == .appOpened(opening))
    }

    /// An older build has no `app_opened` kind, so its decoder fails on the line and the store
    /// skips it as it skips any line it cannot read, and loads the rest. Here a kind this build
    /// does not know stands in for it, through the same path.
    @Test func aBuildThatDoesNotKnowTheKindSkipsTheLineAndKeepsTheRest() async throws {
        let url = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let thread = try ThreadStore(fileURL: url)
        try await thread.append(.userMessage(text: "hello"))
        try await thread.append(.appOpened(ThreadItem.AppOpening(calendarApp)))
        try await thread.append(.userMessage(text: "after"))
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: #""type":"app_opened""#, with: #""type":"some_later_kind""#)
        try text.write(to: url, atomically: true, encoding: .utf8)

        let older = try ThreadStore(fileURL: url)
        #expect(await older.unreadableLineCount == 1)
        #expect(await older.entries.map(\.item) == [.userMessage(text: "hello"), .userMessage(text: "after")])
        #expect(await older.episodes.count == 1)
        // It keeps appending after the line it skipped, and the line stays in the file.
        try await older.append(.userMessage(text: "from the older build"))
        let again = try String(contentsOf: url, encoding: .utf8)
        #expect(again.contains("some_later_kind"))
        #expect(await (try ThreadStore(fileURL: url)).entries.count == 3)
    }

    @Test func withTheSwitchOffTheThreadReadsAsBefore() {
        let start = Date()
        let runID = UUID()
        let entries = [
            ThreadEntry(date: start, item: .userMessage(text: "hello")),
            ThreadEntry(date: start.addingTimeInterval(5), item: assistant("Hi.")),
            ThreadEntry(date: start.addingTimeInterval(10), item: .appOpened(ThreadItem.AppOpening(calendarApp))),
            ThreadEntry(id: runID, date: start.addingTimeInterval(20), item: .userMessage(text: "bal", action: Self.run(id: runID, failed: false))),
        ]
        let off = Transcript(entries: entries)
        #expect(!off.rows.contains { $0.isLine }, "no line for the opening or the run")
        let kinds = off.rows.map(\.kind)
        #expect(kinds.contains { if case .user("bal", _, _) = $0 { true } else { false } })
        #expect(off.rows.filter(\.isTool).count == 1)

        let on = Transcript(entries: entries, showsLines: true)
        let lines = on.rows.compactMap { if case .line(let line) = $0.kind { line } else { nil } }
        #expect(lines.map(\.spokenText) == ["Opened Calendar", "Ran Balcony Lights On"])
        #expect(lines[0].icon == .application(path: "/System/Applications/Calendar.app"))
        #expect(lines[1].icon == .quickAction)
        #expect(lines[1].typed == "bal")
        #expect(!on.rows.contains { $0.isTool }, "a run's steps have no rows of their own")
        #expect(!on.rows.contains { if case .user("bal", _, _) = $0.kind { true } else { false } })
        // Lines in a row are not folded: each is its own row.
        #expect(TranscriptRow.gap(after: on.rows[on.rows.count - 2], before: on.rows[on.rows.count - 1]) == .betweenLines)
    }

    @Test func aFailedRunIsOneLineWithWhy() {
        let id = UUID()
        let entry = ThreadEntry(id: id, item: .userMessage(text: "bal", action: Self.run(id: id, failed: true)))
        let transcript = Transcript(entries: [entry], showsLines: true)
        guard case .line(let line) = transcript.rows.last?.kind else { Issue.record("no line"); return }
        #expect(line.isFailure)
        #expect(line.leadingText == nil)
        #expect(line.trailingText == "Balcony Lights On failed: no shortcut by that name")
    }

    @Test func aRunningActionIsOneLineAndItsStepsAddNoRows() {
        var transcript = Transcript(showsLines: true)
        let id = UUID()
        transcript.beginActionRun(QuickActionRunStart(entryID: id, date: Date(), text: "bal", name: "Balcony Lights On"))
        let callID = QuickActionRunStart.callID(entryID: id, index: 0)
        transcript.toolStarted(callID)
        transcript.toolRunning(callID, command: "Bash shortcuts run")
        #expect(transcript.rows.filter(\.isTool).isEmpty)
        transcript.apply(ThreadEntry(id: id, item: .userMessage(text: "bal", action: Self.run(id: id, failed: false))))
        let lines = transcript.rows.compactMap { if case .line(let line) = $0.kind { line } else { nil } }
        #expect(lines.map(\.spokenText) == ["Ran Balcony Lights On"], "the running line is filled in where it is")
        // The model's own calls still get rows afterward.
        transcript.toolStarted("call-1")
        #expect(transcript.rows.filter(\.isTool).count == 1)
    }

    @Test func anOpeningAfterTheTimeoutStartsTheEpisodeTheNextMessageJoins() async throws {
        let url = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(replies: [reply("Hi."), reply("Calendar is open.")])
        let thread = try ThreadStore(fileURL: url)
        let loop = AgentLoop(provider: provider, thread: thread, tools: [], episodeTimeout: { 1800 })
        let start = Date()

        try await loop.run("hello", now: start, onEvent: noEvents, confirm: noConfirm)
        try await loop.logAppOpening(ThreadItem.AppOpening(calendarApp), now: start.addingTimeInterval(3600), onEvent: noEvents)
        #expect(await thread.episodes.count == 2, "the opening starts the episode, as a message would")
        try await loop.run("what's open?", now: start.addingTimeInterval(3660), onEvent: noEvents, confirm: noConfirm)
        #expect(await thread.episodes.count == 2, "the message joins it")
        let sent = provider.requests[1].entries.map(\.item)
        #expect(sent.count == 2)
        if case .appOpened = sent.first {} else { Issue.record("the opening goes with the next message") }
    }

    @Test func anOpeningWhoseEpisodeEndsBeforeAMessageIsNeverSent() async throws {
        let url = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let provider = FakeProvider(replies: [reply("Hi."), reply("Hello again.")])
        let thread = try ThreadStore(fileURL: url)
        let loop = AgentLoop(provider: provider, thread: thread, tools: [], episodeTimeout: { 1800 })
        let start = Date()

        try await loop.run("hello", now: start, onEvent: noEvents, confirm: noConfirm)
        try await loop.logAppOpening(ThreadItem.AppOpening(calendarApp), now: start.addingTimeInterval(60), onEvent: noEvents)
        // The episode times out from the opening, and the next message starts a new one.
        try await loop.run("hi", now: start.addingTimeInterval(60 + 1800), onEvent: noEvents, confirm: noConfirm)
        #expect(await thread.episodes.count == 2)
        #expect(provider.requests[1].entries.map(\.item) == [.userMessage(text: "hi")])
        // It stays in the thread, in the episode it was logged in.
        let first = try #require(await thread.episodes.first)
        let kept = await thread.contents.entries(of: first)
        #expect(kept.contains { if case .appOpened = $0.item { true } else { false } })
    }

    @Test func anOpeningAnswersACallLeftWithoutAResultFirst() async throws {
        let url = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let thread = try ThreadStore(fileURL: url)
        try await thread.append(.userMessage(text: "list files"))
        try await thread.append(toolCall("call-1", name: "run_shell_command", arguments: ["command": "ls"]))
        let loop = AgentLoop(provider: FakeProvider(replies: []), thread: thread, tools: [])
        try await loop.logAppOpening(ThreadItem.AppOpening(calendarApp), onEvent: noEvents)
        let items = await thread.entries.map(\.item)
        if case .toolResult(let result) = items[2] { #expect(result.callID == "call-1") } else { Issue.record("no answer") }
        if case .appOpened = items[3] {} else { Issue.record("the opening comes after the answer") }
    }

    @Test func searchFindsOpenings() {
        let text = HistorySearchText.of(.appOpened(ThreadItem.AppOpening(calendarApp)))?.text
        #expect(text?.contains("Calendar") == true)
    }

    static func run(id: UUID, failed: Bool) -> ThreadItem.QuickActionRun {
        let action = QuickAction(
            id: "balcony-lights-on", name: "Balcony Lights On", description: "Turns the balcony lights on.",
            steps: [.init(tool: "run_shell_command", arguments: ["command": "shortcuts run lights", "destructive": false])])
        let step = ThreadItem.QuickActionRun.Step(
            callID: QuickActionRunStart.callID(entryID: id, index: 0), tool: "run_shell_command",
            arguments: action.steps[0].arguments.encodedString(),
            output: failed ? "Error: no shortcut by that name.\n[exit status 1]" : "[exit status 0]")
        return ThreadItem.QuickActionRun(
            id: action.id, name: action.name, stepCount: 1, steps: [step], failedStep: failed ? 0 : nil,
            message: ThreadItem.QuickActionRun.message(typed: "bal", action: action, steps: [step], failedStep: failed ? 0 : nil))
    }
}
