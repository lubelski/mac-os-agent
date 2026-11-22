import Foundation
import Testing
@testable import MacOSAgentCore

@Suite struct ToolOutputFormatTests {
    private func shape(_ text: String) -> ToolOutputFormat.Shape {
        ToolOutputFormat.format(text).shape
    }

    private func table(_ text: String) -> ToolOutputFormat.Table? {
        for block in ToolOutputFormat.format(text).blocks {
            if case .table(let table) = block { return table }
        }
        return nil
    }

    // MARK: - Empty, plain, and binary

    @Test(arguments: ["", "   ", "\n\n", "\t \n"])
    func blankOutputIsEmpty(_ text: String) {
        #expect(shape(text) == .empty)
        #expect(ToolOutputFormat.format(text).blocks.isEmpty)
    }

    @Test func proseStaysPlain() {
        let text = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=1234)\t81%; charging; 0:42 remaining present: true"
        let formatted = ToolOutputFormat.format(text)
        #expect(formatted.shape == .plain)
        #expect(formatted.blocks == [.text(text)])
    }

    @Test func oneLineIsPlain() {
        #expect(shape("Set the desktop picture to /Users/owner/Pictures/a.heic on the screen.") == .plain)
        #expect(shape("Copied 12 characters to the clipboard.") == .plain)
    }

    @Test func binaryGarbageIsShownWithVisibleControls() {
        let text = String(decoding: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48], as: UTF8.self)
        let formatted = ToolOutputFormat.format(text)
        #expect(formatted.shape == .binary)
        guard case .text(let shown)? = formatted.blocks.first else { Issue.record("no text"); return }
        #expect(shown.contains("␀"))
        #expect(formatted.note != nil)
    }

    @Test func aFewOddCharactersInLongTextAreNotBinary() {
        let text = String(repeating: "plain words on a line\n", count: 20) + "\u{07}"
        #expect(shape(text) == .plain)
    }

    // MARK: - JSON

    @Test func jsonIsPrettyPrintedInItsOwnKeyOrder() throws {
        let formatted = ToolOutputFormat.format(#"{"zeta":1,"alpha":[true,null,"x"],"mid":{"n":-1.5e3}}"#)
        #expect(formatted.shape == .json)
        guard case .json(let node)? = formatted.blocks.first else { Issue.record("no json"); return }
        #expect(node.prettyText() == """
            {
              "zeta": 1,
              "alpha": [
                true,
                null,
                "x"
              ],
              "mid": {
                "n": -1.5e3
              }
            }
            """)
    }

    @Test(arguments: [
        #"{"a": 1,}"#,
        #"{'a': 1}"#,
        #"{"a": 1} // note"#,
        #"[1, 2"#,
        #"{"a": 01}"#,
        "{\"a\": \"tab\tinside\"}",
        #"{"a": "\q"}"#,
        "{\"a\": NaN}",
    ])
    func almostJSONFallsBackToText(_ text: String) {
        #expect(JSONNode.parse(text) == nil)
        #expect(shape(text) != .json)
    }

    @Test func deepNestingIsRefused() {
        let deep = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        #expect(JSONNode.parse(deep) == nil)
        #expect(shape(deep) == .plain)
    }

    @Test func foldedLinesHideTheInsideOfAContainer() throws {
        let node = try #require(JSONNode.parse(#"{"a":[1,2],"b":{}}"#))
        let open = node.lines(folded: [])
        #expect(open.map(\.text) == ["{", "[", "1,", "2", "],", "{}", "}"])
        #expect(open[1].key == #""a""#)
        let folded = node.lines(folded: ["$.0"])
        #expect(folded.map(\.text) == ["{", "[ … ],", "{}", "}"])
        #expect(node.containerPaths(atDepth: 1) == ["$.0"])
    }

    @Test func jsonLinesBecomeOneDocumentEach() {
        let formatted = ToolOutputFormat.format("{\"a\":1}\n{\"a\":2}\n\n{\"a\":3}\n")
        #expect(formatted.shape == .jsonLines)
        #expect(formatted.blocks.count == 3)
    }

    @Test func jsonLinesWithOneBadLineFallBack() {
        #expect(shape("{\"a\":1}\n{\"a\":2\n{\"a\":3}") == .plain)
    }

    // MARK: - Native field lines

    @Test func theNativeToolsFieldLinesBecomeATable() throws {
        let text = """
            Calendars: Home (default), Work. Times are local to the Mac (America/Los_Angeles, PST).
            Range: Sat 2026-11-21 00:00 to Sat 2026-11-28 00:00.
            2 events, soonest first, as id | title | when | calendar | details:
            3f9a2c1b | Lunch with Sam | Sat 2026-11-21 12:00 to 13:00 | Home | at: Café Luna | notes: bring the book
            77aa01ff | Standup | Mon 2026-11-23 09:30 to 09:45 | Work
            Showing the first 2 of 9. Narrow by calendar to see the others.
            """
        let formatted = ToolOutputFormat.format(text)
        #expect(formatted.shape == .fieldTable)
        #expect(formatted.blocks.count == 3)
        guard case .text(let intro) = formatted.blocks[0], case .table(let table) = formatted.blocks[1], case .text(let after) = formatted.blocks[2] else {
            Issue.record("unexpected blocks \(formatted.blocks)")
            return
        }
        #expect(intro.hasPrefix("Calendars: Home"))
        #expect(intro.hasSuffix("2 events, soonest first."))
        #expect(table.header == ["id", "title", "when", "calendar", "details"])
        // Extra fields join the last column, and missing ones are empty.
        #expect(table.rows[0][4] == "at: Café Luna | notes: bring the book")
        #expect(table.rows[1] == ["77aa01ff", "Standup", "Mon 2026-11-23 09:30 to 09:45", "Work", ""])
        #expect(after.hasPrefix("Showing the first 2"))
    }

    @Test func theApplicationSearchBecomesATable() throws {
        let table = try #require(table("Best match first, as name | bundle identifier | path:\nSafari | com.apple.Safari | /Applications/Safari.app\nSafari Technology Preview | com.apple.SafariTechnologyPreview | /Applications/Safari Technology Preview.app"))
        #expect(table.header == ["name", "bundle identifier", "path"])
        #expect(table.rows.count == 2)
    }

    @Test func aHeadingWithNoRowsIsPlain() {
        #expect(shape("Best match first, as name | bundle identifier | path:") == .plain)
    }

    // MARK: - CSV and TSV

    @Test func csvWithQuotesBecomesATableWithAHeader() throws {
        let table = try #require(table("name,size,kind\n\"Report, final.pdf\",120 KB,PDF\nnotes.txt,4 KB,Text\n"))
        #expect(table.header == ["name", "size", "kind"])
        #expect(table.rows == [["Report, final.pdf", "120 KB", "PDF"], ["notes.txt", "4 KB", "Text"]])
    }

    @Test func raggedCSVStaysText() {
        #expect(shape("a,b,c\n1,2\n3,4,5") != .csv)
    }

    @Test func proseWithCommasStaysText() {
        let text = "Movies is the big one, then Downloads, and then the caches, which macOS clears on its own when space runs low.\nAfter that, the rest is small, mostly documents, and photos, and apps that you use every day of the week."
        #expect(shape(text) != .csv)
    }

    @Test func tabSeparatedSizesHaveNoHeader() throws {
        let table = try #require(table(" 38G\t/Users/owner/Movies\n 12G\t/Users/owner/Downloads\n4.1G\t/Users/owner/Library/Caches"))
        #expect(shape(" 38G\t/Users/owner/Movies\n 12G\t/Users/owner/Downloads") == .tsv)
        #expect(table.header.isEmpty)
        #expect(table.rows.count == 3)
    }

    // MARK: - Aligned columns

    @Test func psOutputBecomesColumnsWithTheCommandLast() throws {
        let text = """
              PID TTY           TIME CMD
            12345 ttys000    0:00.05 -zsh
              901 ttys001    1:02.10 /usr/bin/python3 -m http.server 8000
            """
        let table = try #require(table(text))
        #expect(shape(text) == .columns)
        #expect(table.header == ["PID", "TTY", "TIME", "CMD"])
        #expect(table.rows[1] == ["901", "ttys001", "1:02.10", "/usr/bin/python3 -m http.server 8000"])
    }

    @Test func dfOutputKeepsATwoWordLastHeader() throws {
        let text = """
            Filesystem      Size    Used   Avail Capacity  Mounted on
            /dev/disk3s1s1 926Gi    10Gi   500Gi       3%  /
            /dev/disk3s6   926Gi    20Gi   500Gi       4%  /System/Volumes/VM
            """
        #expect(shape(text) == .columns)
        let table = try #require(table(text))
        #expect(table.header.first == "Filesystem")
        #expect(table.rows[1].first == "/dev/disk3s6")
        #expect(table.rows[1].contains("4%"))
        #expect(table.header.last == "Mounted on")
        #expect(table.rows[1].last == "/System/Volumes/VM")
    }

    @Test func aHeaderThatDoesNotLineUpStaysText() {
        let text = """
            Filesystem      Size    Used   Avail Capacity  Mounted on
            /dev/disk3s1s1  926Gi    10Gi   500Gi     3%    /
            /dev/disk3s6    926Gi    20Gi   500Gi     4%    /System/Volumes/VM
            """
        #expect(shape(text) == .plain)
    }

    @Test func lsofOutputBecomesColumns() throws {
        let text = """
            COMMAND     PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
            Safari      812 owner   23u  IPv4 0x8f2a1c3e9b0d4f11      0t0  TCP 192.168.1.20:51234->17.253.144.10:443 (ESTABLISHED)
            Slack      1022 owner   88u  IPv4 0x8f2a1c3e9b0d6b33      0t0  TCP 192.168.1.20:51301->52.4.21.9:443 (ESTABLISHED)
            """
        let table = try #require(table(text))
        #expect(table.header == ["COMMAND", "PID", "USER", "FD", "TYPE", "DEVICE", "SIZE/OFF", "NODE", "NAME"])
        #expect(table.rows[1].last == "192.168.1.20:51301->52.4.21.9:443 (ESTABLISHED)")
    }

    @Test func raggedColumnsStayText() {
        let text = """
            NAME   SIZE
            alpha  12
            this line crosses every column and has no shape at all
            """
        #expect(shape(text) != .columns)
    }

    // MARK: - Keys and values

    @Test func keyValueBlocksKeepTheirNesting() throws {
        let text = """
            Hardware:

                Hardware Overview:

                  Model Name: MacBook Pro
                  Chip: Apple M5 Max
                  Memory: 64 GB
            """
        let formatted = ToolOutputFormat.format(text)
        #expect(formatted.shape == .keyValue)
        guard case .keyValues(let pairs)? = formatted.blocks.first else { Issue.record("no pairs"); return }
        #expect(pairs.map(\.key) == ["Hardware", "Hardware Overview", "Model Name", "Chip", "Memory"])
        #expect(pairs.map(\.depth) == [0, 1, 2, 2, 2])
        #expect(pairs[3].value == "Apple M5 Max")
    }

    @Test func equalsPairs() {
        #expect(shape("HOME=/Users/owner\nSHELL=/bin/zsh\nLANG=en_US.UTF-8") == .keyValue)
    }

    @Test func proseEndingInColonsIsNotPairs() {
        #expect(shape("Here is what I found in the folder you asked about:\nnothing much really, just a few files\nand some more words") == .plain)
    }

    // MARK: - Diffs, paths, Markdown, mixed

    @Test func unifiedDiffLinesAreClassified() {
        let text = """
            diff --git a/notes.txt b/notes.txt
            --- a/notes.txt
            +++ b/notes.txt
            @@ -1,2 +1,2 @@
             same
            -old
            +new
            """
        let formatted = ToolOutputFormat.format(text)
        #expect(formatted.shape == .diff)
        guard case .diff(let lines)? = formatted.blocks.first else { Issue.record("no diff"); return }
        #expect(lines.map(\.kind) == [.file, .file, .file, .hunk, .context, .removed, .added])
    }

    @Test func listsOfPathsAreRecognized() {
        let formatted = ToolOutputFormat.format("/Applications/Safari.app\n/Applications/Notes.app\n~/Downloads/a.pdf\n")
        #expect(formatted.shape == .paths)
        #expect(formatted.blocks == [.paths(["/Applications/Safari.app", "/Applications/Notes.app", "~/Downloads/a.pdf"])])
    }

    @Test func lsErrorsAmongPathsAreNotAPathList() {
        #expect(shape("/Applications/Safari.app\nls: /Applications/Notion.app: No such file or directory") == .plain)
    }

    @Test func markdownIsHandedToTheMarkdownViews() {
        let text = "# Skill\n\nDoes a thing.\n\n- one\n- two"
        #expect(ToolOutputFormat.format(text) == .init(shape: .markdown, blocks: [.markdown(text)]))
    }

    @Test func aSingleBulletIsNotMarkdown() {
        #expect(shape("- just one dash line\nand some text") == .plain)
    }

    @Test func mixedContentFallsBackToPlain() {
        let text = "{\"ok\": true}\nDone, 3 files changed\n/Users/owner/a.txt"
        #expect(shape(text) == .plain)
    }

    // MARK: - Terminal codes

    @Test func colorCodesAreRemovedAndNoted() {
        let formatted = ToolOutputFormat.format("\u{1B}[1;31merror:\u{1B}[0m something broke\n\u{1B}]8;;https://example.com\u{07}link\u{1B}]8;;\u{07}")
        #expect(formatted.blocks == [.text("error: something broke\nlink")])
        #expect(formatted.note == "Terminal color codes were removed.")
    }

    @Test func carriageReturnProgressShowsTheLastState() {
        #expect(TerminalText.clean("10%\r50%\r100%\ndone\r\n").text == "100%\ndone\n")
        #expect(TerminalText.clean("b\u{08}bo\u{08}old").text == "bold")
    }

    @Test func colorCodedJSONIsStillJSON() {
        #expect(shape("\u{1B}[32m{\"a\": 1}\u{1B}[0m") == .json)
    }

    // MARK: - Size

    @Test func hugeOutputIsPlainWithANote() {
        let huge = String(repeating: "{\"a\": 1}\n", count: ToolOutputFormat.formattingLimit / 8)
        let formatted = ToolOutputFormat.format(huge)
        #expect(formatted.shape == .plain)
        #expect(formatted.note?.contains("Too large") == true)
    }

    @Test func aLongTableStopsAtTheRowLimit() throws {
        var lines = ["name\tsize"]
        for index in 0..<(ToolOutputFormat.tableRowLimit + 50) { lines.append("file\(index)\t\(index)") }
        let table = try #require(table(lines.joined(separator: "\n")))
        #expect(table.rows.count == ToolOutputFormat.tableRowLimit)
        #expect(table.totalRows == ToolOutputFormat.tableRowLimit + 50)
    }

    @Test func detectionOnALargeOutputIsQuick() {
        let line = "12345 ttys000    0:00.05 /usr/bin/some-long-running-process --with --many --arguments\n"
        let big = "  PID TTY           TIME CMD\n" + String(repeating: line, count: 20_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = ToolOutputFormat.format(big) }
        #expect(elapsed < .seconds(5))
    }
}

@Suite struct ToolCallInputTests {
    @Test func aLongPipelineBreaksAtItsOperators() {
        let command = "du -sh ~/Library/Caches ~/Downloads ~/Movies 2>/dev/null | sort -hr | head -n 20 && echo 'done | really; yes'"
        #expect(ToolCallInput.commandLines(command) == [
            "du -sh ~/Library/Caches ~/Downloads ~/Movies 2>/dev/null",
            "  | sort -hr",
            "  | head -n 20",
            "  && echo 'done | really; yes'",
        ])
    }

    @Test(arguments: [
        "ls",
        "echo 'an unfinished quote that is long enough to be broken into parts | if it were safe",
        "cat <<EOF | grep something that makes this long enough to be considered for breaking\nEOF",
        "echo first part of a long command ; echo second # with a comment | that is not a pipe",
        "echo $(printf 'a | b' | tr a b) and some more words so the command is long enough",
    ])
    func unsafeOrShortCommandsAreNotBroken(_ command: String) {
        #expect(ToolCallInput.commandLines(command) == nil)
    }

    @Test func aBackgroundAmpersandIsNotABreak() {
        let command = "some-long-running-server --port 8000 --verbose --log /tmp/server.log & sleep 1 && curl localhost:8000"
        #expect(ToolCallInput.commandLines(command) == [
            "some-long-running-server --port 8000 --verbose --log /tmp/server.log & sleep 1",
            "  && curl localhost:8000",
        ])
    }

    @Test func argumentsBecomeLabeledFieldsInTheModelsOrder() throws {
        let fields = try #require(ToolCallInput.fields(#"{"query":"safari","limit":null,"changes":[{"id":"3f9a2c1b","completed":true}],"note":"line\nbreak"}"#))
        #expect(fields.map(\.name) == ["query", "limit", "changes", "note"])
        #expect(fields[0].value == .text("safari"))
        #expect(fields[1].value == .literal("null"))
        #expect(fields[3].value == .text("line\nbreak"))
        #expect(fields[2].value == .records([[.init(key: "id", value: "3f9a2c1b"), .init(key: "completed", value: "true")]]))
    }

    @Test func anArrayOfFlatObjectsBecomesRecordsWithoutNulls() throws {
        let fields = try #require(ToolCallInput.fields(#"{"changes":[{"id":"3f9a2c1b","completed":true,"title":null},{"id":null,"title":"Water the plants"}]}"#))
        #expect(fields[0].value == .records([
            [.init(key: "id", value: "3f9a2c1b"), .init(key: "completed", value: "true")],
            [.init(key: "title", value: "Water the plants")],
        ]))
        // A nested object inside keeps the JSON view.
        let nested = try #require(ToolCallInput.fields(#"{"changes":[{"id":"a","alarm":{"minutes":5}}]}"#))
        guard case .structured = nested[0].value else { Issue.record("expected JSON"); return }
    }

    @Test func argumentsThatAreNotAnObjectHaveNoFields() {
        #expect(ToolCallInput.fields("[1,2]") == nil)
        #expect(ToolCallInput.fields("{\"a\": ") == nil)
        #expect(ToolCallInput.fields("") == nil)
    }
}

@Suite struct ToolCallInspectionTests {
    private func call(_ output: String?, status: TranscriptRow.ToolStatus = .finished, details: ToolRunDetails? = nil, name: String = ShellCommandTool.name) -> InspectedToolCall {
        InspectedToolCall(
            callID: "c", summary: "x", rowStatus: status, output: output,
            facts: ToolCallFacts(call: .init(callID: "c", name: name, arguments: #"{"command":"x"}"#, provider: "p", model: "m"), details: details))
    }

    @Test func statusComesFromDetailsThenOutput() {
        #expect(call("ok\n[exit status 0]").status == .succeeded)
        #expect(call("no\n[exit status 2]").status == .failed)
        #expect(call(ShellCommandTool.declinedOutput).status == .declined)
        #expect(call("x\n[Stopped after the 120 second limit.]\n[exit status 15]").status == .timedOut)
        #expect(call("x\n[The task was stopped while this command ran.]\n[exit status 15]").status == .stopped)
        #expect(call("The owner declined. Nothing was changed.", name: "change_reminders").status == .declined)
        #expect(call("The owner declined. Safari is still running.", name: "quit_or_hide_application").status == .declined)
        #expect(call("Error: no running app matches", name: "quit_or_hide_application").status == .failed)
        #expect(call("Quit Safari.", name: "quit_or_hide_application").status == .succeeded)
        #expect(call(nil).status == .stopped)
        #expect(call(nil, status: .running).status == .running)
        #expect(call(nil, status: .waitingForConfirmation).status == .waitingForGoAhead)
        #expect(call("x", details: ToolRunDetails(timedOut: true)).status == .timedOut)
    }

    @Test func theTrailerIsReadOnlyWhenItMatchesExactly() {
        let trailer = ToolOutputTrailer("line\n[exit status 3]")
        #expect(trailer.body == "line")
        #expect(trailer.exitStatus == 3)
        #expect(ToolOutputTrailer("(no output)\n[exit status 0]").body == "")
        #expect(ToolOutputTrailer("[exit status x]").exitStatus == nil)
        #expect(ToolOutputTrailer("[exit status 1] and more").body == "[exit status 1] and more")
        let both = ToolOutputTrailer("a\n[Stopped after the 2 second limit.]\n[exit status 15]")
        #expect(both.body == "a")
        #expect(both.timeLimitSeconds == 2)
        #expect(both.noteText == "Stopped at the 2 second limit")
    }

    @Test func metadataForAFullyRecordedCall() {
        let details = ToolRunDetails(
            started: Date(timeIntervalSince1970: 0), seconds: 1.5, waitedSeconds: 0.25, goAhead: .approved,
            source: "Built In", exitStatus: 0, fullCharacters: 40_000)
        let items = call("a\nb\n[exit status 0]", details: details).metadata(now: Date(), timeText: { _ in "9:41 AM" })
        #expect(items == [
            .init("Tool", "run_shell_command, Built In"),
            .init("Status", "Succeeded"),
            .init("Started", "9:41 AM"),
            .init("Took", "1.5 s"),
            .init("Exit status", "0"),
            .init("Go-ahead", "Asked, approved after 250 ms"),
            .init("Output", "2 lines, 3 characters, shortened from 40,000 characters before the model saw it"),
            .init("Call ID", "c"),
        ])
    }

    @Test func theGoAheadOfAToolThatIsNotTheShellShowsWithItsAnswer() {
        let approved = ToolRunDetails(seconds: 2, waitedSeconds: 1.5, goAhead: .approved, source: "Built In")
        let changed = call("Deleted \"Buy eggs\" from Groceries.", details: approved, name: "change_reminders")
        #expect(changed.status == .succeeded)
        #expect(changed.goAheadText == "Asked, approved after 1.5 s")
        let declined = call("The owner declined. Nothing was changed.", details: ToolRunDetails(goAhead: .declined), name: "change_reminders")
        #expect(declined.status == .declined)
        #expect(declined.metadata(now: Date(), timeText: { _ in "" }).contains(.init("Go-ahead", "Asked, declined")))
        // A result stored before go-aheads were recorded still reads as declined.
        #expect(call("The owner declined. Safari is still running.", name: "quit_or_hide_application").goAheadText == "Asked, declined")
        #expect(call(nil, status: .waitingForConfirmation, name: "change_theme").goAheadText == "Asked, waiting for an answer")
    }

    @Test func aRunningCallShowsHowLongItHasRun() {
        var running = call(nil, status: .running)
        running.facts.runningSince = Date(timeIntervalSince1970: 100)
        let items = running.metadata(now: Date(timeIntervalSince1970: 103), timeText: { _ in "now" })
        #expect(items.contains(.init("Running for", "3.0 s")))
        #expect(!items.contains { $0.label == "Output" })
    }

    @Test func theTranscriptKeepsFactsLive() throws {
        var transcript = Transcript()
        let call = ThreadEntry(date: Date(timeIntervalSince1970: 10), item: toolCall("a", name: "search_applications", arguments: ["query": "notes"]))
        transcript.apply(call)
        transcript.toolRunning("a", command: "Search apps", at: Date(timeIntervalSince1970: 11))
        var inspected = try #require(transcript.toolCall("a"))
        #expect(inspected.status == .running)
        #expect(inspected.started == Date(timeIntervalSince1970: 11))
        transcript.apply(ThreadEntry(date: Date(timeIntervalSince1970: 12), item: .toolResult(.init(callID: "a", output: "none"))))
        inspected = try #require(transcript.toolCall("a"))
        #expect(inspected.status == .succeeded)
        #expect(inspected.seconds(now: Date()) == 1)
        #expect(transcript.toolCallIDs == ["a"])
        #expect(transcript.toolCall("missing") == nil)
    }

    @Test func durations() {
        #expect(ToolCallText.duration(0.042) == "42 ms")
        #expect(ToolCallText.duration(3.24) == "3.2 s")
        #expect(ToolCallText.duration(42) == "42 s")
        #expect(ToolCallText.duration(125) == "2 min 5 s")
        #expect(ToolCallText.duration(3840) == "1 h 4 min")
        #expect(ToolCallText.lineCount("a\nb\n") == 2)
        #expect(ToolCallText.lineCount("a\n\nb") == 3)
        #expect(ToolCallText.size(of: "") == "empty")
    }
}
