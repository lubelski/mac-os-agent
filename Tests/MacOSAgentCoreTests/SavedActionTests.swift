import Foundation
import Synchronization
import Testing
@testable import MacOSAgentCore

/// A stand-in tool for action steps: it records its calls, returns a fixed result, and can ask
/// for a go-ahead the way a destructive call does. It never touches the system.
final class StepTool: AgentTool, @unchecked Sendable {
    let name: String
    let result: String
    let asks: Bool
    private let lock = NSLock()
    private var calls: [JSONValue] = []
    private var answers: [Bool] = []

    init(_ name: String, result: String = "done", asks: Bool = false) {
        self.name = name
        self.result = result
        self.asks = asks
    }

    var received: [JSONValue] { lock.withLock { calls } }
    var goAheadAnswers: [Bool] { lock.withLock { answers } }

    var definition: ToolDefinition {
        ToolDefinition(name: name, description: "A stand-in.", parameters: [
            "type": "object",
            "properties": ["value": ["type": "string"], "count": ["type": ["integer", "null"]]],
            "required": ["value", "count"],
            "additionalProperties": false,
        ])
    }

    func summary(arguments: JSONValue) -> String { "\(name) \(arguments["value"]?.stringValue ?? "")" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        lock.withLock { calls.append(arguments) }
        if asks {
            let approved = await context.confirm(ConfirmationRequest(callID: context.callID, command: name, reason: "deletes files"))
            lock.withLock { answers.append(approved) }
            if !approved { return ShellCommandTool.declinedOutput }
        }
        return result
    }
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private let screensaver = SavedAction(
    id: "start-screensaver", name: "Start Screensaver", description: "Starts the screen saver.",
    phrases: ["screensaver", "screen saver"],
    steps: [.init(tool: "open_application", arguments: ["bundle_identifier_or_path": "/System/Library/CoreServices/ScreenSaverEngine.app"])])

private func step(_ tool: String, _ value: String) -> SavedAction.Step {
    .init(tool: tool, arguments: ["value": .string(value), "count": nil])
}

@Suite struct SavedActionFileTests {
    @Test func aFileRoundTripsAndReadsAsAPersonWouldWriteIt() throws {
        let text = screensaver.fileText
        #expect(text.hasPrefix("{\n  \"format\": 1,\n  \"name\": \"Start Screensaver\","))
        #expect(text.contains("\"tool\": \"open_application\""))
        #expect(try SavedAction.parse(text, id: "start-screensaver") == screensaver)

        let handWritten = """
            {"format": 1, "name": "  Lock  ", "description": "Locks the screen.",
             "steps": [{"tool": "run_shell_command", "arguments": {"command": "pmset displaysleepnow", "destructive": false}}]}
            """
        let action = try SavedAction.parse(handWritten, id: "lock")
        #expect(action.name == "Lock")
        #expect(action.phrases.isEmpty)
        #expect(action.isEnabled, "on unless the file says otherwise")
        #expect(try SavedAction.parse(action.fileText, id: "lock") == action)
    }

    @Test func theLibrarySavesFindsTurnsOffAndDeletes() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SavedActionLibrary(folder: folder)
        #expect(library.entries().isEmpty, "a missing folder is no actions")
        try library.save(screensaver)
        #expect(library.entries().map(\.id) == ["start-screensaver"])
        #expect(library.find("start-screensaver")?.id == "start-screensaver")
        #expect(library.find("Start Screensaver")?.action == screensaver)
        #expect(library.availableActions() == [screensaver])
        try library.setEnabled(false, id: "start-screensaver")
        #expect(library.entry(id: "start-screensaver")?.action?.isEnabled == false)
        #expect(library.availableActions().isEmpty)
        try library.delete(id: "start-screensaver")
        #expect(library.entries().isEmpty)
        #expect(SavedActionLibrary.identifier(for: "Start Screensaver!") == "start-screensaver")
    }

    @Test func aBadFileIsListedWithItsProblemAndTheRestStillLoad() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SavedActionLibrary(folder: folder)
        try library.save(screensaver)
        let files: [String: String] = [
            "broken.json": "{ not json",
            "later.json": #"{"format": 2, "name": "Volume", "description": "Sets the volume.", "parameters": [], "steps": []}"#,
            "no-steps.json": #"{"format": 1, "name": "Nothing", "description": "Does nothing.", "steps": []}"#,
            "Bad Name.json": screensaver.fileText,
            "notes.txt": "not an action",
        ]
        for (name, text) in files { try Data(text.utf8).write(to: folder.appending(path: name)) }

        let entries = library.entries()
        #expect(entries.count == 5, "every .json file is listed, and nothing else")
        let problems = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.problem) })
        #expect(problems["broken"] == "The file is not valid JSON.")
        #expect(problems["later"] == "The file is format 2, and this version of the app reads format 1.")
        #expect(problems["no-steps"] == "The quick action has no steps.")
        #expect(problems["Bad Name"]??.contains("lowercase") == true)
        #expect(problems["start-screensaver"] == .some(nil))
        #expect(library.availableActions() == [screensaver])
    }

    @Test func theNoticeNamesAddedAndChangedActions() {
        let folder = URL(filePath: "/tmp/actions")
        func entry(_ action: SavedAction) -> SavedActionEntry {
            SavedActionEntry(id: action.id, name: action.name, action: action, problem: nil, fileURL: folder.appending(path: action.id + ".json"))
        }
        var changed = screensaver
        changed.phrases = ["saver"]
        let lock = SavedAction(id: "lock", name: "Lock", description: "Locks.", steps: [step("a", "x")])
        #expect(SavedActionLibrary.changeNotice(from: [], to: [entry(screensaver)])
            == "The quick action Start Screensaver is ready to use. Type its name and press Return.")
        #expect(SavedActionLibrary.changeNotice(from: [entry(screensaver)], to: [entry(changed), entry(lock)])
            == "The quick action Lock is ready to use. Type its name and press Return. The quick action Start Screensaver is updated.")
        #expect(SavedActionLibrary.changeNotice(from: [entry(screensaver)], to: [entry(screensaver)]) == nil)
        var off = lock
        off.isEnabled = false
        #expect(SavedActionLibrary.changeNotice(from: [], to: [entry(off)]) == nil, "an action that is off is not offered")
    }
}

@Suite struct ActionMatchingTests {
    static let applications: [InstalledApplication] = [
        ("Safari", "com.apple.Safari"), ("Spotify", "com.spotify.client"), ("Screen Sharing", "com.apple.ScreenSharing"),
        ("Xcode", "com.apple.dt.Xcode"),
    ].map { name, identifier in
        InstalledApplication(name: name, bundleIdentifier: identifier, url: URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory))
    }

    static let spotifyFocus = SavedAction(
        id: "spotify-focus", name: "Spotify Focus", description: "Opens Spotify and hides the rest.",
        steps: [.init(tool: "open_application", arguments: ["bundle_identifier_or_path": "com.spotify.client"])])

    private func engine(_ actions: [SavedAction] = [screensaver, Self.spotifyFocus]) -> InstantActionEngine {
        InstantActionEngine(providers: [
            ActionInstantActions(actions: actions),
            ApplicationInstantActions(applications: Self.applications),
        ])
    }

    @Test func thePhraseOrTheNameOffersTheActionAloneWithAReadingOfItsSteps() throws {
        for input in ["screensaver", "screen saver", "Start Screensaver", "start screensaver", "run screensaver", "screensa"] {
            let suggestion = try #require(engine().suggestion(for: input), "\(input)")
            #expect(suggestion.choices.map(\.title) == ["Start Screensaver"], "\(input)")
            #expect(suggestion.top.target == .action(id: "start-screensaver"))
            #expect(suggestion.top.detail == "Open ScreenSaverEngine")
            #expect(suggestion.top.target.actionLabel == "runs")
        }
    }

    @Test func appsStillOpenAsBeforeBesideActions() throws {
        #expect(engine().suggestion(for: "saf")?.choices.map(\.title) == ["Safari"])
        #expect(engine().suggestion(for: "open xcode")?.choices.map(\.title) == ["Xcode"])
        #expect(engine().suggestion(for: "screen sharing")?.choices.map(\.title) == ["Screen Sharing"])
        #expect(engine().suggestion(for: "what is the screensaver") == nil, "a sentence still goes to the agent")
    }

    @Test func anActionAndAnAppRankTogetherAndLearnedUseDecides() throws {
        let tied = try #require(engine().suggestion(for: "spot"))
        #expect(tied.choices.map(\.title) == ["Spotify Focus", "Spotify"], "a tie goes to the action the owner made")
        var history = InstantActionHistory()
        history.record(ApplicationInstantActions.id(for: Self.applications[1]), subject: "spot", at: Date())
        let learned = try #require(engine().suggestion(for: "spot", history: history))
        #expect(learned.choices.map(\.title) == ["Spotify"], "what the owner took before is offered alone")
    }

    @Test func aLongReadingIsShortened() {
        let many = SavedAction(id: "many", name: "Many", description: "Many steps.",
                               steps: (1...5).map { _ in .init(tool: "read_clipboard", arguments: [:]) })
        #expect(ActionInstantActions.reading(of: many) == "Read the clipboard, then Read the clipboard, and 3 more steps")
    }
}

@Suite struct ActionRunTests {
    private func loop(tools: [any AgentTool], thread: any ThreadStorage = InMemoryThreadStore(), provider: FakeProvider = FakeProvider(replies: [])) -> AgentLoop {
        AgentLoop(provider: provider, thread: thread, tools: tools, instructions: { "Be brief." }, episodeTimeout: { 1800 })
    }

    @Test func stepsRunInOrderAndStopAtTheFirstFailure() async throws {
        let first = StepTool("first")
        let second = StepTool("second", result: "Error: the thing was not there.")
        let third = StepTool("third")
        let thread = InMemoryThreadStore()
        let action = SavedAction(id: "three", name: "Three Steps", description: "Runs three.",
                                 steps: [step("first", "a"), step("second", "b"), step("third", "c")])
        let events = EventLog()
        let entry = try await loop(tools: [first, second, third], thread: thread)
            .runAction(action, typed: "three", onEvent: { events.record($0) })

        #expect(first.received == [["value": "a", "count": nil]])
        #expect(second.received.count == 1)
        #expect(third.received.isEmpty, "nothing runs after a failed step")
        guard case .userMessage(let text, nil, let record?) = entry.item else { Issue.record("not an action's record"); return }
        #expect(text == "three")
        #expect(record.steps.map(\.tool) == ["first", "second"])
        #expect(record.failedStep == 1)
        #expect(record.outcomeNotice == "Three Steps stopped at step 2 of 3. The step after it did not run.")
        #expect(record.message.contains("Step 2 failed, so the app stopped and the 1 after it did not run."))
        let names: [String] = events.events.compactMap { if case .toolCallStarted(_, let name) = $0 { name } else { nil } }
        #expect(names == ["first", "second"])
        #expect(events.events.first.map { if case .actionStarted = $0 { true } else { false } } == true)
        #expect(await thread.entries == [entry], "one entry, the owner's message")
    }

    @Test func aGoAheadIsGivenWithoutAskingAndNoted() async throws {
        let asking = StepTool("asking", asks: true)
        let action = SavedAction(id: "ask", name: "Ask", description: "Asks.", steps: [step("asking", "x")])
        let entry = try await loop(tools: [asking]).runAction(action, typed: "ask", onEvent: { _ in })
        #expect(asking.goAheadAnswers == [true])
        guard case .userMessage(_, _, let record?) = entry.item else { Issue.record("no record"); return }
        #expect(record.failedStep == nil)
        #expect(record.steps[0].goAheadReason == "deletes files")
        #expect(record.steps[0].details?.goAhead == .preapproved)
        #expect(record.steps[0].details?.waitedSeconds == nil)
    }

    @Test func aRefusalThatIsNotAGoAheadStillStopsTheStep() async throws {
        // A theme too hard to read is refused whoever asks. The action does not get past it.
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let themes = ThemeLibrary(folder: folder)
        let change = ChangeThemeTool(library: themes, preferences: ThemePreferences(suiteName: "actions-test-\(UUID().uuidString)"))
        let action = SavedAction(id: "bad-theme", name: "Bad Theme", description: "Saves a bad theme.", steps: [
            .init(tool: "change_theme", arguments: ["action": "delete", "theme_id": "glass", "file": nil]),
        ])
        let entry = try await loop(tools: [change]).runAction(action, typed: "bad theme", onEvent: { _ in })
        guard case .userMessage(_, _, let record?) = entry.item else { Issue.record("no record"); return }
        #expect(record.failedStep == 0)
        #expect(record.steps[0].output.hasPrefix("Error: Glass is a built-in theme"))
    }

    @Test func theRecordIsAPlainUserMessageInTheRequestAndKeepsThePrefix() async throws {
        let thread = InMemoryThreadStore()
        let tool = StepTool("first", result: "Opened it.")
        let provider = FakeProvider(replies: [[.item(assistant("Hi."))], [.item(assistant("I started the screen saver."))]])
        let loop = loop(tools: [tool], thread: thread, provider: provider)
        try await loop.run("hello", onEvent: { _ in }, confirm: { _ in false })
        let before = await thread.entries
        let action = SavedAction(id: "one", name: "One", description: "One step.", steps: [step("first", "a")])
        try await loop.runAction(action, typed: "one", onEvent: { _ in })
        #expect(provider.requests.count == 1, "running an action asks the model nothing")
        try await loop.run("what did you just do", onEvent: { _ in }, confirm: { _ in false })

        let request = try #require(provider.requests.last)
        #expect(Array(request.entries.prefix(before.count)) == before, "everything before the run is sent as it was")
        let input = OpenAIResponses.input(for: request, model: "test-model")
        #expect(!input.contains { $0["type"]?.stringValue == "function_call" || $0["type"]?.stringValue == "function_call_output" },
                "no call without a model turn that made it")
        let users = input.filter { $0["role"]?.stringValue == "user" }
        #expect(users.count == 3)
        let note = try #require(users[1]["content"]?.arrayValue?.first?["text"]?.stringValue)
        #expect(note.contains("<action_run>"))
        #expect(note.contains(#"ran their quick action "One" (one) from the instant row"#))
        #expect(note.contains(#"Step 1 of 1: first {"count":null,"value":"a"}"#))
        #expect(note.contains("Result: Opened it."))
    }

    @Test func theRecordIsKeptAndReadsBackAsRowsAndAsAPlainMessageForOlderBuilds() async throws {
        let file = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let thread = try ThreadStore(fileURL: file)
        let action = SavedAction(id: "two", name: "Two", description: "Two steps.", steps: [step("first", "a"), step("second", "b")])
        let entry = try await loop(tools: [StepTool("first"), StepTool("second", result: "Error: no.")], thread: thread)
            .runAction(action, typed: "two", onEvent: { _ in })

        let reopened = try ThreadStore(fileURL: file)
        let stored = await reopened.entries
        #expect(stored.map(\.id) == [entry.id])
        // Dates are kept to the second, so compare what the record says.
        guard case .userMessage("two", nil, let record?) = stored.first?.item else { Issue.record("no record"); return }
        #expect(record.steps.map(\.output) == ["done", "Error: no."])
        let transcript = Transcript(entries: stored)
        #expect(transcript.rows.count == 5)
        guard case .user(let typed, _, _) = transcript.rows[1].kind else { Issue.record("no owner's row"); return }
        #expect(typed == "two")
        #expect(transcript.rows[2].id == ActionRunStart.callID(entryID: entry.id, index: 0))
        #expect(transcript.rows[4].kind == .error("Two stopped at step 2 of 2."))
        #expect(transcript.toolCall(transcript.rows[3].id)?.facts.call?.name == "second")

        // A build from before actions reads the line's value as text and nothing else.
        struct OlderUserText: Decodable { var text: String }
        struct OlderItem: Decodable { var type: String; var value: OlderUserText }
        struct OlderLine: Decodable { var item: OlderItem }
        let line = try #require(String(contentsOf: file, encoding: .utf8).split(separator: "\n").first)
        let older = try JSONDecoder().decode(OlderLine.self, from: Data(line.utf8))
        #expect(older.item.type == "user_message")
        #expect(older.item.value.text == "two")
    }

    /// Lines written before saved actions became quick actions: a run whose note says "saved
    /// action", and the agent saving one with the tool's old name. They read as they did, and the
    /// model is sent exactly what it was sent then.
    @Test func linesFromBeforeTheRenameStillRead() async throws {
        let file = temporaryThreadFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let note = #"<action_run>\nThe person typed \"screensaver\" and ran their saved action \"Start Screensaver\" (start-screensaver) from the instant row. The app ran its steps itself, without you. Choosing it from the list was their go-ahead, so nothing asked.\nStep 1 of 1: open_application {\"bundle_identifier_or_path\":\"\/System\/Library\/CoreServices\/ScreenSaverEngine.app\"}\nResult: Opened ScreenSaverEngine.\nIt finished.\nNo reply was asked for. This is a record, so you know it happened if they refer to it.\n<\/action_run>"#
        let lines = [
            #"{"date":"2026-11-21T10:00:00Z","id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","item":{"type":"tool_call","value":{"arguments":"{\"operation\":\"save\",\"action_id\":null,\"file\":\"{\\\"format\\\": 1, \\\"name\\\": \\\"Start Screensaver\\\"}\"}","callID":"call-1","model":"gpt-test","name":"change_action","provider":"openai"}}}"#,
            #"{"date":"2026-11-21T10:00:01Z","id":"6F9619FF-8B86-D011-B42D-00C04FC96500","item":{"type":"tool_result","value":{"callID":"call-1","output":"Saved Start Screensaver as start-screensaver."}}}"#,
            #"{"date":"2026-11-21T10:01:00Z","id":"6F9619FF-8B86-D011-B42D-00C04FC96501","item":{"type":"user_message","value":{"action":{"id":"start-screensaver","message":""# + note + #"","name":"Start Screensaver","stepCount":1,"steps":[{"arguments":"{\"bundle_identifier_or_path\":\"\/System\/Library\/CoreServices\/ScreenSaverEngine.app\"}","callID":"6F9619FF-8B86-D011-B42D-00C04FC96501-step-1","output":"Opened ScreenSaverEngine.","tool":"open_application"}]},"text":"screensaver"}}}"#,
        ]
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let thread = try ThreadStore(fileURL: file)
        #expect(await thread.unreadableLineCount == 0)
        let entries = await thread.entries
        #expect(entries.count == 3)
        guard case .toolCall(let call) = entries[0].item else { Issue.record("no call"); return }
        #expect(call.name == "change_action")
        #expect(ToolCallSummaries.builtIn.summary(of: call) == "Save the quick action Start Screensaver",
                "a call under the old name reads as the renamed tool's summary")
        guard case .userMessage("screensaver", nil, let record?) = entries[2].item else { Issue.record("no record"); return }
        #expect(record.failedStep == nil)
        let sent = ThreadItem.modelText(text: "screensaver", skill: nil, action: record)
        #expect(sent.hasPrefix("<action_run>\nThe person typed \"screensaver\" and ran their saved action"), "the model is sent the note as it was stored")
        #expect(sent.hasSuffix("</action_run>"))

        let transcript = Transcript(entries: entries)
        let kinds = transcript.rows.map(\.kind)
        #expect(kinds.contains { if case .tool("Save the quick action Start Screensaver", .finished, _) = $0 { true } else { false } })
        #expect(kinds.contains { if case .user("screensaver", _, _) = $0 { true } else { false } })
        #expect(kinds.contains { if case .tool("Open ScreenSaverEngine", .finished, "Opened ScreenSaverEngine.") = $0 { true } else { false } })

        // The request carries the old call and the old note unchanged, so the cached prefix holds.
        let input = OpenAIResponses.input(for: ModelRequest(instructions: "", entries: entries, tools: []), model: "gpt-test")
        #expect(input.contains { $0["type"]?.stringValue == "function_call" && $0["name"]?.stringValue == "change_action" })
        #expect(input.contains { $0["content"]?.arrayValue?.first?["text"]?.stringValue?.hasSuffix(sent) == true })
    }

    @Test func aRunAfterTheTimeoutStartsANewEpisodeFirst() async throws {
        let thread = InMemoryThreadStore()
        let provider = FakeProvider(replies: [[.item(assistant("Hi."))]])
        let loop = loop(tools: [StepTool("first")], thread: thread, provider: provider)
        let start = Date()
        try await loop.run("hello", now: start, onEvent: { _ in }, confirm: { _ in false })
        let action = SavedAction(id: "one", name: "One", description: "One step.", steps: [step("first", "a")])
        try await loop.runAction(action, typed: "one", now: start.addingTimeInterval(3600), onEvent: { _ in })
        let entries = await thread.entries
        #expect(entries.count == 4)
        #expect(entries[2].item == .episodeStart(.init(reason: .timeout)))
        let current = await thread.contents.currentEpisodeEntries
        #expect(current.last?.id == entries[3].id)
        #expect(!current.contains { $0.id == entries[0].id }, "the earlier episode is not sent")
    }
}

@Suite struct ActionValidationTests {
    private let definitions = [StepTool("first").definition, ShellCommandTool().definition]

    private func problems(_ steps: [SavedAction.Step]) -> [String] {
        ActionValidation.problems(SavedAction(id: "x", name: "X", description: "X.", steps: steps), tools: definitions)
    }

    @Test func everyStepMustNameARealToolWithArgumentsThatFit() {
        #expect(problems([step("first", "a")]).isEmpty)
        #expect(problems([.init(tool: "missing", arguments: [:])]) == ["Step 1 (missing): there is no tool named missing."])
        #expect(problems([.init(tool: "first", arguments: ["value": 3, "count": nil])])
            == ["Step 1 (first): arguments.value should be string, not a number."])
        #expect(problems([.init(tool: "first", arguments: ["value": "a"])]) == ["Step 1 (first): arguments is missing count."])
        #expect(problems([.init(tool: "first", arguments: ["value": "a", "count": .number(1.5)])])
            == ["Step 1 (first): arguments.count should be integer or null, not a number."])
        #expect(problems([.init(tool: "first", arguments: ["value": "a", "count": nil, "extra": true])])
            == ["Step 1 (first): arguments has extra, which the tool does not take."])
        #expect(problems([.init(tool: "change_quick_action", arguments: [:])]) == ["Step 1 (change_quick_action): a quick action cannot call change_quick_action."])
    }

    @Test func aShellStepThatWouldAskIsNotedNotRefused() {
        let remove = SavedAction.Step(tool: ShellCommandTool.name, arguments: ["command": "rm ~/Desktop/old.txt", "destructive": false])
        #expect(problems([remove]).isEmpty)
        #expect(ActionValidation.goAheadNote(remove) == "deletes files")
        let list = SavedAction.Step(tool: ShellCommandTool.name, arguments: ["command": "ls ~", "destructive": false])
        #expect(ActionValidation.goAheadNote(list) == nil)
        let marked = SavedAction.Step(tool: ShellCommandTool.name, arguments: ["command": "ls ~", "destructive": true])
        #expect(ActionValidation.goAheadNote(marked) == "is marked as destructive")
    }

    @Test func changeActionChecksASaveInFullAndDeletingAsks() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SavedActionLibrary(folder: folder)
        let definitions = definitions
        let tool = ChangeActionTool(library: library, tools: { definitions })
        let context = ToolRunContext(callID: "c", confirm: { _ in false })

        let bad = #"{"format": 1, "name": "Bad", "description": "Bad.", "steps": [{"tool": "nope", "arguments": {}}]}"#
        let refused = await tool.run(arguments: ["operation": "save", "action_id": nil, "file": .string(bad)], context: context)
        #expect(refused == "Error: the quick action was not saved.\n- Step 1 (nope): there is no tool named nope.\nFix those and save again.")
        #expect(library.entries().isEmpty, "nothing malformed reaches the folder")

        let malformed = await tool.run(arguments: ["operation": "save", "action_id": nil, "file": "{"], context: context)
        #expect(malformed == "Error: the quick action was not saved. The file is not valid JSON.")

        let good = #"""
            {"format": 1, "name": "Clean Desktop", "description": "Removes old.txt.", "phrases": ["tidy"],
             "steps": [{"tool": "run_shell_command", "arguments": {"command": "rm ~/Desktop/old.txt", "destructive": true}}]}
            """#
        let saved = await tool.run(arguments: ["operation": "save", "action_id": nil, "file": .string(good)], context: context)
        #expect(saved == """
            Saved Clean Desktop as clean-desktop. Typing "Clean Desktop" in the panel offers it, and Return runs it.
            Step 1 deletes files. It runs without asking when the owner runs the quick action, since choosing it is the go-ahead.
            """)
        #expect(library.entry(id: "clean-desktop")?.action?.phrases == ["tidy"])
        let again = await tool.run(arguments: ["operation": "save", "action_id": nil, "file": .string(good)], context: context)
        #expect(again.hasPrefix("Error: a quick action with the id clean-desktop already exists."))

        let declined = await tool.run(arguments: ["operation": "delete", "action_id": "clean-desktop", "file": nil], context: context)
        #expect(declined == "The owner declined. Clean Desktop is still there.")
        let yes = ToolRunContext(callID: "d", confirm: { $0.kind == .deleteAction })
        let deleted = await tool.run(arguments: ["operation": "delete", "action_id": "clean-desktop", "file": nil], context: yes)
        #expect(deleted == "Deleted Clean Desktop.")
        #expect(library.entries().isEmpty)
    }

    @Test func readActionsListsThemAndShowsAFile() async throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = SavedActionLibrary(folder: folder)
        try library.save(screensaver)
        let read = ReadActionsTool(library: library)
        let context = ToolRunContext(callID: "c", confirm: { _ in false })
        let list = await read.run(arguments: ["action_id": nil], context: context)
        #expect(list.contains("- start-screensaver: Start Screensaver, on, Starts the screen saver. Also typed as: screensaver, screen saver."))
        #expect(list.contains("A quick action file is JSON with \"format\": 1"))
        let one = await read.run(arguments: ["action_id": "start-screensaver"], context: context)
        #expect(one.hasSuffix(screensaver.fileText))
    }

    @Test func theActionToolsAreSmallStrictAndTheInstructionsSayWhatAnActionIs() {
        let tools = BuiltInTools.make(applicationWorkspace: FakeApplicationWorkspace(installed: []), system: FakeSystemControl())
        var characters = 0
        for tool in tools.suffix(2) {
            let definition = tool.definition
            #expect(tool.source == .actions)
            #expect(definition.parameters["additionalProperties"] == false)
            let encoded: JSONValue = ["type": "function", "name": .string(definition.name), "description": .string(definition.description), "parameters": definition.parameters, "strict": true]
            characters += encoded.encodedString().count
        }
        print("action tools add \(characters) characters to each request")
        #expect(characters < 1200)
        let text = AgentInstructions.fixed(skills: [], skillsFolder: URL(filePath: "/tmp/skills"))
        #expect(text.contains("A quick action is a fixed tool call"))
        #expect(text.contains("\"make that instant\""))
        #expect(text.contains("Use a skill instead when the task needs judgment each time."))
        #expect(!AgentInstructions.incognitoFixed.contains("action"), "the incognito window has no actions")
    }
}

/// The quick actions folder was `actions/` before. It is renamed once at launch, and only when
/// `quick-actions/` is not there yet. Each test uses a temporary data folder.
@Suite struct QuickActionsFolderMoveTests {
    private func dataFolder() throws -> URL {
        let folder = temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func theFolderIsCalledQuickActions() {
        #expect(AgentPaths.actionsFolder.lastPathComponent == "quick-actions")
    }

    @Test func theOldFolderIsRenamedOnce() throws {
        let data = try dataFolder()
        defer { try? FileManager.default.removeItem(at: data) }
        try write("{}", to: data.appending(path: "actions/start-screensaver.json"))

        #expect(SavedActionLibrary.moveFolderFromOldName(in: data) == .moved)
        #expect(!FileManager.default.fileExists(atPath: data.appending(path: "actions").path(percentEncoded: false)))
        #expect(read(data.appending(path: "quick-actions/start-screensaver.json")) == "{}")
        #expect(SavedActionLibrary.moveFolderFromOldName(in: data) == .nothingToMove, "the next launch has nothing to do")
        #expect(SavedActionLibrary.moveFolderFromOldName(in: data).problem == nil)
    }

    @Test func withNeitherFolderNothingHappens() throws {
        let data = try dataFolder()
        defer { try? FileManager.default.removeItem(at: data) }
        #expect(SavedActionLibrary.moveFolderFromOldName(in: data) == .nothingToMove)
        #expect(try FileManager.default.contentsOfDirectory(atPath: data.path(percentEncoded: false)).isEmpty)
    }

    @Test func withBothFoldersNeitherIsTouchedAndTheNewOneIsUsed() throws {
        let data = try dataFolder()
        defer { try? FileManager.default.removeItem(at: data) }
        try write("old", to: data.appending(path: "actions/lock.json"))
        try write("new", to: data.appending(path: "quick-actions/lock.json"))

        let move = SavedActionLibrary.moveFolderFromOldName(in: data)
        #expect(move == .bothExist)
        #expect(read(data.appending(path: "actions/lock.json")) == "old")
        #expect(read(data.appending(path: "quick-actions/lock.json")) == "new")
        let problem = try #require(move.problem)
        #expect(problem == "The data folder has both actions/ and quick-actions/. The app uses quick-actions/ and leaves actions/ as it is.")
        #expect(!problem.contains("lock"), "it names the folders, never what is in them")
    }

    @Test func aFileNamedActionsIsNotMoved() throws {
        let data = try dataFolder()
        defer { try? FileManager.default.removeItem(at: data) }
        try write("not a folder", to: data.appending(path: "actions"))
        #expect(SavedActionLibrary.moveFolderFromOldName(in: data) == .nothingToMove)
        #expect(read(data.appending(path: "actions")) == "not a folder")
    }
}
