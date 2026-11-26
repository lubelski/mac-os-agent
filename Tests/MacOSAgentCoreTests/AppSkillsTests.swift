import Foundation
import Testing
@testable import MacOSAgentCore

/// Skills that are part of the app: listed to the agent beside the owner's skills, loaded with
/// `load_skill`, and out of reach of anything in the skills folder.
@Suite struct AppSkillsTests {
    private let name = AppSkills.fileIssueAboutThisAppName
    private let context = ToolRunContext(callID: "c", confirm: { _ in false })
    private let versions = AppSkillContext(appVersion: "1.0.0", macOSVersion: "Version 27.0 (Build 27A100)")

    private func library(appSkillContext: AppSkillContext? = nil) -> SkillLibrary {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return SkillLibrary(
            folder: root.appending(path: "skills", directoryHint: .isDirectory),
            settingsFile: root.appending(path: "skill-settings.json"),
            appSkillContext: appSkillContext ?? versions)
    }

    private func writeSkill(_ folderName: String, in library: SkillLibrary, _ text: String) throws {
        let folder = library.folder.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appending(path: SkillLibrary.fileName), options: .atomic)
    }

    private func prompt(_ library: SkillLibrary) -> AgentPrompt {
        AgentPrompt(
            instructions: InstructionsStore(fileURL: library.folder.deletingLastPathComponent().appending(path: "instructions.md")),
            skills: library)
    }

    private var expectedLine: String {
        "- file-issue-about-this-app (part of the app): File a bug or a request about this app, mac-os-agent, as a public "
            + "GitHub issue that the person reads and submits. Use when they ask to report a problem with the app, ask for a "
            + "change to it, or file an issue about it."
    }

    // MARK: - The list the agent is sent

    @Test func theAgentIsSentOneLineForItAmongTheOwnersSkills() throws {
        let skills = library()
        try writeSkill("rename-photos", in: skills, "---\nname: rename-photos\ndescription: Renames photos.\n---\n")
        try writeSkill("apple", in: skills, "---\nname: apple\ndescription: First.\n---\n")
        let text = prompt(skills).current()
        #expect(text.hasSuffix("Skills you have:\n- apple: First.\n" + expectedLine + "\n- rename-photos: Renames photos."))
        #expect(text.contains("A skill marked part of the app comes with the app. It is not in that folder, it cannot be changed, and a folder with the same name is not used."))
        // Only the name and description. The body is read with load_skill.
        #expect(!text.contains("lubelski/mac-os-agent"))
    }

    @Test func theListIsTheSameBytesWhateverTheVersionsAndFromLaunchToLaunch() {
        let one = prompt(library(appSkillContext: versions)).current()
        let other = prompt(library(appSkillContext: AppSkillContext(appVersion: nil, macOSVersion: "Version 28.1"))).current()
        // Each library has its own folder, which the instructions name, so compare past it.
        func listed(_ text: String) -> Substring { text[text.range(of: "Skills you have:")!.lowerBound...] }
        #expect(listed(one) == listed(other))
        #expect(listed(one) == "Skills you have:\n" + expectedLine)
        #expect(AppSkills.skills == AppSkills.skills.sorted { $0.name < $1.name })
    }

    @Test func itIsAlwaysOnAndListedFirstInSettings() throws {
        let skills = library()
        try writeSkill("apple", in: skills, "---\nname: apple\ndescription: First.\n---\n")
        let listed = skills.skills()
        #expect(listed.map(\.id) == ["app.\(name)", "apple"])
        let skill = listed[0]
        #expect(skill.isPartOfApp && skill.isAvailable && skill.isUserInvocable)
        #expect(skill.folderURL == nil && skill.fileURL == nil)
        let contents = skills.contents(of: skill)
        #expect(contents.files.isEmpty)
        #expect(contents.instructions.hasPrefix("Use this when the person wants to report a bug in this app"))
    }

    // MARK: - Loading it

    @Test func loadSkillGivesTheGuidanceAndTheVersions() async {
        let output = await LoadSkillTool(library: library()).run(arguments: ["name": .string(name)], context: context)
        #expect(output.hasPrefix(
            "Skill file-issue-about-this-app, part of the app. It is not in the skills folder, and it cannot be changed.\n\n"
                + "Use this when the person wants to report a bug in this app"))
        #expect(output.contains("https://github.com/lubelski/mac-os-agent/issues/new?title=TITLE&body=BODY"))
        #expect(output.contains("open it with open_item"))
        #expect(output.contains("Keep the body to 1,500 characters before encoding"))
        #expect(output.contains("Never file the issue yourself"))
        #expect(output.hasSuffix("## This Mac\n\n- App: mac-os-agent 1.0.0\n- macOS: Version 27.0 (Build 27A100)"))
    }

    @Test func aBuildWithNoVersionSaysSo() async {
        let skills = library(appSkillContext: AppSkillContext(appVersion: nil, macOSVersion: "Version 27.0"))
        let output = await LoadSkillTool(library: skills).run(arguments: ["name": .string(name)], context: context)
        #expect(output.hasSuffix("- App: mac-os-agent, a development build with no version number\n- macOS: Version 27.0"))
    }

    @Test func itCanBeInvokedWithASlash() throws {
        let skills = library()
        let menu = SlashCommandMenu(skills: skills.skills())
        let command = try #require(menu.skills.first { $0.name == name })
        #expect(menu.parse("/\(name) the panel forgets its size") == .skill(command, text: "the panel forgets its size"))
        let invocation = try skills.invocation(typed: "/\(name) the panel forgets its size", command: command).get()
        #expect(invocation.message.contains("<skill name=\"\(name)\">\nSkill \(name), part of the app."))
        #expect(invocation.message.contains("- App: mac-os-agent 1.0.0"))
    }

    // MARK: - The skills folder cannot change it

    @Test func aUserSkillWithTheSameNameDoesNotReplaceIt() async throws {
        let skills = library()
        // Same folder name and front matter name, and another folder with only the name.
        try writeSkill(name, in: skills, "---\nname: \(name)\ndescription: Files issues with gh.\n---\n\nRun gh issue create.\n")
        try writeSkill("my-issues", in: skills, "---\nname: \(name)\ndescription: Also mine.\n---\n\nUse curl.\n")

        let output = await LoadSkillTool(library: skills).run(arguments: ["name": .string(name)], context: context)
        #expect(output.contains("part of the app"))
        #expect(!output.contains("gh issue create") && !output.contains("curl."))

        // Listed once, with the app's description. The folders are shown with a problem and not used.
        let text = prompt(skills).current()
        #expect(text.hasSuffix("Skills you have:\n" + expectedLine))
        #expect(!text.contains("Files issues with gh.") && !text.contains("Also mine."))
        let folders = skills.skills().filter { !$0.isPartOfApp }
        #expect(folders.map(\.folderName) == [name, "my-issues"])
        #expect(folders.allSatisfy {
            $0.problem == "A skill that is part of the app is named \(name), so this one is not used. Rename it to use it."
        })
        #expect(SlashCommandMenu(skills: skills.skills()).skills.filter { $0.name == name }.count == 1)
    }

    @Test func theSkillsFolderAndItsSettingsCannotTurnItOffOrChangeIt() async throws {
        let skills = library()
        try writeSkill(name, in: skills, "no front matter")
        try skills.setEnabled(false, folderName: name)
        #expect(skills.disabledFolders() == [name])

        let listed = try #require(skills.skills().first { $0.isPartOfApp })
        #expect(listed.isEnabled && listed.isAvailable)
        #expect(prompt(skills).current().hasSuffix(expectedLine))
        let output = await LoadSkillTool(library: skills).run(arguments: ["name": .string(name)], context: context)
        #expect(output.hasPrefix("Skill \(name), part of the app."))

        // Removing the whole folder leaves it too.
        try FileManager.default.removeItem(at: skills.folder)
        #expect(skills.skills() == AppSkills.skills)
        #expect(await LoadSkillTool(library: skills).run(arguments: ["name": .string(name)], context: context) == output)
    }

    @Test func itsNameIsNotOneOfTheAppsOwnCommands() {
        for skill in AppSkills.skills {
            #expect(SlashCommandMenu.builtInClash(for: skill.name) == nil)
            #expect(SkillDocument.isValidName(skill.name))
        }
    }
}
