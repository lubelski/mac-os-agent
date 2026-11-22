import Foundation
import Testing
@testable import MacOSAgentCore

/// Rows rebuilt from the saved thread read as the live rows did, for every built-in tool.
@Suite struct RebuiltToolRowTests {
    /// One call to each built-in tool, in registry order, and the line its row should show.
    static let calls: [(name: String, arguments: JSONValue, row: String)] = [
        (ShellCommandTool.name, ["command": "du -sh ~/Movies", "destructive": false], "du -sh ~/Movies"),
        (SearchApplicationsTool.name, ["query": "zoom"], "Search applications for \"zoom\""),
        (OpenApplicationTool.name, ["bundle_identifier_or_path": "/Applications/Safari.app"], "Open Safari"),
        (ListRunningApplicationsTool.name, [:], "List running applications"),
        (LoadSkillTool.name, ["name": "wallpaper"], "Load the wallpaper skill"),
        (SearchHistoryTool.name, ["query": "dark mode", "limit": nil], "Search history for \"dark mode\""),
        (ReadEpisodeTool.name, ["episode": 3, "from_line": 61], "Read episode 3 from line 61"),
        (ReadRemindersTool.name, ["status": "incomplete", "list": "Groceries", "text": nil, "due_from": nil, "due_to": nil],
         "Read incomplete reminders in Groceries"),
        (ChangeRemindersTool.name, ["changes": [["id": "3f9a2c1b", "delete": true], ["id": "7c21d0e4", "delete": true]]],
         "Change 2 reminders"),
        (ReadEventsTool.name, ["from": "2026-11-21", "to": "2026-11-22", "text": nil], "Read events from 2026-11-21 to 2026-11-22"),
        (ChangeEventsTool.name, ["changes": [["id": nil, "title": "Lunch with Sam", "start": "2026-11-21T12:00"]]],
         "Create event \"Lunch with Sam\""),
        (OpenItemTool.name, ["target": "https://example.com", "application": nil, "reveal_in_finder": false], "Open https://example.com"),
        (FindFilesTool.name, ["name": "receipt", "kind": "pdf", "folder": "~/Downloads", "content": nil], "Find PDFs named \"receipt\" in ~/Downloads"),
        (ReadClipboardTool.name, [:], "Read the clipboard"),
        (WriteClipboardTool.name, ["text": "hello"], "Copy text to the clipboard"),
        (SetDesktopPictureTool.name, ["path": "~/Pictures/sunset.heic"], "Set the desktop picture to ~/Pictures/sunset.heic"),
        (QuitOrHideApplicationTool.name, ["application": "Safari", "action": "quit"], "Quit Safari"),
        (ReadThemesTool.name, ["theme_id": "paper"], "Read the theme paper"),
        (ChangeThemeTool.name, ["action": "save_and_apply", "theme_id": nil, "file": #"{"format": 1, "name": "Night Swim"}"#],
         "Save and apply the theme Night Swim"),
    ]

    private func thread() -> [ThreadEntry] {
        var entries = [ThreadEntry(date: Date(timeIntervalSince1970: 0), item: .userMessage(text: "do things"))]
        for (index, call) in Self.calls.enumerated() {
            entries.append(ThreadEntry(date: Date(timeIntervalSince1970: Double(index + 1)), item: toolCall("call_\(index)", name: call.name, arguments: call.arguments)))
            entries.append(ThreadEntry(date: Date(timeIntervalSince1970: Double(index + 1)), item: .toolResult(.init(callID: "call_\(index)", output: "done"))))
        }
        return entries
    }

    @Test func everyBuiltInToolIsCovered() {
        #expect(Self.calls.map(\.name) == BuiltInTools.names)
    }

    @Test func rebuiltRowsShowEachToolsSummary() throws {
        let tools = ToolRegistry(builtIn: BuiltInTools.make(history: try ThreadStore(fileURL: temporaryThreadFile())))
        let transcript = Transcript(entries: thread(), summaries: tools.summaries)
        let rows = transcript.rows.compactMap { row -> String? in
            if case .tool(let command, _, _) = row.kind { command } else { nil }
        }
        #expect(rows == Self.calls.map(\.row))
        // The same text the live row was given while the call ran.
        for (index, call) in Self.calls.enumerated() {
            let tool = try #require(tools.tools.first { $0.definition.name == call.name })
            #expect(rows[index] == tool.summary(arguments: call.arguments))
        }
        // The default is the built-in tools.
        #expect(Transcript(entries: thread()).rows.map(\.kind) == transcript.rows.map(\.kind))
    }

    @Test func theInspectorAndHistoryReadTheSame() throws {
        let transcript = Transcript(entries: thread())
        for (index, call) in Self.calls.enumerated() {
            #expect(try #require(transcript.toolCall("call_\(index)")).summary == call.row)
        }
        let contents = ThreadContents(entries: thread())
        let episode = try #require(contents.episodes.first)
        let lines = EpisodeLine.lines(of: episode, in: contents).filter { if case .command = $0.kind { true } else { false } }
        #expect(lines.map(\.text) == Self.calls.map(\.row))
    }

    @Test func aToolThatNoLongerExistsShowsItsName() {
        let entries = [
            ThreadEntry(date: Date(), item: toolCall("gone", name: "set_volume", arguments: ["level": 40])),
            ThreadEntry(date: Date(), item: .toolCall(.init(callID: "bad", name: ReadThemesTool.name, arguments: "{not json", provider: "test", model: "m"))),
        ]
        let rows = Transcript(entries: entries).rows.compactMap { row -> String? in
            if case .tool(let command, _, _) = row.kind { command } else { nil }
        }
        #expect(rows == ["set_volume", ReadThemesTool.name])
        // A registry without the tool falls back the same way.
        #expect(ToolCallSummaries([]).summary(name: ShellCommandTool.name, arguments: #"{"command":"ls"}"#) == ShellCommandTool.name)
    }

    @Test func summariesStayShortWithoutTheirArguments() {
        let summaries = ToolCallSummaries.builtIn
        let empty: [String: String] = [
            LoadSkillTool.name: "Load a skill",
            SearchHistoryTool.name: "Search history",
            ReadEpisodeTool.name: "Read an episode",
            SearchApplicationsTool.name: "Search applications",
            OpenApplicationTool.name: "Open an application",
            ChangeRemindersTool.name: "Change reminders",
            ChangeEventsTool.name: "Change events",
            ChangeThemeTool.name: "Save a theme",
        ]
        for (name, expected) in empty {
            #expect(summaries.summary(name: name, arguments: "{}") == expected)
        }
        #expect(summaries.summary(name: ChangeThemeTool.name, arguments: #"{"action":"delete","theme_id":"paper"}"#) == "Delete the theme paper")
        #expect(summaries.summary(name: ChangeRemindersTool.name, arguments: #"{"changes":[{"id":"x","delete":true}]}"#) == "Delete a reminder")
        // No summary is a dump of the arguments.
        for call in Self.calls {
            let line = summaries.summary(name: call.name, arguments: call.arguments.encodedString())
            #expect(!line.contains("{") && line.count <= 80, "\(call.name): \(line)")
        }
    }
}
