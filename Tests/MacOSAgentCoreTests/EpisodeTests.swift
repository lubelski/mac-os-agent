import Foundation
import Testing
@testable import MacOSAgentCore

/// A thread file exactly as the app wrote it before episodes existed: no markers.
/// Three stretches, split by pauses of an hour and of a day.
let legacyThreadText = """
    {"date":"2026-11-18T17:41:00Z","id":"00000000-0000-0000-0000-000000000001","item":{"type":"user_message","value":{"text":"what's eating my disk space"}}}
    {"date":"2026-11-18T17:41:05Z","id":"00000000-0000-0000-0000-000000000002","item":{"type":"tool_call","value":{"arguments":"{\\"command\\":\\"du -sh ~/Movies\\",\\"destructive\\":false}","callID":"call_1","model":"gpt-6-luna","name":"run_shell_command","provider":"openai","providerID":"fc_1"}}}
    {"date":"2026-11-18T17:41:07Z","id":"00000000-0000-0000-0000-000000000003","item":{"type":"tool_result","value":{"callID":"call_1","output":" 38G\\t/Users/owner/Movies\\n[exit status 0]"}}}
    {"date":"2026-11-18T17:41:09Z","id":"00000000-0000-0000-0000-000000000004","item":{"type":"assistant_message","value":{"model":"gpt-6-luna","provider":"openai","providerData":{"phase":"final_answer"},"providerID":"msg_1","text":"Movies is the big one at 38 GB."}}}
    {"date":"2026-11-18T17:55:00Z","id":"00000000-0000-0000-0000-000000000005","item":{"type":"user_message","value":{"text":"and Downloads?"}}}
    {"date":"2026-11-18T17:55:04Z","id":"00000000-0000-0000-0000-000000000006","item":{"type":"assistant_message","value":{"model":"gpt-6-luna","provider":"openai","text":"Downloads is 12 GB."}}}
    {"date":"2026-11-18T18:55:04Z","id":"00000000-0000-0000-0000-000000000007","item":{"type":"user_message","value":{"text":"turn on dark mode\\nplease"}}}
    {"date":"2026-11-18T18:55:09Z","id":"00000000-0000-0000-0000-000000000008","item":{"type":"assistant_message","value":{"model":"gpt-6-luna","provider":"openai","text":"Dark mode is on."}}}
    {"date":"2026-11-19T18:55:09Z","id":"00000000-0000-0000-0000-000000000009","item":{"type":"user_message","value":{"text":"how long until my battery is full"}}}
    {"date":"2026-11-19T18:55:14Z","id":"00000000-0000-0000-0000-00000000000A","item":{"type":"assistant_message","value":{"model":"gpt-6-luna","provider":"openai","text":"About 42 minutes."}}}

    """

func writeLegacyThread() throws -> URL {
    let file = temporaryThreadFile()
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(legacyThreadText.utf8).write(to: file)
    return file
}

@Suite struct EpisodeTests {
    @Test func aThreadWithoutMarkersLoadsUnchangedWithDerivedEpisodes() async throws {
        let file = try writeLegacyThread()
        let index = file.deletingLastPathComponent().appending(path: "history-index.sqlite")
        let before = try Data(contentsOf: file)

        let store = try ThreadStore(fileURL: file, searchIndexURL: index)
        #expect(await store.unreadableLineCount == 0)
        #expect(await store.entries.count == 10)
        #expect(try Data(contentsOf: file) == before)

        let episodes = await store.episodes
        #expect(episodes.map(\.number) == [1, 2, 3])
        #expect(episodes.map(\.range) == [0..<6, 6..<8, 8..<10])
        #expect(episodes.map(\.preview) == ["what's eating my disk space", "turn on dark mode", "how long until my battery is full"])
        #expect(episodes.map(\.messageCount) == [4, 2, 2])
        #expect(episodes.map(\.commandCount) == [1, 0, 0])
        #expect(episodes[0].id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(episodes[2].lastActivity == ISO8601DateFormatter().date(from: "2026-11-19T18:55:14Z"))

        // Reading the old thread through the index, and opening it again, never touches the file.
        _ = await store.search("dark mode")
        _ = try ThreadStore(fileURL: file, searchIndexURL: index)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func theFirstMessageAfterAnUpgradeAddsAMarkerAtTheEndOnly() async throws {
        let file = try writeLegacyThread()
        let before = try Data(contentsOf: file)
        let store = try ThreadStore(fileURL: file)
        let provider = FakeProvider(replies: [[.item(assistant("Hello again"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [])

        try await loop.run("hello", onEvent: { _ in }, confirm: { _ in true })

        let after = try Data(contentsOf: file)
        #expect(after.prefix(before.count) == before)
        #expect(await store.episodes.count == 4)
        #expect(provider.requests[0].entries.map(\.item) == [.userMessage(text: "hello")])
        let reloaded = try ThreadStore(fileURL: file)
        #expect(await reloaded.episodes.map(\.range) == [0..<6, 6..<8, 8..<10, 10..<13])
    }

    @Test func aMarkerIsOneJSONLineThatRoundTrips() throws {
        let entry = ThreadEntry(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!,
            date: Date(timeIntervalSince1970: 1_795_320_000),
            item: .episodeStart(.init(reason: .timeout)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let text = String(decoding: try encoder.encode(entry), as: UTF8.self)
        #expect(text == #"{"date":"2026-11-22T04:00:00Z","id":"00000000-0000-0000-0000-0000000000FF","item":{"type":"episode_start","value":{"reason":"timeout"}}}"#)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ThreadEntry.self, from: Data(text.utf8)) == entry)
    }

    @Test func markersDivideTheThreadAndPausesNoLongerDoAfterTheFirst() {
        let start = Date(timeIntervalSince1970: 1_795_320_000)
        let entries = [
            ThreadEntry(date: start, item: .userMessage(text: "one")),
            ThreadEntry(date: start.addingTimeInterval(60), item: .episodeStart(.init(reason: .requested))),
            ThreadEntry(date: start.addingTimeInterval(60), item: .userMessage(text: "two")),
            // A long pause after a marker is the live app's call, recorded by a marker or not at all.
            ThreadEntry(date: start.addingTimeInterval(5 * 3600), item: .userMessage(text: "still two")),
        ]
        let contents = ThreadContents(entries: entries)
        #expect(contents.episodes.map(\.range) == [0..<1, 1..<4])
        #expect(contents.currentEpisodeEntries.map(\.item) == [.userMessage(text: "two"), .userMessage(text: "still two")])
        #expect(contents.episode(containing: 0)?.number == 1)
        #expect(contents.episode(containing: 3)?.number == 2)
        #expect(contents.episode(containing: 4) == nil)
    }

    @Test func idlenessCountsFromTheLastActivity() {
        let start = Date(timeIntervalSince1970: 1_795_320_000)
        let contents = ThreadContents(entries: [
            ThreadEntry(date: start, item: .userMessage(text: "go")),
            ThreadEntry(date: start.addingTimeInterval(20 * 60), item: .toolResult(.init(callID: "a", output: "slow"))),
        ])
        let episode = try! #require(contents.currentEpisode)
        #expect(!episode.hasTimedOut(now: start.addingTimeInterval(49 * 60), timeout: 30 * 60))
        #expect(episode.hasTimedOut(now: start.addingTimeInterval(50 * 60), timeout: 30 * 60))
        #expect(!ThreadContents().currentEpisode.map { $0.hasTimedOut(now: start, timeout: 0) }.isTrue)
    }

    @Test func theTimeoutSettingDefaultsToThirtyMinutes() throws {
        let defaults = try #require(UserDefaults(suiteName: "mac-os-agent-tests-\(UUID().uuidString)"))
        #expect(EpisodeTimeoutSetting.minutes(defaults) == 30)
        #expect(EpisodeTimeoutSetting.current(defaults) == 1800)
        EpisodeTimeoutSetting.set(minutes: 120, defaults)
        #expect(EpisodeTimeoutSetting.current(defaults) == 7200)
    }
}

@Suite struct EpisodeLoopTests {
    private func store() throws -> ThreadStore { try ThreadStore(fileURL: temporaryThreadFile()) }

    @Test func withinTheTimeoutTheEpisodeContinues() async throws {
        let store = try store()
        let provider = FakeProvider(replies: [[.item(assistant("one"))], [.item(assistant("two"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [], episodeTimeout: { 1800 })
        let start = Date()

        try await loop.run("first", now: start, onEvent: { _ in }, confirm: { _ in true })
        try await loop.run("second", now: start.addingTimeInterval(29 * 60), onEvent: { _ in }, confirm: { _ in true })

        #expect(await store.episodes.count == 1)
        #expect(provider.requests[1].entries.map(\.item) == [.userMessage(text: "first"), assistant("one"), .userMessage(text: "second")])
    }

    @Test func afterTheTimeoutOnlyTheNewEpisodeIsSent() async throws {
        let store = try store()
        let provider = FakeProvider(replies: [
            [.item(assistant("one"))],
            [.item(toolCall("a", name: "record", arguments: [:]))],
            [.item(assistant("two"))],
        ])
        let loop = AgentLoop(provider: provider, thread: store, tools: [RecordingTool()], instructions: { "Be brief." }, episodeTimeout: { 1800 })
        let log = EventLog()
        let start = Date().addingTimeInterval(-3600)

        try await loop.run("first", now: start, onEvent: { _ in }, confirm: { _ in true })
        // Replies are stamped with the real time, so the pause counts from now.
        try await loop.run("second", now: Date().addingTimeInterval(31 * 60), onEvent: { log.record($0) }, confirm: { _ in true })

        let items = await store.entries.map(\.item)
        #expect(items[2] == .episodeStart(.init(reason: .timeout)))
        #expect(await store.episodes.count == 2)
        // The new episode starts with just the instructions, the tools, and the new message.
        #expect(provider.requests[1].instructions == "Be brief.")
        #expect(provider.requests[1].entries.map(\.item) == [.userMessage(text: "second")])
        // Within it the request only grows at the end.
        let first = provider.requests[1].entries
        #expect(Array(provider.requests[2].entries.prefix(first.count)) == first)
        #expect(provider.requests[2].entries.count == 3)
        // The panel hears about the marker so it can draw the separator.
        guard case .entryAdded(let marker) = log.events.first, case .episodeStart = marker.item else {
            Issue.record("the marker came first: \(log.events)")
            return
        }
    }

    @Test func askingForAFreshStartAddsARequestedMarker() async throws {
        let store = try store()
        let provider = FakeProvider(replies: [[.item(assistant("one"))], [.item(assistant("two"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [])

        try await loop.run("first", startsNewEpisode: true, onEvent: { _ in }, confirm: { _ in true })
        // Nothing to start fresh from on an empty thread, so no marker.
        #expect(await store.entries.count == 2)
        try await loop.run("second", startsNewEpisode: true, onEvent: { _ in }, confirm: { _ in true })

        #expect(await store.entries.map(\.item)[2] == .episodeStart(.init(reason: .requested)))
        #expect(provider.requests[1].entries.map(\.item) == [.userMessage(text: "second")])
    }

    @Test func aCallLeftOpenInAnEarlierEpisodeIsLeftAlone() async throws {
        let store = try store()
        let old = Date().addingTimeInterval(-7200)
        try await store.append(.userMessage(text: "earlier"), date: old)
        try await store.append(toolCall("lost", name: "record", arguments: [:]), date: old)
        let provider = FakeProvider(replies: [[.item(assistant("ok"))]])
        let loop = AgentLoop(provider: provider, thread: store, tools: [])

        try await loop.run("later", onEvent: { _ in }, confirm: { _ in true })

        #expect(provider.requests[0].entries.map(\.item) == [.userMessage(text: "later")])
        #expect(await store.unansweredToolCalls().isEmpty)
    }

    @Test func theOpenAIInputLeavesMarkersOut() {
        let request = ModelRequest(instructions: "x", entries: [
            ThreadEntry(item: .episodeStart(.init(reason: .requested))),
            ThreadEntry(item: .userMessage(text: "hi")),
        ], tools: [])
        #expect(OpenAIResponses.input(for: request, model: "gpt-6-luna").count == 2)
    }
}

@Suite struct InstructionsForEpisodesTests {
    @Test func theFixedPartTellsTheAgentAboutEarlierEpisodes() {
        let text = AgentInstructions.fixed(skills: [], skillsFolder: URL(filePath: "/tmp/skills"))
        #expect(text.contains("You see only the current episode."))
        #expect(text.contains("call search_history"))
        #expect(text.contains("read_episode"))
        #expect(!text.contains("incognito"))
    }

    @Test func theIncognitoWindowHasItsOwnFixedPart() {
        let folder = URL(filePath: "/tmp/skills")
        let kept = AgentInstructions.assemble(editable: "Hi.", skills: [.init(name: "tidy", description: "Tidies.")], skillsFolder: folder)
        let incognito = AgentInstructions.assembleIncognito(editable: "Hi.")
        // The owner's editable part comes first, as in the main panel.
        #expect(incognito.hasPrefix("Hi.\n\n"))
        #expect(incognito == "Hi.\n\n" + AgentInstructions.incognitoFixed)
        #expect(incognito != kept)
        // Byte for byte the same each time, so the cache holds.
        #expect(AgentInstructions.assembleIncognito(editable: "Hi.") == incognito)
        // It names its three tools, says nothing is kept, and points to the main panel.
        for name in BuiltInTools.incognitoNames { #expect(incognito.contains(name)) }
        #expect(incognito.contains("Nothing from it is kept."))
        #expect(incognito.contains("main panel"))
        // Skills, the shell, and history are the main panel's.
        #expect(!AgentInstructions.incognitoFixed.contains("tidy"))
        #expect(!AgentInstructions.incognitoFixed.contains(SearchHistoryTool.name))
        #expect(!AgentInstructions.incognitoFixed.contains(ShellCommandTool.name))
        #expect(!AgentInstructions.incognitoFixed.contains(LoadSkillTool.name))
    }
}

@Suite struct SlashCommandTests {
    @Test(arguments: [
        ("/new", SlashCommand.new),
        ("  /NEW \n", .new),
        ("/incognito", .incognito),
        ("/Incognito", .incognito),
    ] as [(String, SlashCommand)])
    func knownCommandsAreRecognized(text: String, command: SlashCommand) {
        #expect(SlashCommand.parse(text) == command)
    }

    @Test(arguments: ["new", "/new please", "/newer", "/", "/usr/bin is slow", "// comment", "what is /new"])
    func anythingElseIsAMessage(text: String) {
        #expect(SlashCommand.parse(text) == nil)
    }

    @Test func suggestionsFollowWhatIsTyped() {
        #expect(SlashCommand.suggestions(for: "/") == [.new, .incognito])
        #expect(SlashCommand.suggestions(for: "/in") == [.incognito])
        #expect(SlashCommand.suggestions(for: "/new") == [.new])
        #expect(SlashCommand.suggestions(for: "/new ").isEmpty)
        #expect(SlashCommand.suggestions(for: "/usr/").isEmpty)
        #expect(SlashCommand.suggestions(for: "hello").isEmpty)
        #expect(SlashCommand.allCases.allSatisfy { $0.name.hasPrefix("/") && !$0.summary.isEmpty })
    }
}

@Suite struct TranscriptEpisodeTests {
    private static let start = Date(timeIntervalSince1970: 1_795_320_000)

    @Test func eachEpisodeOpensWithASeparator() async throws {
        let store = try ThreadStore(fileURL: try writeLegacyThread())
        let transcript = Transcript(entries: await store.entries)
        let separators = transcript.rows.indices.filter { transcript.rows[$0].isEpisodeStart }
        #expect(separators.count == 3)
        #expect(transcript.currentEpisodeStartRow == separators.last)
        // The first message of an episode has the separator, not its own time label.
        #expect(transcript.rows[separators[1] + 1].kind == .user(
            text: "turn on dark mode\nplease", date: ISO8601DateFormatter().date(from: "2026-11-18T18:55:04Z")!, showsTime: false))
    }

    @Test func aFreshPageIsClaimedByTheNextEpisode() {
        var transcript = Transcript(entries: [ThreadEntry(date: Self.start, item: .userMessage(text: "one"))])
        #expect(transcript.currentEpisodeHasTimedOut(now: Self.start.addingTimeInterval(1800), timeout: 1800))
        transcript.beginEpisode(at: Self.start.addingTimeInterval(1800))
        transcript.beginEpisode(at: Self.start.addingTimeInterval(1900))
        #expect(transcript.hasPendingEpisode)
        #expect(!transcript.currentEpisodeHasTimedOut(now: Self.start.addingTimeInterval(9000), timeout: 1800))
        #expect(transcript.rows.count == 3)
        #expect(transcript.currentEpisodeStartRow == 2)

        let markerDate = Self.start.addingTimeInterval(2000)
        transcript.apply(ThreadEntry(date: markerDate, item: .episodeStart(.init(reason: .requested))))
        transcript.apply(ThreadEntry(date: markerDate, item: .userMessage(text: "two")))
        #expect(!transcript.hasPendingEpisode)
        #expect(transcript.rows.map(\.kind) == [
            .episodeStart(date: Self.start),
            .user(text: "one", date: Self.start, showsTime: false),
            .episodeStart(date: markerDate),
            .user(text: "two", date: markerDate, showsTime: false),
        ])
    }

    @Test func separatorsCarryTheDateAndTime() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Self.start
        func label(_ offset: TimeInterval) -> String {
            TranscriptTimeLabel.episodeText(for: now.addingTimeInterval(offset), now: now, calendar: calendar, locale: Locale(identifier: "en_US"))
                .replacing("\u{202F}", with: " ")
        }
        #expect(label(0) == "Today 8:00 PM")
        #expect(label(-21 * 3600) == "Yesterday 11:00 PM")
        // Daylight saving time was on then.
        #expect(label(-400 * 24 * 3600) == "Oct 17, 2025, 9:00 PM")
    }
}

extension Optional where Wrapped == Bool {
    var isTrue: Bool { self == true }
}
