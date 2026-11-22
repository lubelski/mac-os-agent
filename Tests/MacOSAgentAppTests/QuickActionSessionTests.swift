import AppKit
import Foundation
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// A stand-in for a step's tool: it records its calls and returns a fixed result, and never
/// opens anything.
private final class StandInStepTool: AgentTool, @unchecked Sendable {
    let name: String
    let result: String
    private let lock = NSLock()
    private var calls: [JSONValue] = []

    init(_ name: String, result: String) {
        self.name = name
        self.result = result
    }

    var received: [JSONValue] { lock.withLock { calls } }

    var definition: ToolDefinition {
        ToolDefinition(name: name, description: "A stand-in.", parameters: [
            "type": "object", "properties": ["bundle_identifier_or_path": ["type": "string"]],
            "required": ["bundle_identifier_or_path"], "additionalProperties": false,
        ])
    }

    func summary(arguments: JSONValue) -> String { "Open \(arguments["bundle_identifier_or_path"]?.stringValue ?? "")" }

    func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        lock.withLock { calls.append(arguments) }
        return result
    }
}

/// Saves an action with `change_action` on the first request of each instruction, then replies "Done.".
private final class QuickActionSavingProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    static let file = #"{"format": 1, "name": "Start Screensaver", "description": "Starts the screen saver.", "phrases": ["screensaver"], "steps": [{"tool": "open_application", "arguments": {"bundle_identifier_or_path": "/System/Library/CoreServices/ScreenSaverEngine.app"}}]}"#

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let count = lock.withLock { count += 1; return count }
        let arguments: JSONValue = ["operation": "save", "action_id": nil, "file": .string(Self.file)]
        let event: ModelStreamEvent = count % 2 == 1
            ? .item(.toolCall(.init(callID: "call-\(count)", name: ChangeQuickActionTool.name, arguments: arguments.encodedString(), provider: "test", model: "test-model")))
            : .item(.assistantMessage(.init(text: "Done.", provider: "test", model: "test-model")))
        return AsyncThrowingStream { continuation in
            continuation.yield(event)
            continuation.finish()
        }
    }
}

/// Quick actions in the main panel's session: Return runs one with no model request, the run
/// is kept, a failure brings the panel back, the incognito window offers none, and an action
/// the agent saves is announced. Everything is in a temporary folder.
@MainActor
@Suite(.serialized) struct QuickActionSessionTests {
    private let root = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private var library: QuickActionLibrary { QuickActionLibrary(folder: root.appending(path: "quick-actions", directoryHint: .isDirectory)) }

    private static let screensaver = QuickAction(
        id: "start-screensaver", name: "Start Screensaver", description: "Starts the screen saver.", phrases: ["screensaver"],
        steps: [.init(tool: "open_application", arguments: ["bundle_identifier_or_path": "/System/Library/CoreServices/ScreenSaverEngine.app"])])

    final class Recorder {
        var hides = 0
        var shows = 0
        var opened: [String] = []
    }

    private func makeSession(provider: any ModelProvider = EchoProvider(), tools: [any AgentTool]) throws -> (AgentSession, ThreadStore, Recorder) {
        let thread = try ThreadStore(fileURL: root.appending(path: "thread.jsonl"))
        let loop = AgentLoop(provider: provider, thread: thread, tools: tools, episodeTimeout: { 1800 })
        let session = AgentSession(loop: loop, authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        let recorder = Recorder()
        session.instantActions = InstantActions(
            applications: InstantActionPreview.applications, open: { recorder.opened.append($0.name) },
            quickActionLibrary: library, summaries: ToolCallSummaries(tools))
        session.hidePanel = { recorder.hides += 1 }
        session.showPanel = { recorder.shows += 1 }
        return (session, thread, recorder)
    }

    @Test func returnRunsTheActionWithNoModelRequestAndKeepsARecord() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(Self.screensaver)
        let tool = StandInStepTool("open_application", result: "Opened ScreenSaverEngine.")
        let provider = EchoProvider()
        let (session, thread, recorder) = try makeSession(provider: provider, tools: [tool])

        session.draft = "screensaver"
        #expect(session.instantActions.suggestion?.choices.map(\.title) == ["Start Screensaver"])
        #expect(session.instantActions.suggestion?.top.detail == "Open /System/Library/CoreServices/ScreenSaverEngine.app", "the stand-in tool says what it does")
        session.submit()
        await session.waitUntilIdle()

        #expect(tool.received == [["bundle_identifier_or_path": "/System/Library/CoreServices/ScreenSaverEngine.app"]])
        #expect(provider.requests.isEmpty, "the model is never asked")
        #expect(recorder.hides == 1)
        #expect(recorder.shows == 0)
        #expect(session.draft == "")
        let entries = await thread.entries
        #expect(entries.count == 1)
        guard case .userMessage("screensaver", nil, let record?) = entries.first?.item else { Issue.record("no record"); return }
        #expect(record.id == "start-screensaver")
        #expect(record.failedStep == nil)
        let kinds = session.transcript.rows.map(\.kind)
        #expect(kinds.contains { if case .user("screensaver", _, _) = $0 { true } else { false } })
        #expect(kinds.contains { if case .tool("Open ScreenSaverEngine", .finished, "Opened ScreenSaverEngine.") = $0 { true } else { false } })

        // The next message sends the record to the model as the owner's message.
        session.draft = "undo that"
        session.submitToAgent()
        await session.waitUntilIdle()
        let sent = try #require(provider.requests.first)
        #expect(sent.entries.first?.item == entries.first?.item)
    }

    @Test func aFailedStepBringsThePanelBackWithTheText() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(Self.screensaver)
        let tool = StandInStepTool("open_application", result: "Error: there is no application bundle at that path.")
        let (session, _, recorder) = try makeSession(tools: [tool])
        session.draft = "screensaver"
        session.submit()
        await session.waitUntilIdle()
        #expect(recorder.hides == 1)
        #expect(recorder.shows == 1)
        #expect(session.draft == "screensaver", "Command-Return can send it to the agent instead")
        #expect(session.transcript.rows.last?.kind == .error("Start Screensaver failed."))
    }

    @Test func anActionTurnedOffSinceTheRowWasShownDoesNotRun() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(Self.screensaver)
        let tool = StandInStepTool("open_application", result: "Opened.")
        let (session, thread, _) = try makeSession(tools: [tool])
        session.draft = "screensaver"
        #expect(session.instantActions.suggestion != nil)
        // Turned off by hand, which the row has not seen yet.
        var off = Self.screensaver
        off.isEnabled = false
        try Data(off.fileText.utf8).write(to: library.fileURL(id: off.id))
        session.submit()
        await session.waitUntilIdle()
        #expect(tool.received.isEmpty)
        #expect(await thread.entries.isEmpty)
        #expect(session.instantActions.suggestion == nil)
    }

    @Test func theIncognitoWindowOffersNoActionsAndStillOpensApps() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try library.save(Self.screensaver)
        let (main, _, recorder) = try makeSession(tools: [StandInStepTool("open_application", result: "Opened.")])
        main.draft = "screensaver"
        #expect(main.instantActions.suggestion != nil)

        let incognito = AgentSession(
            incognito: { AgentLoop(provider: EchoProvider(), thread: InMemoryThreadStore(), tools: [], episodeTimeout: { .infinity }) },
            signedIn: true)
        incognito.instantActions = main.instantActions.incognitoCopy()
        #expect(incognito.instantActions.quickActionLibrary == nil)
        incognito.draft = "screensaver"
        #expect(incognito.instantActions.suggestion == nil)
        incognito.draft = "open safari"
        incognito.submit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(recorder.opened == ["Safari"])
    }

    @Test func actionsIsASectionOfItsOwnAndDebuggingStaysLast() {
        let sections = SettingsSection.allCases
        #expect(sections.last == .debugging)
        #expect(sections.firstIndex(of: .quickActions) == sections.firstIndex(of: .skills)! + 1)
        #expect(SettingsSection.quickActions.title == "Quick Actions")
        // The stored preference and the `--preview-settings` name are from before the rename.
        #expect(SettingsSection.quickActions.rawValue == "actions")
        #expect(SettingsSection(rawValue: "actions") == .quickActions)
    }

    @Test func anActionTheAgentSavesIsAnnouncedAndOfferedAtOnce() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let step = StandInStepTool("open_application", result: "Opened.")
        let definitions = [step.definition]
        let change = ChangeQuickActionTool(library: library, tools: { definitions })
        let (session, _, _) = try makeSession(provider: QuickActionSavingProvider(), tools: [step, change])
        session.draft = "make starting the screensaver instant"
        session.submitToAgent()
        await session.waitUntilIdle()
        let notices = session.transcript.rows.compactMap { row -> String? in
            if case .notice(let text) = row.kind { text } else { nil }
        }
        #expect(notices == ["The quick action Start Screensaver is ready to use. Type its name and press Return."])
        session.draft = "screensaver"
        #expect(session.instantActions.suggestion?.choices.map(\.title) == ["Start Screensaver"])
    }
}

/// Renders the instant row offering a quick action, and the Quick Actions section of Settings,
/// offscreen for a pull request when screen capture is not available. Run with
/// MAC_OS_AGENT_RENDER_QUICK_ACTIONS set to a folder. The Liquid Glass is drawn as its fallback fill.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_QUICK_ACTIONS"] != nil))
struct QuickActionRenders {
    private var out: URL {
        URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_QUICK_ACTIONS"]!, directoryHint: .isDirectory)
    }

    @Test func rendersTheRowOfferingAnAction() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for name in ["instant-action", "instant-action-beside-apps"] {
            let session = try #require(InstantActionPreview.session(named: name))
            for (themeID, scheme) in [("glass", ColorScheme.light), ("glass", .dark)] {
                let theme = try #require(BuiltInThemes.all.first { $0.id == themeID }?.theme)
                let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
                let view = VStack(spacing: 0) {
                    InstantActionRow(actions: session.instantActions)
                    PanelDivider()
                    HStack(spacing: 10) {
                        Text(verbatim: Mark.prompt).font(.system(size: 17, design: .monospaced)).foregroundStyle(.secondary)
                        Text(verbatim: session.draft).font(.system(size: 15))
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
                try data.write(to: out.appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    @Test func rendersTheActionsSection() throws {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appending(path: "actions-render-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = QuickActionLibrary(folder: folder)
        for action in InstantActionPreview.actions { try library.save(action) }
        var off = QuickAction(id: "focus-music", name: "Focus Music", description: "Opens Music for a work session.",
                              steps: [.init(tool: "open_application", arguments: ["bundle_identifier_or_path": "com.apple.Music"])])
        off.isEnabled = false
        try library.save(off)
        try Data("{ \"format\": 1, \"name\": \"Half Written\"".utf8).write(to: folder.appending(path: "half-written.json"))
        let registry = ToolRegistry(builtIn: BuiltInTools.make())
        let model = QuickActionsSettingsModel(library: library, tools: registry.definitions, summaries: registry.summaries, watches: false)
        for (selection, name) in [("start-screensaver", "actions-settings"), ("spotify-focus", "actions-settings-two-steps"), ("half-written", "actions-settings-problem")] {
            model.selection = selection
            for dark in [false, true] {
                try write(QuickActionsSettingsView(model: model).background(Color(nsColor: .windowBackgroundColor)),
                          size: NSSize(width: 700, height: 560), dark: dark,
                          to: out.appending(path: "\(name)-\(dark ? "dark" : "light").png"))
            }
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
