import Foundation
import Testing
@testable import MacOSAgentCore

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func writeSkill(_ folderName: String, in folder: URL, _ text: String, extraFiles: [String] = []) throws {
    let skillFolder = folder.appending(path: folderName, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: skillFolder.appending(path: "SKILL.md"))
    for file in extraFiles {
        let url = skillFolder.appending(path: file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("echo hi\n".utf8).write(to: url)
    }
}

private func library(_ root: URL) -> SkillLibrary {
    SkillLibrary(folder: root.appending(path: "skills", directoryHint: .isDirectory),
                 settingsFile: root.appending(path: "skill-settings.json"))
}

@Suite struct InstructionsStoreTests {
    @Test func theDefaultAppliesUntilTheFirstEdit() throws {
        let store = InstructionsStore(fileURL: temporaryFolder().appending(path: "instructions.md"))
        #expect(store.load() == AgentInstructions.defaultEditable)
        #expect(!store.isCustomized)
    }

    @Test func theDefaultGivesTheAgentNoName() {
        #expect(AgentInstructions.defaultEditable.hasPrefix(
            "You are the agent in the mac-os-agent app, and you live in the menu bar of the person's Mac."))
    }

    @Test func editsAreKeptByteForByte() throws {
        let store = InstructionsStore(fileURL: temporaryFolder().appending(path: "instructions.md"))
        let text = "Be brief.\n\n  Indented line with trailing spaces   \n"
        try store.save(text)
        #expect(store.isCustomized)
        #expect(store.load() == text)
        #expect(try Data(contentsOf: store.fileURL) == Data(text.utf8))
    }

    @Test func restoringTheDefaultRemovesTheFile() throws {
        let store = InstructionsStore(fileURL: temporaryFolder().appending(path: "instructions.md"))
        try store.save("Custom")
        try store.restoreDefault()
        #expect(!store.isCustomized)
        #expect(store.load() == AgentInstructions.defaultEditable)
        // Restoring again is fine.
        try store.restoreDefault()
    }

    @Test func savingTheDefaultTextIsTheSameAsRestoring() throws {
        let store = InstructionsStore(fileURL: temporaryFolder().appending(path: "instructions.md"))
        try store.save("Custom")
        try store.save(AgentInstructions.defaultEditable)
        #expect(!store.isCustomized)
    }
}

/// The default instructions are fixed text, so every request starts with the same bytes and
/// the prompt cache holds.
@Suite struct DefaultInstructionsTests {
    @Test func theMainPanelAndIncognitoStartWithTheDefault() {
        let root = temporaryFolder()
        let prompt = AgentPrompt(
            instructions: InstructionsStore(fileURL: root.appending(path: "i.md")), skills: library(root))
        #expect(prompt.current().hasPrefix(AgentInstructions.defaultEditable))
        #expect(prompt.currentIncognito().hasPrefix(AgentInstructions.defaultEditable))
        #expect(Data(prompt.current().utf8) == Data(prompt.current().utf8))
    }
}

@Suite struct SkillDocumentTests {
    @Test func parsesNameDescriptionAndBody() throws {
        let document = try SkillDocument.parse("""
            ---
            name: rename-photos
            description: Rename photos in a folder by the date they were taken.
            license: MIT
            metadata:
              author: someone
            ---

            # Steps
            Run rename.sh with the folder.
            """)
        #expect(document.name == "rename-photos")
        #expect(document.description == "Rename photos in a folder by the date they were taken.")
        #expect(document.body == "# Steps\nRun rename.sh with the folder.")
    }

    @Test func acceptsQuotesBlocksAndWindowsLineEnds() throws {
        let quoted = try SkillDocument.parse("---\r\nname: \"tidy-desktop\"\r\ndescription: 'Moves files: it''s quick'\r\n---\r\nBody")
        #expect(quoted.name == "tidy-desktop")
        #expect(quoted.description == "Moves files: it's quick")
        #expect(quoted.body == "Body")

        let folded = try SkillDocument.parse("""
            ---
            name: long-one
            description: >
              Spans two
              lines.
            ---
            """)
        #expect(folded.description == "Spans two lines.")
        #expect(folded.body == "")

        let withBOM = try SkillDocument.parse("\u{FEFF}---\nname: a\ndescription: b # a comment\n---\n")
        #expect(withBOM.description == "b")
    }

    @Test func rejectsMalformedFiles() {
        #expect(throws: SkillDocument.ParseError.noFrontMatter) { try SkillDocument.parse("Just instructions") }
        #expect(throws: SkillDocument.ParseError.noFrontMatter) { try SkillDocument.parse("") }
        #expect(throws: SkillDocument.ParseError.unclosedFrontMatter) { try SkillDocument.parse("---\nname: a\ndescription: b\n") }
        #expect(throws: SkillDocument.ParseError.missingField("name")) { try SkillDocument.parse("---\ndescription: b\n---\n") }
        #expect(throws: SkillDocument.ParseError.missingField("description")) { try SkillDocument.parse("---\nname: a\ndescription:\n---\n") }
        #expect(throws: SkillDocument.ParseError.invalidName("Rename Photos")) {
            try SkillDocument.parse("---\nname: Rename Photos\ndescription: b\n---\n")
        }
        let long = String(repeating: "x", count: 1025)
        #expect(throws: SkillDocument.ParseError.descriptionTooLong(1025)) {
            try SkillDocument.parse("---\nname: a\ndescription: \(long)\n---\n")
        }
    }

    @Test func names() {
        #expect(SkillDocument.isValidName("rename-photos-2"))
        #expect(!SkillDocument.isValidName("-leading"))
        #expect(!SkillDocument.isValidName("double--hyphen"))
        #expect(!SkillDocument.isValidName("UPPER"))
        #expect(!SkillDocument.isValidName(String(repeating: "a", count: 65)))
        #expect(SkillLibrary.suggestedName(from: "Rename Photos!") == "rename-photos")
        #expect(SkillLibrary.suggestedName(from: "  Café  menu ") == "cafe-menu")
    }
}

@Suite struct SkillLibraryTests {
    @Test func findsSkillsAndReportsBrokenOnes() throws {
        let root = temporaryFolder()
        let skills = library(root)
        try writeSkill("rename-photos", in: skills.folder, "---\nname: rename-photos\ndescription: Renames photos.\n---\nSteps")
        try writeSkill("broken", in: skills.folder, "no front matter")
        try writeSkill("copy", in: skills.folder, "---\nname: rename-photos\ndescription: Same name.\n---\n")
        try FileManager.default.createDirectory(at: skills.folder.appending(path: "empty-folder"), withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: skills.folder.appending(path: "stray.txt"))

        let found = skills.folderSkills()
        #expect(found.map(\.folderName) == ["broken", "copy", "empty-folder", "rename-photos"])
        #expect(found[0].problem == SkillDocument.ParseError.noFrontMatter.description)
        #expect(found[1].problem == nil, "the first folder in order keeps the name")
        #expect(found[2].problem == "There is no SKILL.md in this folder.")
        #expect(found[3].problem == "Another skill already has the name rename-photos.")
        #expect(found.filter(\.isAvailable).map(\.folderName) == ["copy"])
    }

    @Test func aMissingFolderHasOnlyTheSkillsThatArePartOfTheApp() {
        let skills = library(temporaryFolder())
        #expect(skills.folderSkills().isEmpty)
        #expect(skills.skills() == AppSkills.skills)
    }

    @Test func skillsCanBeTurnedOffAndOn() throws {
        let skills = library(temporaryFolder())
        try skills.create(name: "tidy-desktop", description: "Tidies the desktop.")
        #expect(skills.folderSkills().first?.isEnabled == true)
        try skills.setEnabled(false, folderName: "tidy-desktop")
        #expect(skills.folderSkills().first?.isEnabled == false)
        #expect(skills.folderSkills().first?.isAvailable == false)
        try skills.setEnabled(true, folderName: "tidy-desktop")
        #expect(skills.folderSkills().first?.isEnabled == true)
    }

    @Test func createdSkillsParse() throws {
        let skills = library(temporaryFolder())
        let created = try skills.create(name: "mute-at-night", description: "Mutes: at night, #quietly")
        #expect(created.problem == nil)
        #expect(created.description == "Mutes: at night, #quietly")
        #expect(throws: SkillLibrary.LibraryError.alreadyExists("mute-at-night")) {
            try skills.create(name: "mute-at-night", description: "")
        }
        #expect(throws: SkillLibrary.LibraryError.invalidName("Bad Name")) {
            try skills.create(name: "Bad Name", description: "")
        }
        let blank = try skills.create(name: "blank", description: "  ")
        #expect(blank.problem == nil)
    }
}

@Suite struct LoadSkillToolTests {
    private let context = ToolRunContext(callID: "c", confirm: { _ in false })

    @Test func loadsTheInstructionsAndListsFilesBesideThem() async throws {
        let skills = library(temporaryFolder())
        try writeSkill("rename-photos", in: skills.folder,
                       "---\nname: rename-photos\ndescription: Renames photos.\n---\n\nRun rename.sh.\n",
                       extraFiles: ["rename.sh", "lib/helper.py"])
        let output = await LoadSkillTool(library: skills).run(arguments: ["name": "rename-photos"], context: context)
        #expect(output.hasPrefix("Skill rename-photos, from \(skills.folder.plainPath)/rename-photos/SKILL.md\n"))
        #expect(output.contains("- lib/helper.py\n- rename.sh\n"))
        #expect(output.hasSuffix("\n\nRun rename.sh."))
    }

    @Test func refusesUnknownTurnedOffAndBrokenSkills() async throws {
        let skills = library(temporaryFolder())
        try writeSkill("one", in: skills.folder, "---\nname: one\ndescription: First.\n---\n")
        try writeSkill("off", in: skills.folder, "---\nname: off\ndescription: Off.\n---\n")
        try writeSkill("broken", in: skills.folder, "nothing")
        try skills.setEnabled(false, folderName: "off")
        let tool = LoadSkillTool(library: skills)

        let unknown = await tool.run(arguments: ["name": "missing"], context: context)
        #expect(unknown == "Error: there is no skill named \"missing\". The skills are: \(AppSkills.fileIssueAboutThisAppName), one.")
        let off = await tool.run(arguments: ["name": "off"], context: context)
        #expect(off.hasPrefix("Error: the off skill is turned off"))
        let broken = await tool.run(arguments: ["name": "broken"], context: context)
        #expect(broken.hasPrefix("Error: the broken skill cannot be used."))
        let empty = await tool.run(arguments: [:], context: context)
        #expect(empty.hasPrefix("Error:"))
    }
}

@Suite struct AgentPromptTests {
    @Test func theFixedPartIsAlwaysSent() throws {
        let root = temporaryFolder()
        let prompt = AgentPrompt(instructions: InstructionsStore(fileURL: root.appending(path: "instructions.md")), skills: library(root))
        try prompt.instructions.save("   ")
        let text = prompt.current()
        #expect(text.hasPrefix("How this app works."))
        #expect(text.contains("Set destructive to true on run_shell_command"))
        #expect(text.contains("local time it was sent, in square brackets"))
        #expect(text.contains("call load_skill"))
        #expect(text.hasSuffix("Skills you have:\n- \(AppSkills.fileIssueAboutThisAppName) (part of the app): \(AppSkills.skills[0].description)"))
    }

    @Test func theEditablePartComesFirst() throws {
        let root = temporaryFolder()
        let prompt = AgentPrompt(instructions: InstructionsStore(fileURL: root.appending(path: "instructions.md")), skills: library(root))
        try prompt.instructions.save("Talk like a pirate.\n")
        #expect(prompt.current().hasPrefix("Talk like a pirate.\n\nHow this app works."))
        try prompt.instructions.restoreDefault()
        #expect(prompt.current().hasPrefix(AgentInstructions.defaultEditable + "\n\nHow this app works."))
    }

    @Test func listsOnlyAvailableSkillsSortedByName() throws {
        let root = temporaryFolder()
        let skills = library(root)
        try writeSkill("b-folder", in: skills.folder, "---\nname: zebra\ndescription: |\n  Last\n  one.\n---\nSecret body text")
        try writeSkill("a-folder", in: skills.folder, "---\nname: apple\ndescription: First one.\n---\n")
        try writeSkill("c-folder", in: skills.folder, "---\nname: muted\ndescription: Turned off.\n---\n")
        try writeSkill("d-folder", in: skills.folder, "broken")
        try skills.setEnabled(false, folderName: "c-folder")
        let text = AgentPrompt(instructions: InstructionsStore(fileURL: root.appending(path: "i.md")), skills: skills).current()
        #expect(text.hasSuffix(
            "Skills you have:\n- apple: First one.\n- \(AppSkills.fileIssueAboutThisAppName) (part of the app): \(AppSkills.skills[0].description)\n- zebra: Last one."))
        #expect(!text.contains("Secret body text"))
        #expect(!text.contains("muted"))
    }

    @Test func thePromptIsByteStableWhenNothingChanged() throws {
        let root = temporaryFolder()
        let skills = library(root)
        try writeSkill("one", in: skills.folder, "---\nname: one\ndescription: First.\n---\n")
        try writeSkill("two", in: skills.folder, "---\nname: two\ndescription: Second.\n---\n")
        let prompt = AgentPrompt(instructions: InstructionsStore(fileURL: root.appending(path: "i.md")), skills: skills)
        try prompt.instructions.save("Custom text")
        let first = prompt.current()
        // Touching files without changing them, and turning a skill off and on again, changes nothing.
        try prompt.instructions.save("Custom text")
        try skills.setEnabled(false, folderName: "two")
        try skills.setEnabled(true, folderName: "two")
        #expect(Data(prompt.current().utf8) == Data(first.utf8))
        #expect(AgentPrompt(instructions: prompt.instructions, skills: skills).current() == first)
    }

    @Test func theLoopReadsTheInstructionsOncePerInstruction() async throws {
        let store = try ThreadStore(fileURL: temporaryThreadFile())
        let provider = FakeProvider(replies: [
            [.item(toolCall("a", name: "record", arguments: [:]))],
            [.item(assistant("one"))],
            [.item(assistant("two"))],
        ])
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var value = 0
            func next() -> Int { lock.withLock { value += 1; return value } }
        }
        let counter = Counter()
        let loop = AgentLoop(provider: provider, thread: store, tools: [RecordingTool()],
                             instructions: { "version \(counter.next())" })
        try await loop.run("first", onEvent: { _ in }, confirm: { _ in true })
        try await loop.run("second", onEvent: { _ in }, confirm: { _ in true })
        #expect(provider.requests.map(\.instructions) == ["version 1", "version 1", "version 2"])
    }

    @Test func theDataFolderCanBeMovedForManualChecks() {
        #expect(AgentPaths.dataFolder(from: ["app", "--data-folder", "/tmp/x"])?.plainPath == "/tmp/x")
        #expect(AgentPaths.dataFolder(from: ["app", "--data-folder"]) == nil)
        #expect(AgentPaths.dataFolder(from: ["app"]) == nil)
    }
}
