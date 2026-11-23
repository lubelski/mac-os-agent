import AppKit
import Foundation
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// A stand-in data folder with invented memory: a few core lines, two topic files, an archived
/// one, and some history. Never the real data folder.
@MainActor
private func standInMemory() throws -> (MemoryLibrary, AgentPrompt) {
    let root = FileManager.default.temporaryDirectory.appending(path: "mac-os-agent-memory-app-\(UUID().uuidString)", directoryHint: .isDirectory)
    let library = MemoryLibrary(folder: root.appending(path: "memory", directoryHint: .isDirectory))
    let episode = UUID()
    try library.apply(.append(file: "core", text: "- Goes by Sam.\n- Prefers Celsius and the 24-hour clock.\n- Never empty the Trash without asking."), cause: .episode(episode))
    try library.apply(.create(name: "travel-plans", description: "Trips planned for next year. Read for flights, hotels, or packing.", body: "- A week in Lisbon in May.\n- Window seats."), cause: .episode(episode))
    try library.apply(.append(file: "travel-plans", text: "- Carry-on only."), cause: .episode(episode))
    try library.apply(.create(name: "garden", description: "The vegetable garden. Read for plants or watering.", body: "Beans by the fence."), cause: .episode(episode))
    try library.apply(.create(name: "old-car", description: "The car sold last year.", body: "A blue hatchback."), cause: .episode(episode))
    try library.apply(.delete(file: "old-car"), cause: .episode(episode))
    let prompt = AgentPrompt(
        instructions: InstructionsStore(fileURL: root.appending(path: "instructions.md")),
        skills: SkillLibrary(folder: root.appending(path: "skills"), settingsFile: root.appending(path: "skill-settings.json")),
        memories: library)
    return (library, prompt)
}

/// Replies with one `change_memory` call, then "Noted.".
private final class RememberingProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let count = lock.withLock { count += 1; return count }
        let arguments: JSONValue = ["operation": "append", "file": "core", "old_text": nil, "text": "- Their dog is called Rufus.", "description": nil, "new_name": nil]
        let event: ModelStreamEvent = count == 1
            ? .item(.toolCall(.init(callID: "call-1", name: ChangeMemoryTool.name, arguments: arguments.encodedString(), provider: "test", model: "test-model")))
            : .item(.assistantMessage(.init(text: "Noted.", provider: "test", model: "test-model")))
        return AsyncThrowingStream { continuation in
            continuation.yield(event)
            continuation.finish()
        }
    }
}

@MainActor
@Suite(.serialized) struct MemorySettingsTests {
    @Test func memoryComesAfterInstructionsAndDebuggingStaysLast() {
        let sections = SettingsSection.allCases
        #expect(sections.last == .debugging)
        #expect(sections.firstIndex(of: .memory) == sections.firstIndex(of: .instructions)! + 1)
    }

    @Test func theModelListsTheFilesAndTheirHistory() throws {
        let (_, prompt) = try standInMemory()
        let model = MemorySettingsModel(prompt: prompt, watches: false)
        #expect(model.core?.text.contains("Goes by Sam.") == true)
        #expect(model.topics.map(\.id) == ["garden", "travel-plans"])
        #expect(model.archived.map(\.id) == ["old-car"])
        model.selection = .topic("travel-plans")
        #expect(model.history.map(\.operation) == [.append, .create])
        #expect(model.history.allSatisfy { $0.memoryCause.title == "Agent" })
        // Before any request, the block shown is the one the next request would take.
        #expect(model.block?.taken == nil)
        #expect(model.block?.contents == MemoryBlock.contents(prompt.memories!))
        _ = prompt.current(episodeID: UUID())
        #expect(model.block?.taken != nil)
    }

    @Test func editingRestoringAndArchivingWriteThroughTheJournal() throws {
        let (library, prompt) = try standInMemory()
        let model = MemorySettingsModel(prompt: prompt, watches: false)
        model.selection = .core
        model.beginEditing()
        model.editText = "- Goes by Sam.\n"
        model.saveEditing()
        #expect(model.errorMessage == nil)
        #expect(library.core().text == "- Goes by Sam.\n")
        #expect(library.journal.entries().last?.operation == .edit)
        #expect(library.journal.entries().last?.memoryCause == .settings)

        // The first revision, restored, is a new entry; nothing earlier changes.
        let count = library.journal.entries().count
        let first = try #require(model.history.last)
        model.viewedRevision = first.id
        model.restoreRevision()
        #expect(library.core().text.contains("Never empty the Trash without asking."))
        #expect(library.journal.entries().count == count + 1)
        #expect(library.journal.entries().last?.operation == .restore)
        #expect(model.viewedRevision == nil)

        model.selection = .topic("garden")
        model.archive()
        #expect(library.topics().map(\.id) == ["travel-plans"])
        #expect(model.archived.map(\.id) == ["garden", "old-car"])
        model.selection = .archived("old-car")
        model.unarchive()
        #expect(library.topics().map(\.id) == ["old-car", "travel-plans"])
        #expect(model.selection == .topic("old-car"))
        #expect(library.journal.entries().suffix(4).allSatisfy { $0.memoryCause == .settings })
        #expect(library.reconcile().isEmpty)
    }

    @Test func aTurnThatChangesMemoryEndsWithANotice() async throws {
        let (library, _) = try standInMemory()
        let thread = try ThreadStore(fileURL: library.folder.deletingLastPathComponent().appending(path: "thread.jsonl"))
        let loop = AgentLoop(provider: RememberingProvider(), thread: thread, tools: [ChangeMemoryTool(library: library)], episodeTimeout: { 1800 })
        let session = AgentSession(loop: loop, authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.memories = library
        session.draft = "remember my dog is Rufus"
        session.submitToAgent()
        await session.waitUntilIdle()
        let notices = session.transcript.rows.compactMap { row -> String? in
            if case .notice(let text) = row.kind { text } else { nil }
        }
        #expect(notices == ["Remembered in core."])
    }
}

/// Renders the Memory section, with a file's history and a revision showing, and the panel's
/// notice, offscreen for a pull request when screen capture is not available. Run with
/// MAC_OS_AGENT_RENDER_MEMORY set to a folder. The Liquid Glass is drawn as its fallback fill.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_MEMORY"] != nil))
struct MemoryRenders {
    private var out: URL {
        URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_MEMORY"]!, directoryHint: .isDirectory)
    }

    @Test func rendersTheMemorySection() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (_, prompt) = try standInMemory()
        _ = prompt.current(episodeID: UUID())
        let model = MemorySettingsModel(prompt: prompt, watches: false)
        let states: [(String, MemorySettingsModel.Item, Bool)] = [
            ("memory-core", .core, false), ("memory-topic-history", .topic("travel-plans"), false),
            ("memory-revision", .topic("travel-plans"), true), ("memory-block", .block, false),
        ]
        for (name, item, revision) in states {
            model.selection = item
            if revision { model.viewedRevision = model.history.last?.id }
            for dark in [false, true] {
                try write(MemorySettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                          size: NSSize(width: 760, height: 620), dark: dark,
                          to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func rendersTheNotice() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var notice = Transcript()
        notice.appendNotice("Remembered in travel-plans.", id: "notice")
        for (themeID, scheme) in [("glass", ColorScheme.light), ("glass", .dark)] {
            let theme = try #require(BuiltInThemes.all.first { $0.id == themeID }?.theme)
            let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
            let view = VStack(alignment: .leading, spacing: 10) {
                RowView(row: TranscriptRow(id: "agent", kind: .assistant("I'll remember that you fly carry-on only.")), now: Date())
                ForEach(notice.rows) { row in RowView(row: row, now: Date()) }
            }
            .frame(width: 640, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .foregroundStyle(palette.primary)
            .background(palette.fallbackFill)
            .environment(\.panelPalette, palette)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
            try data.write(to: out.appending(path: "memory-notice-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    private func write(_ view: some View, size: NSSize, dark: Bool, to url: URL) throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        host.sizingOptions = []
        host.appearance = appearance
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
