import AppKit
import Foundation
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

private func skillText(_ name: String, _ description: String, extra: String = "", body: String = "Do the thing.") -> String {
    "---\nname: \(name)\ndescription: \(description)\n\(extra)---\n\n\(body)\n"
}

private func writeSkill(_ name: String, in folder: URL, _ text: String) throws {
    let skillFolder = folder.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: skillFolder, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: skillFolder.appending(path: "SKILL.md"), options: .atomic)
}

/// Waits for a condition on the main actor, checking every few milliseconds, up to two seconds.
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// A tool that writes a skill into the skills folder, as the agent does with the shell.
private struct WriteSkillTool: AgentTool {
    let folder: URL

    var definition: ToolDefinition {
        ToolDefinition(name: "write_skill", description: "Writes a skill.", parameters: ["type": "object"])
    }

    func summary(arguments: JSONValue) -> String { "write a skill" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        let name = arguments["name"]?.stringValue ?? "tidy-downloads"
        try? writeSkill(name, in: folder, skillText(name, "Tidies the Downloads folder."))
        return "written"
    }
}

/// Calls `write_skill` on the first request of each instruction, then replies "Done.".
private final class SkillWritingProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ModelRequest] = []
    var requests: [ModelRequest] { lock.withLock { recorded } }

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let count = lock.withLock { recorded.append(request); return recorded.count }
        let event: ModelStreamEvent = count % 2 == 1
            ? .item(.toolCall(.init(callID: "call-\(count)", name: "write_skill", arguments: "{}", provider: "test", model: "test-model")))
            : .item(.assistantMessage(.init(text: "Done.", provider: "test", model: "test-model")))
        return AsyncThrowingStream { continuation in
            continuation.yield(event)
            continuation.finish()
        }
    }
}

/// Skills as slash commands in the main panel: the list, completing, invoking, and staying
/// live as the skills folder changes, against a temporary folder.
@MainActor
@Suite(.serialized) struct SkillCommandSessionTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var library: SkillLibrary {
        SkillLibrary(folder: root.appending(path: "skills", directoryHint: .isDirectory),
                     settingsFile: root.appending(path: "skill-settings.json"))
    }

    private func makeSession(provider: any ModelProvider = EchoProvider(), tools: [any AgentTool] = []) throws -> (AgentSession, ThreadStore) {
        let thread = try ThreadStore(fileURL: root.appending(path: "thread.jsonl"))
        let loop = AgentLoop(provider: provider, thread: thread, tools: tools)
        let session = AgentSession(loop: loop, authenticator: nil, signedIn: true)
        session.skillCommands = SkillCommandsModel(library: library)
        return (session, thread)
    }

    @Test func aSkillWrittenWhileTheAppRunsIsListedWithoutARelaunch() async throws {
        try FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        let (session, _) = try makeSession()
        session.draft = "/"
        #expect(session.commandSuggestions.map(\.name) == ["/new", "/incognito"])

        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos by date."))
        #expect(await eventually { session.commandSuggestions.map(\.name) == ["/new", "/incognito", "/rename-photos"] })
        #expect(session.commandSuggestions.last?.summary() == "Renames photos by date.")

        // Changed by hand, as in an editor that replaces the file.
        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos by the date taken."))
        #expect(await eventually { session.commandSuggestions.last?.summary() == "Renames photos by the date taken." })

        // Broken: not offered.
        try writeSkill("rename-photos", in: library.folder, "no front matter")
        #expect(await eventually { session.commandSuggestions.map(\.name) == ["/new", "/incognito"] })

        // Fixed, then removed in Finder.
        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos."))
        #expect(await eventually { session.commandSuggestions.count == 3 })
        try FileManager.default.removeItem(at: library.folder.appending(path: "rename-photos"))
        #expect(await eventually { session.commandSuggestions.count == 2 })
    }

    @Test func turningASkillOffInSettingsTakesItOutAtOnce() throws {
        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos."))
        let (session, _) = try makeSession()
        session.draft = "/ren"
        #expect(session.commandSuggestions.map(\.name) == ["/rename-photos"])
        try library.setEnabled(false, folderName: "rename-photos")
        #expect(session.commandSuggestions.isEmpty)
        try library.setEnabled(true, folderName: "rename-photos")
        #expect(session.commandSuggestions.map(\.name) == ["/rename-photos"])
    }

    @Test func theSkillsFolderMadeAfterLaunchIsPickedUpOnTheNextSummon() async throws {
        let (session, _) = try makeSession()
        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos."))
        session.panelDidAppear()
        session.draft = "/r"
        #expect(session.commandSuggestions.map(\.name) == ["/rename-photos"])
        // And it is watched from then on.
        try writeSkill("resize-images", in: library.folder, skillText("resize-images", "Resizes images."))
        #expect(await eventually { session.commandSuggestions.map(\.name) == ["/rename-photos", "/resize-images"] })
    }

    @Test func tabAndReturnCompleteTheChosenCommandAndEscapeDismissesTheList() throws {
        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos."))
        try writeSkill("resize-images", in: library.folder, skillText("resize-images", "Resizes images."))
        let (session, _) = try makeSession()
        session.draft = "/re"
        #expect(session.moveHintSelection(by: 1))
        #expect(session.hintSelection == 1)
        #expect(session.completeHint())
        #expect(session.draft == "/resize-images ")
        #expect(session.commandSuggestions.map(\.name) == ["/resize-images"])

        session.draft = "/ren"
        session.submit()
        #expect(session.draft == "/rename-photos ")
        #expect(!session.isRunning)

        session.draft = "/n"
        session.submit()
        #expect(session.draft == "/new")

        // Escape hides the list for this draft and the next Escape goes on.
        session.draft = "/re"
        #expect(session.dismissSuggestionOrHint())
        #expect(session.commandSuggestions.isEmpty)
        #expect(!session.dismissSuggestionOrHint())
        session.draft = "/res"
        #expect(session.commandSuggestions.isEmpty)
        session.draft = ""
        session.draft = "/"
        #expect(session.commandSuggestions.count == 4)
    }

    @Test func invokingASkillShowsTheTypedLineAndSendsItsInstructions() async throws {
        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos.", body: "1. Read the dates."))
        let provider = EchoProvider()
        let (session, thread) = try makeSession(provider: provider)
        session.draft = "/rename-photos the trip folder"
        session.submit()
        await session.waitUntilIdle()

        #expect(session.transcript.rows.contains {
            if case .user(let text, _, _) = $0.kind { text == "/rename-photos the trip folder" } else { false }
        })
        let stored = try #require(await thread.entries.first)
        guard case .userMessage(let text, let skill, _) = stored.item else {
            Issue.record("not a message")
            return
        }
        #expect(text == "/rename-photos the trip folder")
        #expect(skill?.name == "rename-photos")
        #expect(skill?.message.contains("1. Read the dates.") == true)
        let sent = provider.requests.first?.entries.first
        #expect(sent?.item == stored.item)
    }

    @Test func aSkillTurnedOffBeforeSendingIsNotSent() async throws {
        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos."))
        let provider = EchoProvider()
        let (session, thread) = try makeSession(provider: provider)
        session.draft = "/rename-photos x"
        // Turned off by hand, which the list has not seen yet.
        try Data(#"{"disabled":["rename-photos"]}"#.utf8).write(to: library.settingsFile)
        session.submitToAgent()
        await session.waitUntilIdle()
        #expect(provider.requests.isEmpty)
        #expect(await thread.entries.isEmpty)
        #expect(session.draft == "/rename-photos x")
        #expect(session.commandSuggestions.isEmpty)
    }

    @Test func aSkillTheAgentWritesIsAnnouncedWhenItsTurnEnds() async throws {
        try FileManager.default.createDirectory(at: library.folder, withIntermediateDirectories: true)
        let (session, _) = try makeSession(provider: SkillWritingProvider(), tools: [WriteSkillTool(folder: library.folder)])
        session.draft = "make a skill for tidying downloads"
        session.submit()
        await session.waitUntilIdle()

        let notices = session.transcript.rows.compactMap { row -> String? in
            if case .notice(let text) = row.kind { text } else { nil }
        }
        #expect(notices == ["/tidy-downloads is ready to use."])
        session.draft = "/t"
        #expect(session.commandSuggestions.map(\.name) == ["/tidy-downloads"])

        // A turn that changes no skill says nothing more.
        session.draft = "thanks"
        session.submit()
        await session.waitUntilIdle()
        #expect(session.transcript.rows.filter { if case .notice = $0.kind { true } else { false } }.count == 1)
    }

    @Test func theIncognitoWindowOffersNoSkills() throws {
        try writeSkill("rename-photos", in: library.folder, skillText("rename-photos", "Renames photos."))
        let session = AgentSession(previewEntries: [], incognito: true)
        session.skillCommands = SkillCommandsModel(library: library)
        session.draft = "/"
        #expect(session.commandSuggestions.map(\.name) == ["/new", "/incognito"])
        #expect(session.slashMenu.parse("/rename-photos x") == nil)
    }
}

/// Renders the list of slash commands with skills in it, and the notice after the agent wrote
/// a skill, offscreen for a pull request when screen capture is not available. Run with
/// MAC_OS_AGENT_RENDER_SKILL_COMMANDS set to a folder. The Liquid Glass behind them is not
/// drawn offscreen, so they sit on the theme's fallback fill.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SKILL_COMMANDS"] != nil))
struct SkillCommandRenders {
    static let menu = SlashCommandMenu(skills: [
        SkillCommand(name: "rename-photos", description: "Renames photos in a folder by the date they were taken.", folderName: "rename-photos"),
        SkillCommand(name: "resize-images", description: "Resizes images to a width, keeping the originals.", folderName: "resize-images"),
        SkillCommand(name: "tidy-downloads", description: "Moves old files in Downloads to the Trash, after asking.", folderName: "tidy-downloads"),
    ])

    @Test func rendersTheListAndTheNotice() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SKILL_COMMANDS"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var notice = Transcript()
        notice.appendNotice("/tidy-downloads is ready to use.", id: "notice")
        let states: [(name: String, draft: String, selection: Int, rows: [TranscriptRow])] = [
            ("slash-list", "/", 2, []),
            ("slash-filtered", "/re", 0, []),
            ("slash-argument", "/rename-photos ~/Pictures/Trip", 0, []),
            ("skill-notice", "", 0, Array(notice.rows.suffix(1))),
        ]
        for state in states {
            let session = AgentSession(previewEntries: [])
            session.skillCommands = SkillCommandsModel(menu: Self.menu)
            session.draft = state.draft
            for _ in 0..<state.selection { _ = session.moveHintSelection(by: 1) }
            for (themeID, scheme) in [("glass", ColorScheme.light), ("glass", .dark), ("tidewater", .dark), ("paper", .light)] {
                let theme = try #require(BuiltInThemes.all.first { $0.id == themeID }?.theme)
                let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
                let view = VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        RowView(row: TranscriptRow(id: "agent", kind: .assistant("Here is the folder.")), now: Date())
                        ForEach(state.rows) { row in RowView(row: row, now: Date()) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    CommandHint(suggestions: session.commandSuggestions, selection: session.hintSelection, incognito: false)
                    PanelDivider()
                    HStack(spacing: 10) {
                        InputMark(target: nil)
                        Text(verbatim: session.draft.isEmpty ? "Tell your Mac what to do" : session.draft)
                            .font(.system(size: 15))
                            .foregroundStyle(session.draft.isEmpty ? .tertiary : .primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                }
                .frame(width: 640)
                .foregroundStyle(palette.primary)
                .background(palette.fallbackFill)
                .environment(\.panelPalette, palette)
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
                try data.write(to: folder.appending(path: "\(state.name)-\(themeID)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
