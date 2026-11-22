import Foundation
import Testing
@testable import MacOSAgentCore

/// A memory folder in a temporary folder. Every fact in these tests is invented.
private func temporaryMemory() -> MemoryLibrary {
    MemoryLibrary(folder: FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-memory-tests-\(UUID().uuidString)/memory", directoryHint: .isDirectory))
}

private func context(episode: UUID? = nil) -> ToolRunContext {
    ToolRunContext(callID: "call_1", episodeID: episode, confirm: { _ in
        Issue.record("A memory change never asks for a go-ahead")
        return false
    })
}

private func change(_ library: MemoryLibrary, _ arguments: [String: JSONValue], episode: UUID? = nil) async -> String {
    var full: [String: JSONValue] = ["file": "core", "old_text": nil, "text": nil, "description": nil, "new_name": nil]
    for (key, value) in arguments { full[key] = value }
    return await ChangeMemoryTool(library: library).run(arguments: .object(full), context: context(episode: episode))
}

private func read(_ library: MemoryLibrary, _ file: String?) async -> String {
    await ReadMemoryTool(library: library).run(arguments: ["file": file.map { .string($0) } ?? nil], context: context())
}

private func write(_ text: String, _ path: String, in library: MemoryLibrary) throws {
    let url = library.folder.appending(path: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@Suite struct MemoryLayoutTests {
    @Test func filesRoundTripThroughTheFolder() async throws {
        let library = temporaryMemory()
        #expect(library.core().text.isEmpty)
        #expect(library.topics().isEmpty)
        // Nothing is made on disk until the first change.
        #expect(!FileManager.default.fileExists(atPath: library.folder.plainPath))

        _ = await change(library, ["operation": "append", "text": "- Prefers temperatures in Celsius."])
        _ = await change(library, [
            "operation": "create", "file": "travel-plans",
            "description": "Trips planned for next year. Read for anything about flights, hotels, or packing.",
            "text": "- A week in Lisbon in May, flying from the nearest airport.",
        ])
        #expect(try String(contentsOf: library.coreURL, encoding: .utf8) == "- Prefers temperatures in Celsius.\n")
        #expect(try String(contentsOf: library.folder.appending(path: "travel-plans.md"), encoding: .utf8) == """
            ---
            name: travel-plans
            description: Trips planned for next year. Read for anything about flights, hotels, or packing.
            ---

            - A week in Lisbon in May, flying from the nearest airport.

            """)
        let topic = try #require(library.topics().first)
        #expect(topic.id == "travel-plans")
        #expect(topic.kind == .topic)
        #expect(topic.description == "Trips planned for next year. Read for anything about flights, hotels, or packing.")
        #expect(topic.body == "- A week in Lisbon in May, flying from the nearest airport.")
        #expect(topic.problem == nil)
        #expect(library.file(named: "travel-plans.md") == topic)
        #expect(library.file(named: "CORE")?.kind == .core)
    }

    @Test func aDescriptionTheReaderWouldChangeIsQuoted() throws {
        let document = MemoryTopicDocument(name: "music", description: "Bands, \"live\" shows #1 and up", body: "Body.")
        #expect(document.text.contains("description: \"Bands, \\\"live\\\" shows #1 and up\""))
        #expect(try MemoryTopicDocument.parse(document.text) == document)
    }

    @Test func aMalformedFileIsKeptListedAndReadable() async throws {
        let library = temporaryMemory()
        try write("Just some notes with no front matter.\n", "loose-notes.md", in: library)
        try write("---\nname: other-name\ndescription: Named wrong.\n---\n\nBody.\n", "garden.md", in: library)
        try write("not memory", "picture.txt", in: library)
        let topics = library.topics()
        #expect(topics.map(\.id) == ["garden", "loose-notes"])
        #expect(topics[0].problem?.contains("other-name") == true)
        #expect(topics[1].problem == SkillDocument.ParseError.noFrontMatter.description)
        // The index says so instead of dropping the file.
        let block = MemoryBlock.contents(library).text
        #expect(block.contains("- loose-notes (changed "))
        #expect(block.contains("(Its front matter cannot be read: SKILL.md does not start with front matter"))
        // The agent can read the whole file to fix it, and a local edit still works on it.
        let text = await read(library, "loose-notes")
        #expect(text.contains("Just some notes with no front matter."))
        let result = await change(library, ["operation": "replace", "file": "loose-notes", "old_text": "Just some", "text": "A few"])
        #expect(result.hasPrefix("Replaced"))
        let described = await change(library, ["operation": "set_description", "file": "loose-notes", "description": "Notes."])
        #expect(described.hasPrefix("Error: loose-notes has no readable front matter"))
    }
}

@Suite struct MemoryChangeTests {
    @Test func eachOperationMakesALocalEdit() async throws {
        let library = temporaryMemory()
        let episode = UUID()
        var result = await change(library, ["operation": "append", "text": "- Their cat is called Biscuit."], episode: episode)
        #expect(result.hasPrefix("Added to core. It is in the memory block from the next episode.\ncore.md is 31 of about 4,000 characters, and the memory block is"))
        _ = await change(library, ["operation": "append", "text": "- Never play music out loud before nine."])
        result = await change(library, ["operation": "replace", "old_text": "Biscuit", "text": "Pepper"])
        #expect(result.hasPrefix("Replaced the text in core."))
        #expect(library.core().text == "- Their cat is called Pepper.\n- Never play music out loud before nine.\n")
        result = await change(library, ["operation": "remove", "old_text": "- Their cat is called Pepper.\n"])
        #expect(result.hasPrefix("Removed the text from core."))
        #expect(library.core().text == "- Never play music out loud before nine.\n")

        result = await change(library, ["operation": "create", "file": "garden", "description": "The vegetable garden.", "text": "Tomatoes by the fence."])
        #expect(result.hasPrefix("Created the topic file garden."))
        _ = await change(library, ["operation": "append", "file": "garden", "text": "Basil in pots."])
        #expect(library.file(named: "garden")?.body == "Tomatoes by the fence.\nBasil in pots.")
        _ = await change(library, ["operation": "replace", "file": "garden", "old_text": "Tomatoes", "text": "Beans"])
        #expect(library.file(named: "garden")?.body == "Beans by the fence.\nBasil in pots.")
        _ = await change(library, ["operation": "set_description", "file": "garden", "description": "The garden: what grows where. Read for plants."])
        #expect(library.file(named: "garden")?.description == "The garden: what grows where. Read for plants.")
        result = await change(library, ["operation": "rename", "file": "garden", "new_name": "vegetable-garden"])
        #expect(result.hasPrefix("Renamed garden to vegetable-garden."))
        #expect(library.topics().map(\.id) == ["vegetable-garden"])
        #expect(try MemoryTopicDocument.parse(library.topics()[0].text).name == "vegetable-garden")
        result = await change(library, ["operation": "delete", "file": "vegetable-garden"])
        #expect(result.hasPrefix("Archived vegetable-garden."))
        #expect(library.topics().isEmpty)
        #expect(library.archived().map(\.id) == ["vegetable-garden"])
        #expect(library.archived()[0].body == "Beans by the fence.\nBasil in pots.")
    }

    @Test func aChangeThatCannotApplySaysWhy() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "append", "text": "- Likes tea.\n- Likes tea with milk."])
        #expect(await change(library, ["operation": "replace", "old_text": "coffee", "text": "x"]).hasPrefix("Error: That text is not in core."))
        #expect(await change(library, ["operation": "replace", "old_text": "Likes tea", "text": "x"]).hasPrefix("Error: That text is in core 2 times."))
        #expect(await change(library, ["operation": "create", "file": "Bad Name", "description": "x", "text": ""]).contains("is not a topic file name"))
        #expect(await change(library, ["operation": "create", "file": "core", "description": "x", "text": ""]).contains("core is reserved"))
        #expect(await change(library, ["operation": "create", "file": "notes", "description": nil, "text": ""]).hasPrefix("Error: create needs a description"))
        _ = await change(library, ["operation": "create", "file": "notes", "description": "Notes.", "text": ""])
        #expect(await change(library, ["operation": "create", "file": "notes", "description": "Notes.", "text": ""]).contains("already a topic file notes"))
        #expect(await change(library, ["operation": "delete", "file": "core"]).contains("core has no name or description"))
        #expect(await change(library, ["operation": "rename", "file": "missing", "new_name": "x"]).contains("There is no memory file missing"))
        #expect(await change(library, ["operation": "forget"]).hasPrefix("Error: operation must be one of"))
    }

    @Test func readingReturnsCoreAndTheWholeIndexOrOneFile() async throws {
        let library = temporaryMemory()
        #expect(await read(library, nil).contains("(empty)"))
        #expect(await read(library, "core") == "core.md is empty.")
        _ = await change(library, ["operation": "append", "text": "- Works from home on Fridays."])
        _ = await change(library, ["operation": "create", "file": "work", "description": "Their job. Read for anything about work.", "text": "Starts at nine."])
        let all = await read(library, nil)
        #expect(all.contains("- Works from home on Fridays."))
        #expect(all.contains(", 90): Their job. Read for anything about work."))
        #expect(await read(library, "work") == "work.md, 90 characters.\nDescription: Their job. Read for anything about work.\nStarts at nine.")
        #expect(await read(library, "nothing").hasPrefix("Error: There is no memory file nothing."))
    }

    @Test func theResultWarnsWhenCoreNearsOrPassesItsCap() async throws {
        let library = temporaryMemory()
        let near = await change(library, ["operation": "append", "text": .string(String(repeating: "a", count: 3_300))])
        #expect(near.contains("Core is nearly full. Move the least general items into a topic file."))
        let over = await change(library, ["operation": "append", "text": .string(String(repeating: "b", count: 1_000))])
        #expect(over.contains("core.md is 4,302 of about 4,000 characters"))
        #expect(over.contains("Core is over its cap. Move long or topic-specific items into a topic file now"))
    }
}

@Suite struct MemoryJournalTests {
    @Test func everyChangeIsAnEntryWithTheFullContentAndItsCause() async throws {
        let library = temporaryMemory()
        let episode = UUID()
        _ = await change(library, ["operation": "append", "text": "- Their sister is called Ada."], episode: episode)
        try library.apply(.edit(file: "core.md", text: "- Their sister is called Ada.\n- Their brother is called Ben.\n"), cause: .settings)
        let entries = library.journal.entries()
        #expect(entries.map(\.operation) == [.append, .edit])
        #expect(entries[0].file == "core.md")
        #expect(entries[0].content == "- Their sister is called Ada.\n")
        #expect(entries[0].hash == MemoryJournal.hash("- Their sister is called Ada.\n"))
        #expect(entries[0].memoryCause == .episode(episode))
        #expect(entries[1].memoryCause == .settings)
        // One JSON line per entry, with the cause written out.
        let lines = try String(contentsOf: library.journal.fileURL, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"cause\":\"episode\""))
        #expect(lines[0].contains("\"episode\":\"\(episode.uuidString)\""))
        #expect(lines[1].contains("\"cause\":\"settings\""))
    }

    @Test func aChangeMadeOutsideTheAppIsJournaled() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "append", "text": "- Likes jazz."])
        _ = await change(library, ["operation": "create", "file": "music", "description": "Music.", "text": "Jazz."])
        #expect(library.reconcile().isEmpty)
        // An editor changes core, adds a file, and removes one.
        try write("- Likes jazz and blues.\n", "core.md", in: library)
        try write("---\nname: films\ndescription: Films.\n---\n\nOld ones.\n", "films.md", in: library)
        try FileManager.default.removeItem(at: library.folder.appending(path: "music.md"))
        let found = library.reconcile()
        #expect(found.map(\.file) == ["core.md", "films.md", "music.md"])
        #expect(found.map(\.operation) == [.outsideEdit, .outsideEdit, .outsideRemoval])
        #expect(found.allSatisfy { $0.memoryCause == .outside })
        #expect(found[0].content == "- Likes jazz and blues.\n")
        #expect(library.reconcile().isEmpty)

        // An edit right before the app's own change is journaled first, so nothing is lost.
        try write("- Likes jazz, blues, and soul.\n", "core.md", in: library)
        _ = await change(library, ["operation": "append", "text": "- Plays piano."])
        #expect(library.journal.entries().suffix(2).map(\.operation) == [.outsideEdit, .append])
    }

    @Test func restoringWritesAnOldRevisionAsANewEntry() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "append", "text": "- Lives near the river."])
        _ = await change(library, ["operation": "replace", "old_text": "near the river", "text": "by the park"])
        let first = try #require(library.journal.history(of: "core.md").first)
        let count = library.journal.entries().count
        try library.apply(.restore(first, file: "core.md"), cause: .settings)
        #expect(library.core().text == "- Lives near the river.\n")
        let entries = library.journal.entries()
        #expect(entries.count == count + 1)
        #expect(entries.last?.operation == .restore)
        #expect(entries.last?.restoredFrom == first.id)
        #expect(Array(entries.prefix(count)) == Array(library.journal.entries().prefix(count)))
        #expect(library.journal.history(of: "core.md").map(\.operation) == [.append, .replace, .restore])
    }

    @Test func deletingArchivesAndTheHistoryFollowsTheFile() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "create", "file": "car", "description": "The car.", "text": "A blue hatchback."])
        _ = await change(library, ["operation": "rename", "file": "car", "new_name": "vehicles"])
        _ = await change(library, ["operation": "append", "file": "vehicles", "text": "A red bicycle."])
        _ = await change(library, ["operation": "delete", "file": "vehicles"])
        #expect(!FileManager.default.fileExists(atPath: library.folder.appending(path: "vehicles.md").plainPath))
        #expect(FileManager.default.fileExists(atPath: library.archiveFolder.appending(path: "vehicles.md").plainPath))
        let archiving = library.journal.entries().suffix(2)
        #expect(archiving.map(\.file) == ["vehicles.md", "archive/vehicles.md"])
        #expect(archiving.first?.archivedAs == "archive/vehicles.md")
        #expect(archiving.first?.content == nil)
        #expect(archiving.last?.content?.contains("A red bicycle.") == true)
        // The archived file's history goes back through the archive and the rename to its creation.
        let history = library.journal.history(of: "archive/vehicles.md")
        #expect(history.map(\.operation) == [.create, .rename, .append, .archive, .archive])
        #expect(library.reconcile().isEmpty)

        // A second file archived under the same name does not overwrite the first.
        _ = await change(library, ["operation": "create", "file": "vehicles", "description": "Again.", "text": "A scooter."])
        _ = await change(library, ["operation": "delete", "file": "vehicles"])
        #expect(library.archived().map(\.id) == ["vehicles", "vehicles-2"])
        #expect(library.journal.history(of: "archive/vehicles-2.md").map(\.operation) == [.create, .archive, .archive])

        // Moving one back is journaled as well.
        try library.apply(.unarchive(file: "vehicles"), cause: .settings)
        #expect(library.topics().map(\.id) == ["vehicles"])
        #expect(library.topics()[0].body == "A blue hatchback.\nA red bicycle.")
        #expect(library.reconcile().isEmpty)
    }

    @Test func aLineCutShortByACrashLeavesTheRestReadable() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "append", "text": "- One."])
        let handle = try FileHandle(forWritingTo: library.journal.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"cause\":\"epi".utf8))
        try handle.close()
        _ = await change(library, ["operation": "append", "text": "- Two."])
        #expect(library.journal.entries().map(\.operation) == [.append, .append])
    }
}

@Suite struct MemoryBlockTests {
    private func prompt(_ library: MemoryLibrary) -> AgentPrompt {
        let folder = library.folder.deletingLastPathComponent()
        return AgentPrompt(
            instructions: InstructionsStore(fileURL: folder.appending(path: "instructions.md"), agentName: { "Iris" }),
            skills: SkillLibrary(folder: folder.appending(path: "skills"), settingsFile: folder.appending(path: "skill-settings.json")),
            memories: library)
    }

    @Test func theBlockEndsTheInstructionsWithCoreAndAGeneratedIndex() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "append", "text": "- Their name is Sam.\n- Never book flights before 8 a.m."])
        _ = await change(library, ["operation": "create", "file": "travel-plans", "description": "Trips. Read for travel.", "text": "Lisbon in May."])
        _ = await change(library, ["operation": "create", "file": "books", "description": "What they are reading.", "text": "A novel."])
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: library.folder.appending(path: "books.md").plainPath)
        let changed = MemoryBlock.day(day, calendar: .current)
        let today = MemoryBlock.day(Date(), calendar: .current)

        let instructions = prompt(library).current(episodeID: UUID())
        let block = """
            <memory>
            Your memory, as it was when this episode began. A change you make in this episode shows here from the next one.

            <core>
            - Their name is Sam.
            - Never book flights before 8 a.m.
            </core>

            <topic_files>
            Read one with read_memory when its description matches the request.
            - books (changed \(changed)): What they are reading.
            - travel-plans (changed \(today)): Trips. Read for travel.
            </topic_files>
            </memory>
            """
        #expect(instructions.hasSuffix("\n\n" + block))
        // Everything before it is the instructions without memory, so it stays a cached prefix.
        #expect(instructions == prompt(library).current() + "\n\n" + block)
        #expect(prompt(library).current().contains("There are no skills yet."))
    }

    @Test func anEmptyMemorySaysSo() {
        let text = MemoryBlock.contents(temporaryMemory()).text
        #expect(text.contains("<core>\ncore.md is empty.\n</core>"))
        #expect(text.contains("There are no topic files yet."))
    }

    @Test func overTheCapTheIndexAndThenCoreAreCut() {
        let index = (0..<50).map { MemoryBlock.IndexLine(name: String(format: "topic-%02d", $0), description: String(repeating: "d", count: 100), changed: "2026-11-20") }
        let recency = Dictionary(uniqueKeysWithValues: index.enumerated().map { ($1.name, Date(timeIntervalSince1970: Double($0))) })
        let core = (1...40).map { "- Fact number \($0) " + String(repeating: "x", count: 80) }.joined(separator: "\n")

        let indexCut = MemoryBlock.contents(core: core, index: index, recency: recency)
        #expect(indexCut.characters <= MemoryLayout.blockCap)
        #expect(indexCut.coreIncluded == indexCut.coreTotal)
        #expect(indexCut.topicsListed < 50 && indexCut.topicsListed > 0)
        // The files changed most recently are the ones kept.
        #expect(indexCut.text.contains("- topic-49 "))
        #expect(!indexCut.text.contains("- topic-00 "))
        #expect(indexCut.text.contains("[\(50 - indexCut.topicsListed) more topic files are left out to keep this block under its cap. read_memory with file null lists them all.]"))

        let huge = (1...200).map { "- Fact number \($0) " + String(repeating: "x", count: 80) }.joined(separator: "\n")
        let coreCut = MemoryBlock.contents(core: huge, index: index, recency: recency)
        #expect(coreCut.characters <= MemoryLayout.blockCap)
        #expect(coreCut.isCut)
        #expect(coreCut.topicsListed == 0)
        #expect(coreCut.text.contains("- Fact number 1 "))
        #expect(!coreCut.text.contains("- Fact number 200 "))
        #expect(coreCut.text.contains("characters, is left out to keep this block under its cap. Read it with read_memory with file \"core\".]"))
        #expect(coreCut.text.contains("[50 more topic files are left out"))
    }

    @Test func theBlockIsFrozenForTheEpisodeAndRefreshedAtTheNext() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "append", "text": "- Their name is Sam."])
        let prompt = prompt(library)
        let arguments: JSONValue = ["operation": "append", "file": "core", "old_text": nil, "text": "- Their dog is called Rufus.", "description": nil, "new_name": nil]
        let provider = FakeProvider(replies: [
            [.item(toolCall("a", name: ChangeMemoryTool.name, arguments: arguments))],
            [.item(assistant("I'll remember Rufus."))],
            [.item(assistant("Rufus, yes."))],
            [.item(assistant("Your dog is Rufus."))],
        ])
        let thread = try ThreadStore(fileURL: temporaryThreadFile())
        let loop = AgentLoop(
            provider: provider, thread: thread, tools: [ChangeMemoryTool(library: library)],
            instructionsForEpisode: { prompt.current(episodeID: $0) }, episodeTimeout: { .infinity })
        try await loop.run("remember my dog is Rufus", onEvent: { _ in }, confirm: { _ in true })
        try await loop.run("what is my dog called?", onEvent: { _ in }, confirm: { _ in true })
        let journal = library.journal.entries()
        #expect(journal.last?.memoryCause == .episode(await thread.currentEpisode?.id))
        try await loop.run("and now?", startsNewEpisode: true, onEvent: { _ in }, confirm: { _ in true })

        let requests = provider.requests.map(\.instructions)
        #expect(requests.count == 4)
        // The change is in the file at once, but the episode it was made in keeps its block.
        #expect(library.core().text.contains("Rufus"))
        #expect(requests[0] == requests[1])
        #expect(requests[1] == requests[2])
        #expect(!requests[0].contains("Rufus"))
        // The next episode takes a fresh block.
        #expect(requests[3].contains("- Their dog is called Rufus."))
        #expect(requests[3].hasPrefix(prompt.current()))
        #expect(prompt.memorySnapshot.latest?.contents.text.contains("Rufus") == true)
    }

    @Test func debuggingShowsOnlyTheBlocksSize() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "append", "text": "- Their pin code is not here, only this invented line."])
        let shown = prompt(library).currentForDisplay()
        #expect(!shown.contains("invented line"))
        #expect(shown.hasSuffix("<memory>\n[The memory block: core.md and an index of 0 topic files, \(MemoryBlock.contents(library).characters.formatted()) characters. Not shown here. See Settings, Memory.]\n</memory>"))
        let counts = MemoryCounts(library, block: MemoryBlock.contents(library))
        #expect(counts.coreCharacters == library.core().characters)
        #expect(counts.journalEntries == 1)
    }
}

@Suite struct MemoryInstructionsTests {
    @Test func theFixedInstructionsSayHowToManageMemory() {
        let fixed = AgentInstructions.fixed(skills: [], skillsFolder: URL(filePath: "/tmp/skills"))
        #expect(fixed.contains("is yours to manage with read_memory and change_memory"))
        #expect(fixed.contains("Never store passwords, card numbers, or other secrets, even when asked, and say why"))
        #expect(fixed.contains("every standing rule or prohibition"))
        #expect(fixed.contains("When the person says to forget something, remove it."))
    }

    @Test func incognitoHasNoMemoryBlockAndNoMemoryTools() async throws {
        let library = temporaryMemory()
        _ = await change(library, ["operation": "append", "text": "- An invented fact."])
        let prompt = AgentPrompt(memories: library)
        let incognito = prompt.currentIncognito()
        #expect(!incognito.contains(MemoryBlock.opening))
        #expect(!incognito.contains("An invented fact."))
        #expect(incognito.contains("read or change memory"))
        let names = BuiltInTools.makeIncognito().map(\.definition.name)
        #expect(!names.contains(ReadMemoryTool.name))
        #expect(!names.contains(ChangeMemoryTool.name))
    }

    @Test func memoryToolsAreTheLastBuiltInToolsWithSmallStrictSchemas() {
        #expect(BuiltInTools.names.suffix(2) == [ReadMemoryTool.name, ChangeMemoryTool.name])
        #expect(Array(BuiltInTools.names.dropLast(2).suffix(2)) == [ReadQuickActionsTool.name, ChangeQuickActionTool.name])
        var characters = 0
        for tool in BuiltInTools.make().suffix(2) {
            let definition = tool.definition
            #expect(tool.source == .memory)
            #expect(tool.goAhead == .never)
            #expect(definition.parameters["additionalProperties"] == false)
            let encoded: JSONValue = ["type": "function", "name": .string(definition.name), "description": .string(definition.description), "parameters": definition.parameters, "strict": true]
            characters += encoded.encodedString().count
        }
        print("memory tools add \(characters) characters to each request")
        #expect(characters < 1700)
    }
}

@Suite struct MemoryNoticeTests {
    private func entry(_ operation: MemoryJournalEntry.Operation, _ file: String, cause: MemoryCause = .episode(nil), archivedAs: String? = nil) -> MemoryJournalEntry {
        var entry = MemoryJournalEntry(date: Date(), file: file, operation: operation, content: "x", cause: cause)
        entry.archivedAs = archivedAs
        return entry
    }

    @Test func theNoticeSaysWhatChangedInOneLine() {
        #expect(MemoryLibrary.changeNotice([entry(.append, "core.md")]) == "Remembered in core.")
        #expect(MemoryLibrary.changeNotice([entry(.create, "travel-plans.md"), entry(.append, "travel-plans.md")]) == "Remembered in travel-plans.")
        #expect(MemoryLibrary.changeNotice([entry(.replace, "core.md")]) == "Updated core.")
        #expect(MemoryLibrary.changeNotice([entry(.remove, "core.md")]) == "Forgot something in core.")
        #expect(MemoryLibrary.changeNotice([
            entry(.archive, "old-trips.md", archivedAs: "archive/old-trips.md"), entry(.archive, "archive/old-trips.md"),
        ]) == "Forgot old-trips.")
        #expect(MemoryLibrary.changeNotice([entry(.append, "core.md"), entry(.create, "garden.md"), entry(.replace, "core.md")])
            == "Remembered in core and garden.")
        #expect(MemoryLibrary.changeNotice([entry(.append, "a.md"), entry(.append, "b.md"), entry(.append, "c.md")]) == "Remembered in 3 files.")
        // Changes from Settings or an editor are not the agent's, so no notice.
        #expect(MemoryLibrary.changeNotice([entry(.edit, "core.md", cause: .settings), entry(.outsideEdit, "core.md", cause: .outside)]) == nil)
        #expect(MemoryLibrary.changeNotice([]) == nil)
    }
}
