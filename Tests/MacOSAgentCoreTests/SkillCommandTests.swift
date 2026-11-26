import Foundation
import Testing
@testable import MacOSAgentCore

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func skillText(_ name: String, _ description: String, extra: String = "", body: String = "Do the thing.") -> String {
    "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n\(body)\n"
}

@discardableResult
private func writeSkill(_ name: String, in folder: URL, _ text: String, files: [String] = []) throws -> URL {
    let skillFolder = folder.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: skillFolder.appending(path: "SKILL.md"), options: .atomic)
    for file in files {
        try Data("echo hi\n".utf8).write(to: skillFolder.appending(path: file))
    }
    return skillFolder
}

private func library(_ root: URL) -> SkillLibrary {
    SkillLibrary(folder: root.appending(path: "skills", directoryHint: .isDirectory),
                 settingsFile: root.appending(path: "skill-settings.json"))
}

private func command(_ name: String, _ description: String = "Does a thing.") -> SkillCommand {
    SkillCommand(name: name, description: description, folderName: name)
}

@Suite struct UserInvocableTests {
    @Test func skillsAreInvocableUnlessTheFrontMatterSaysFalse() throws {
        #expect(try SkillDocument.parse(skillText("a", "A.")).isUserInvocable)
        #expect(try SkillDocument.parse(skillText("a", "A.", extra: "user-invocable: true\n")).isUserInvocable)
        #expect(try !SkillDocument.parse(skillText("a", "A.", extra: "user-invocable: false\n")).isUserInvocable)
        #expect(try !SkillDocument.parse(skillText("a", "A.", extra: "user-invocable: False\n")).isUserInvocable)
    }

    @Test func aValueThatIsNotABooleanIsAProblem() {
        #expect(throws: SkillDocument.ParseError.invalidUserInvocable("sometimes")) {
            try SkillDocument.parse(skillText("a", "A.", extra: "user-invocable: sometimes\n"))
        }
    }

    @Test func theLibraryReadsTheKeyAndARevisionThatFollowsTheFile() throws {
        let root = temporaryFolder()
        let skills = library(root)
        try writeSkill("agent-only", in: skills.folder, skillText("agent-only", "For the agent.", extra: "user-invocable: false\n"))
        try writeSkill("open-notes", in: skills.folder, skillText("open-notes", "Opens notes."))
        let first = skills.folderSkills()
        #expect(first.map(\.isUserInvocable) == [false, true])
        #expect(first.allSatisfy { $0.revision != nil })

        try writeSkill("open-notes", in: skills.folder, skillText("open-notes", "Opens notes.", body: "New steps."))
        let second = skills.folderSkills()
        #expect(second[0].revision == first[0].revision)
        #expect(second[1].revision != first[1].revision)
    }
}

@Suite struct SlashCommandMenuTests {
    private func menuFromFolder() throws -> SlashCommandMenu {
        let root = temporaryFolder()
        let skills = library(root)
        try writeSkill("rename-photos", in: skills.folder, skillText("rename-photos", "Renames photos by date."))
        try writeSkill("resize-images", in: skills.folder, skillText("resize-images", "Resizes images."))
        try writeSkill("agent-only", in: skills.folder, skillText("agent-only", "Only the agent.", extra: "user-invocable: false\n"))
        try writeSkill("new", in: skills.folder, skillText("new", "Clashes with the app's command."))
        try writeSkill("broken", in: skills.folder, "no front matter")
        try writeSkill("turned-off", in: skills.folder, skillText("turned-off", "Off in Settings."))
        try skills.setEnabled(false, folderName: "turned-off")
        return SlashCommandMenu(skills: skills.skills())
    }

    @Test func theMenuHasTheAppsCommandsThenEachSkillTheOwnerCanInvoke() throws {
        let menu = try menuFromFolder()
        // The skill that is part of the app is listed with the rest, in name order.
        #expect(menu.items.map(\.name) == ["/new", "/incognito", "/file-issue-about-this-app", "/rename-photos", "/resize-images"])
        #expect(menu.items[3].summary() == "Renames photos by date.")
        #expect(menu.items[3].completion == "/rename-photos ")
        #expect(menu.items[0].completion == "/new")
    }

    @Test func theAppsCommandWinsOverASkillWithTheSameName() throws {
        let menu = try menuFromFolder()
        #expect(menu.parse("/new") == .builtIn(.new))
        #expect(menu.parse("/new please") == nil)
        #expect(SlashCommandMenu.builtInClash(for: "new") == .new)
        #expect(SlashCommandMenu.builtInClash(for: "incognito") == .incognito)
        #expect(SlashCommandMenu.builtInClash(for: "rename-photos") == nil)
    }

    @Test func suggestionsFilterAsTheOwnerTypes() throws {
        let menu = try menuFromFolder()
        #expect(menu.suggestions(for: "/").map(\.name) == ["/new", "/incognito", "/file-issue-about-this-app", "/rename-photos", "/resize-images"])
        #expect(menu.suggestions(for: "/re").map(\.name) == ["/rename-photos", "/resize-images"])
        #expect(menu.suggestions(for: "/REN").map(\.name) == ["/rename-photos"])
        #expect(menu.suggestions(for: "/rename-photos").map(\.name) == ["/rename-photos"])
        #expect(menu.suggestions(for: "/in").map(\.name) == ["/incognito"])
        #expect(menu.suggestions(for: "/x").isEmpty)
        #expect(menu.suggestions(for: "/usr/").isEmpty)
        #expect(menu.suggestions(for: "hello").isEmpty)
        #expect(menu.suggestions(for: "/agent").isEmpty)
        #expect(menu.suggestions(for: "/turned").isEmpty)
    }

    @Test func whileASkillsTextIsTypedOnlyThatSkillIsListed() throws {
        let menu = try menuFromFolder()
        #expect(menu.suggestions(for: "/rename-photos the trip").map(\.name) == ["/rename-photos"])
        #expect(menu.suggestions(for: "/new ").isEmpty)
        #expect(menu.suggestions(for: "/ren the trip").isEmpty)
    }

    @Test func theRestOfTheLineIsTheSkillsText() throws {
        let menu = try menuFromFolder()
        let rename = try #require(menu.skills.first { $0.name == "rename-photos" })
        #expect(menu.parse("/rename-photos the trip folder") == .skill(rename, text: "the trip folder"))
        #expect(menu.parse("  /rename-photos  ") == .skill(rename, text: ""))
        #expect(menu.parse("/Rename-Photos x") == .skill(rename, text: "x"))
        #expect(menu.parse("/rename-photos first\nsecond") == .skill(rename, text: "first\nsecond"))
        #expect(menu.parse("/rename-photosx") == nil)
        #expect(menu.parse("/agent-only x") == nil)
        #expect(menu.parse("/usr/local is full") == nil)
        #expect(menu.parse("rename-photos") == nil)
    }

    @Test func theIncognitoMenuHasOnlyTheAppsCommands() {
        #expect(SlashCommandMenu.builtInOnly.items.map(\.name) == ["/new", "/incognito"])
        #expect(SlashCommandMenu.builtInOnly.parse("/rename-photos x") == nil)
        #expect(SlashCommandMenu.builtInOnly.items[0].summary(incognito: true) == "Clear this conversation")
    }

    @Test func settingsSaysHowEachSkillCanBeInvoked() throws {
        let root = temporaryFolder()
        let skills = library(root)
        try writeSkill("rename-photos", in: skills.folder, skillText("rename-photos", "Renames."))
        try writeSkill("agent-only", in: skills.folder, skillText("agent-only", "Agent.", extra: "user-invocable: false\n"))
        try writeSkill("new", in: skills.folder, skillText("new", "Clash."))
        try writeSkill("broken", in: skills.folder, "nothing")
        try writeSkill("turned-off", in: skills.folder, skillText("turned-off", "Off."))
        try skills.setEnabled(false, folderName: "turned-off")
        let status = Dictionary(uniqueKeysWithValues: skills.skills().map { ($0.folderName, SlashCommandMenu.commandStatus(for: $0)) })
        #expect(status["rename-photos"] == "Type /rename-photos in the panel to use it, followed by what to use it on.")
        #expect(status["agent-only"] == "Not offered as a slash command. Its SKILL.md has user-invocable: false, so only the agent uses it.")
        #expect(status["new"] == "Not offered as a slash command, because /new is one of the app's own commands. Rename the skill to invoke it with a slash.")
        #expect(status["turned-off"] == "Offered as /turned-off in the panel once it is on.")
        #expect(status["broken"] == .some(nil))
    }
}

@Suite struct SkillCommandChangeTests {
    @Test func newAndChangedCommandsAreFound() {
        let before = SlashCommandMenu(skills: [command("a"), command("b")])
        var changedB = command("b")
        changedB.revision = "2"
        let after = SlashCommandMenu(skills: [command("a"), changedB, command("c")])
        let changes = SlashCommandMenu.changes(from: before, to: after)
        #expect(changes.added.map(\.name) == ["c"])
        #expect(changes.changed.map(\.name) == ["b"])
        #expect(changes.notice == "/c is ready to use. /b is updated.")
        #expect(SlashCommandMenu.changes(from: after, to: after).isEmpty)
        #expect(SlashCommandMenu.changes(from: after, to: after).notice == nil)
        // A skill that went away is not announced.
        #expect(SlashCommandMenu.changes(from: after, to: before).added.isEmpty)
    }

    @Test func theNoticeListsSeveralCommands() {
        let menu = SlashCommandMenu(skills: [command("a"), command("b"), command("c")])
        #expect(SlashCommandMenu.changes(from: .builtInOnly, to: menu).notice == "/a, /b, and /c are ready to use.")
        let two = SlashCommandMenu(skills: [command("a"), command("b")])
        #expect(SlashCommandMenu.changes(from: .builtInOnly, to: two).notice == "/a and /b are ready to use.")
    }
}

@Suite struct SkillInvocationTests {
    private func renamePhotos() throws -> (SkillLibrary, SkillCommand) {
        let root = temporaryFolder()
        let skills = library(root)
        try writeSkill("rename-photos", in: skills.folder, skillText("rename-photos", "Renames photos.", body: "1. Read the dates.\n2. Rename."),
                       files: ["rename.sh"])
        let menu = SlashCommandMenu(skills: skills.skills())
        return (skills, try #require(menu.skills.first { $0.name == "rename-photos" }))
    }

    @Test func theMessageIsTheTypedLineThenTheSkillsInstructions() throws {
        let (skills, command) = try renamePhotos()
        let invocation = try skills.invocation(typed: "/rename-photos the trip folder", command: command).get()
        #expect(invocation.name == "rename-photos")
        let folder = skills.folder.appending(path: "rename-photos", directoryHint: .isDirectory)
        #expect(invocation.message == """
            /rename-photos the trip folder

            The app added what follows. The person typed only the line above, invoking the rename-photos skill. \
            The text after /rename-photos is what to use it on. Follow the skill's instructions below. They are \
            already loaded, so do not call load_skill for it.

            <skill name="rename-photos">
            Skill rename-photos, from \(folder.appending(path: "SKILL.md").plainPath)
            Files beside SKILL.md, in \(folder.plainPath):
            - rename.sh

            1. Read the dates.
            2. Rename.
            </skill>
            """)
    }

    @Test func withNoTextTheMessageSaysSo() throws {
        let (skills, command) = try renamePhotos()
        let invocation = try skills.invocation(typed: "/rename-photos", command: command).get()
        #expect(invocation.message.hasPrefix("/rename-photos\n\n"))
        #expect(invocation.message.contains("They gave no text after it"))
    }

    @Test func aSkillTurnedOffSinceTheListWasReadIsNotSent() throws {
        let (skills, command) = try renamePhotos()
        try skills.setEnabled(false, folderName: "rename-photos")
        #expect(throws: SkillLibrary.LoadError.turnedOff) { try skills.invocation(typed: "/rename-photos", command: command).get() }
    }

    @Test func aPlainMessageLineIsUnchangedAndOldLinesLoad() async throws {
        // A line as the thread file held it before invocations existed.
        let old = #"{"date":"2026-11-01T10:00:00Z","id":"00000000-0000-0000-0000-000000000001","item":{"type":"user_message","value":{"text":"hi"}}}"#
        let file = temporaryFolder().appending(path: "thread.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((old + "\n").utf8).write(to: file)
        let thread = try ThreadStore(fileURL: file)
        #expect(await thread.entries.map(\.item) == [.userMessage(text: "hi")])

        // A plain message is written with no skill field, and nothing already stored changes.
        try await thread.append(.userMessage(text: "again"))
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.first == old)
        #expect(lines.count == 2)
        #expect(!lines[1].contains("skill"))
    }

    @Test func anInvocationKeepsBothTheTypedLineAndWhatWasSent() throws {
        let invocation = ThreadItem.SkillInvocation(name: "rename-photos", message: "/rename-photos x\n\n<skill>…</skill>")
        let entry = ThreadEntry(item: .userMessage(text: "/rename-photos x", skill: invocation))
        let decoded = try JSONDecoder().decode(ThreadEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded == entry)
        guard case .userMessage(let text, let skill, _, _) = decoded.item else { Issue.record("not a message"); return }
        #expect(text == "/rename-photos x")
        #expect(skill == invocation)
    }

    @Test func theModelIsSentTheExpandedMessageAndThePanelTheTypedLine() throws {
        let invocation = ThreadItem.SkillInvocation(name: "rename-photos", message: "/rename-photos x\n\nSTEPS")
        let entry = ThreadEntry(date: Date(timeIntervalSince1970: 0), item: .userMessage(text: "/rename-photos x", skill: invocation))
        let input = OpenAIResponses.input(
            for: ModelRequest(instructions: "Be brief.", entries: [entry], tools: []), model: "m",
            timeZone: TimeZone(identifier: "UTC")!)
        let text = input[1]["content"]?.arrayValue?.first?["text"]?.stringValue
        #expect(text?.hasSuffix("] /rename-photos x\n\nSTEPS") == true)

        let transcript = Transcript(entries: [entry])
        #expect(transcript.rows.contains {
            if case .user(let text, _, _) = $0.kind { text == "/rename-photos x" } else { false }
        })
    }
}

@Suite struct SkillInvocationPrefixTests {
    /// An invocation is a new message at the end. The instructions, the tools, and every item
    /// already in the episode go out exactly as before, so the prompt cache holds.
    @Test func anInvocationLeavesTheRequestPrefixUnchanged() async throws {
        let root = temporaryFolder()
        let skills = library(root)
        try writeSkill("rename-photos", in: skills.folder, skillText("rename-photos", "Renames photos."))
        let prompt = AgentPrompt(instructions: InstructionsStore(fileURL: root.appending(path: "instructions.md")), skills: skills)
        let provider = FakeProvider(replies: [
            [.item(assistant("First."))],
            [.item(assistant("Renamed."))],
        ])
        let thread = try ThreadStore(fileURL: root.appending(path: "thread.jsonl"))
        let loop = AgentLoop(
            provider: provider, thread: thread, tools: [LoadSkillTool(library: skills)],
            instructions: { prompt.current() })
        let start = Date(timeIntervalSince1970: 1_000_000)
        try await loop.run("hello", now: start, onEvent: { _ in }, confirm: { _ in false })

        let menu = SlashCommandMenu(skills: skills.skills())
        guard case .skill(let command, _) = menu.parse("/rename-photos the trip") else {
            Issue.record("not parsed as a skill")
            return
        }
        let invocation = try skills.invocation(typed: "/rename-photos the trip", command: command).get()
        try await loop.run("/rename-photos the trip", skill: invocation, now: start.addingTimeInterval(60), onEvent: { _ in }, confirm: { _ in false })

        let requests = provider.requests
        try #require(requests.count == 2)
        #expect(requests[1].instructions == requests[0].instructions)
        #expect(requests[1].tools == requests[0].tools)
        let first = OpenAIResponses.body(for: requests[0], model: "m", reasoningEffort: "low", promptCacheKey: "k")
        let second = OpenAIResponses.body(for: requests[1], model: "m", reasoningEffort: "low", promptCacheKey: "k")
        let firstInput = try #require(first["input"]?.arrayValue)
        let secondInput = try #require(second["input"]?.arrayValue)
        // The second request is the first one's input, the reply, and the new message.
        #expect(Array(secondInput.prefix(firstInput.count)) == firstInput)
        #expect(secondInput.count == firstInput.count + 2)
        #expect(secondInput.last?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("<skill name=\"rename-photos\">") == true)
        #expect(first["tools"] == second["tools"])

        // The thread keeps the typed line and what was sent.
        let entries = await thread.entries
        #expect(entries.last(where: { if case .userMessage = $0.item { true } else { false } })?.item
            == .userMessage(text: "/rename-photos the trip", skill: invocation))
    }
}

@MainActor
@Suite(.serialized) struct FolderWatcherTests {
    /// Waits for a condition, checking every few milliseconds, up to a limit.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func aSkillWrittenWhileWatchingIsSeen() async throws {
        let root = temporaryFolder()
        let skills = library(root)
        try FileManager.default.createDirectory(at: skills.folder, withIntermediateDirectories: true)
        var changes = 0
        let watcher = FolderWatcher(folder: skills.folder, delay: .milliseconds(20)) { changes += 1 }
        #expect(watcher.isWatching)

        // A new skill folder, then its SKILL.md, as the agent writes them.
        try writeSkill("rename-photos", in: skills.folder, skillText("rename-photos", "Renames."))
        #expect(await eventually { changes > 0 && SlashCommandMenu(skills: skills.folderSkills()).skills.count == 1 })

        // An edit inside the skill's own folder is seen too, since that folder is watched now.
        let seen = changes
        try writeSkill("rename-photos", in: skills.folder, skillText("rename-photos", "Renames, better."))
        #expect(await eventually { changes > seen })

        // Removing it.
        let beforeRemoval = changes
        try FileManager.default.removeItem(at: skills.folder.appending(path: "rename-photos"))
        #expect(await eventually { changes > beforeRemoval })
        #expect(SlashCommandMenu(skills: skills.folderSkills()).skills.isEmpty)
    }

    @Test func aFolderMadeLaterIsWatchedOnceRearmed() async throws {
        let root = temporaryFolder()
        let skills = library(root)
        var changes = 0
        let watcher = FolderWatcher(folder: skills.folder, delay: .milliseconds(20)) { changes += 1 }
        #expect(!watcher.isWatching)
        try FileManager.default.createDirectory(at: skills.folder, withIntermediateDirectories: true)
        watcher.rearm()
        #expect(watcher.isWatching)
        try writeSkill("a", in: skills.folder, skillText("a", "A."))
        #expect(await eventually { changes > 0 })
    }
}
