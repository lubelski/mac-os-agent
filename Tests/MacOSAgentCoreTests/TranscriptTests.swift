import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct TranscriptTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    /// Nov 21, 2026, 20:00 in Los Angeles.
    private static let now = Date(timeIntervalSince1970: 1_795_320_000)

    private func entry(_ item: ThreadItem, at date: Date = TranscriptTests.now) -> ThreadEntry {
        ThreadEntry(date: date, item: item)
    }

    private func call(_ id: String, _ command: String) -> ThreadItem {
        .toolCall(.init(callID: id, name: "run_shell_command",
                        arguments: JSONValue.object(["command": .string(command), "destructive": .bool(false)]).encodedString(),
                        provider: "openai", model: "gpt-6-luna"))
    }

    private func reply(_ text: String) -> ThreadItem {
        .assistantMessage(.init(text: text, provider: "openai", model: "gpt-6-luna"))
    }

    @Test func wholeThreadBecomesRowsInOrder() {
        let earlier = Self.now.addingTimeInterval(-3600)
        let entries = [
            entry(.userMessage(text: "turn on dark mode"), at: earlier),
            entry(.providerItem(.init(provider: "openai", model: "gpt-6-luna", payload: ["type": "reasoning"]))),
            entry(call("call_1", "osascript -e 'dark mode'")),
            entry(.toolResult(.init(callID: "call_1", output: "[exit status 0]"))),
            entry(reply("Dark mode is on.")),
            entry(.userMessage(text: "and back")),
            entry(reply("")),
        ]
        let transcript = Transcript(entries: entries, calendar: Self.calendar)
        #expect(transcript.rows.map(\.kind) == [
            .user(text: "turn on dark mode", date: earlier, showsTime: true),
            .tool(command: "osascript -e 'dark mode'", status: .finished, output: "[exit status 0]"),
            .assistant("Dark mode is on."),
            .user(text: "and back", date: Self.now, showsTime: true),
        ])
        #expect(transcript.rows[1].id == "call_1")
        #expect(transcript.rows[0].id == entries[0].id.uuidString)
    }

    @Test func aCallWithoutAResultLoadsAsFinished() {
        let transcript = Transcript(entries: [
            entry(.userMessage(text: "sleep")),
            entry(call("call_1", "sleep 100")),
        ], calendar: Self.calendar)
        #expect(transcript.rows.last?.kind == .tool(command: "sleep 100", status: .finished, output: nil))
    }

    @Test func liveEventsUpdateTheToolRow() {
        var transcript = Transcript(calendar: Self.calendar)
        transcript.apply(entry(.userMessage(text: "list")))
        transcript.toolStarted("call_1")
        transcript.toolStarted("call_1")
        #expect(transcript.rows.count == 2)
        #expect(transcript.rows[1].kind == .tool(command: "", status: .preparing, output: nil))

        transcript.apply(entry(call("call_1", "ls")))
        #expect(transcript.rows[1].kind == .tool(command: "ls", status: .preparing, output: nil))
        transcript.toolRunning("call_1", command: "ls")
        #expect(transcript.rows[1].kind == .tool(command: "ls", status: .running, output: nil))
        transcript.setToolStatus("call_1", .waitingForConfirmation)
        #expect(transcript.rows[1].kind == .tool(command: "ls", status: .waitingForConfirmation, output: nil))
        transcript.apply(entry(.toolResult(.init(callID: "call_1", output: "a\n[exit status 0]"))))
        #expect(transcript.rows[1].kind == .tool(command: "ls", status: .finished, output: "a\n[exit status 0]"))
        #expect(transcript.rows.count == 2)
    }

    @Test func aNewInstructionKeepsEarlierRows() {
        var transcript = Transcript(entries: [entry(.userMessage(text: "one")), entry(reply("first"))], calendar: Self.calendar)
        transcript.apply(entry(.userMessage(text: "two"), at: Self.now.addingTimeInterval(60)))
        transcript.appendNotice("Stopped.", id: "n")
        transcript.appendError("Offline", id: "e")
        #expect(transcript.rows.map(\.kind) == [
            .user(text: "one", date: Self.now, showsTime: true),
            .assistant("first"),
            .user(text: "two", date: Self.now.addingTimeInterval(60), showsTime: false),
            .notice("Stopped."),
            .error("Offline"),
        ])
    }

    @Test func updatesFindTheirRowInALongThread() {
        var entries: [ThreadEntry] = []
        for index in 0..<2_000 {
            entries.append(entry(.userMessage(text: "message \(index)")))
            entries.append(entry(call("call_\(index)", "echo \(index)")))
        }
        var transcript = Transcript(entries: entries, calendar: Self.calendar)
        transcript.apply(entry(.toolResult(.init(callID: "call_7", output: "7\n[exit status 0]"))))
        #expect(transcript.rows.count == 4_000)
        #expect(transcript.rows[15].kind == .tool(command: "echo 7", status: .finished, output: "7\n[exit status 0]"))
    }

    @Test func stretchesStartOnTheFirstMessageANewDayOrALongPause() {
        let calendar = Self.calendar
        let morning = Self.now.addingTimeInterval(-10 * 3600)
        #expect(Transcript.startsNewStretch(previous: nil, current: morning, calendar: calendar))
        #expect(!Transcript.startsNewStretch(previous: morning, current: morning.addingTimeInterval(29 * 60), calendar: calendar))
        #expect(Transcript.startsNewStretch(previous: morning, current: morning.addingTimeInterval(30 * 60), calendar: calendar))
        // 23:50 to 00:05 the next day is a short pause across midnight.
        let lateNight = Self.now.addingTimeInterval(3 * 3600 + 50 * 60)
        #expect(Transcript.startsNewStretch(previous: lateNight, current: lateNight.addingTimeInterval(15 * 60), calendar: calendar))
    }

    @Test func gapsGroupCommandsAndSeparateExchanges() {
        let user = TranscriptRow(id: "u", kind: .user(text: "hi", date: Self.now, showsTime: false))
        let tool = TranscriptRow(id: "t", kind: .tool(command: "ls", status: .finished, output: nil))
        let reply = TranscriptRow(id: "r", kind: .assistant("done"))
        #expect(TranscriptRow.gap(after: nil, before: user) == .none)
        #expect(TranscriptRow.gap(after: user, before: tool) == .regular)
        #expect(TranscriptRow.gap(after: tool, before: tool) == .tight)
        #expect(TranscriptRow.gap(after: tool, before: reply) == .regular)
        #expect(TranscriptRow.gap(after: reply, before: user) == .exchange)
    }

    @Test(arguments: [
        ("a\n[exit status 0]", TranscriptRow.ToolOutcome.succeeded),
        ("oops\n[exit status 1]", .failed),
        ("[exit status 0] and more\n[exit status 2]", .failed),
        ("Declined by the owner.", .unknown),
    ])
    func outcomeComesFromTheExitStatusLine(output: String, outcome: TranscriptRow.ToolOutcome) {
        #expect(TranscriptRow.outcome(ofOutput: output) == outcome)
    }

    @Test func noOutputHasAnUnknownOutcome() {
        #expect(TranscriptRow.outcome(ofOutput: nil) == .unknown)
    }

    @Test(arguments: [
        (TimeInterval(0), "8:00 PM"),
        (-19.5 * 3600, "12:30 AM"),
        (-21 * 3600, "Yesterday 11:00 PM"),
        (-3 * 24 * 3600, "Wednesday 8:00 PM"),
        (-10 * 24 * 3600, "Nov 11, 8:00 PM"),
        (-400 * 24 * 3600, "Oct 17, 2025"),
    ] as [(TimeInterval, String)])
    func timeLabels(offset: TimeInterval, expected: String) {
        let label = TranscriptTimeLabel.text(
            for: Self.now.addingTimeInterval(offset), now: Self.now,
            calendar: Self.calendar, locale: Locale(identifier: "en_US"))
        // Date formatting puts a narrow no-break space before AM and PM.
        #expect(label.replacing("\u{202F}", with: " ") == expected)
    }
}
