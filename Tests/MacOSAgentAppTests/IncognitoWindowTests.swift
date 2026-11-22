import AppKit
import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// Every file in a flat folder with its bytes, by name.
private func snapshot(of folder: URL) throws -> [String: Data] {
    var files: [String: Data] = [:]
    let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
    while let url = enumerator?.nextObject() as? URL {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
        files[url.lastPathComponent] = try Data(contentsOf: url)
    }
    return files
}

/// The incognito window, driven through the real controller, session, and panel, with a kept
/// thread, its index, the usage log, the instant actions file, and a defaults suite of its own
/// in a temporary folder. The windows never go on screen: ordering in and out is recorded.
@MainActor
@Suite(.serialized) struct IncognitoWindowTests {
    init() { _ = NSApplication.shared }

    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-incognito-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let suiteName = "mac-os-agent-incognito-tests-\(UUID().uuidString)"
    private let keptProvider = EchoProvider()
    private let incognitoProvider = EchoProvider()
    private let standIn = StandInScreens()
    private let recorder = WindowRecorder()

    private struct Harness {
        let main: AgentSession
        let thread: ThreadStore
        let controller: IncognitoWindowController
        let store: InstantActionHistoryStore
        let defaults: UserDefaults
        var opened: () -> [String]
    }

    private func makeHarness() throws -> Harness {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"), searchIndexURL: folder.appending(path: "history-index.sqlite"))
        let usageLog = UsageLog(fileURL: folder.appending(path: "usage.jsonl"))
        let prompt = AgentPrompt(
            instructions: InstructionsStore(fileURL: folder.appending(path: "instructions.md")),
            skills: SkillLibrary(folder: folder.appending(path: "skills"), settingsFile: folder.appending(path: "skill-settings.json")))
        let main = AgentSession(
            loop: AgentLoop(provider: keptProvider, thread: thread, tools: [], usageLog: usageLog, episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        let store = InstantActionHistoryStore(fileURL: folder.appending(path: "instant-actions.json"))
        final class Opened { var names: [String] = [] }
        let opened = Opened()
        main.instantActions = InstantActions(applications: InstantActionPreview.applications, store: store, open: { opened.names.append($0.name) })

        let incognitoProvider = incognitoProvider
        let standIn = standIn
        let recorder = recorder
        let controller = IncognitoWindowController(
            makeSession: {
                let session = AgentSession(
                    incognito: { IncognitoWindowController.makeLoop(provider: incognitoProvider, prompt: prompt, usageLog: usageLog) },
                    signedIn: main.signInState == .signedIn)
                session.instantActions = main.instantActions.incognitoCopy()
                return session
            },
            makePanel: { session in
                // A defaults suite is passed on purpose: the incognito window must ignore it.
                let panel = SummonPanel(
                    session: session, role: .incognito, remembersFrame: true, placementDefaults: defaults,
                    screens: { standIn.screens }, mouseLocation: { standIn.mouse })
                panel.orderIn = { _, makeKey in recorder.orderedIn.append(makeKey) }
                panel.orderAway = { _ in recorder.orderedAway += 1 }
                panel.drivesSlidesWithTheDisplay = false
                return panel
            })
        main.openIncognito = { controller.open() }
        return Harness(main: main, thread: thread, controller: controller, store: store, defaults: defaults, opened: { opened.names })
    }

    private func cleanUp() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    private func send(_ text: String, in session: AgentSession) async {
        session.draft = text
        session.submit()
        await session.waitUntilIdle()
    }

    private func userTexts(_ session: AgentSession) -> [String] {
        session.transcript.rows.compactMap { if case .user(let text, _, _) = $0.kind { text } else { nil } }
    }

    @Test func itLeavesNoTraceByteForByte() async throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        // Something kept first, so every file exists, and an app taken once, so the instant
        // actions file has something in it.
        await send("kept message", in: harness.main)
        harness.main.draft = "safari"
        harness.main.submit()
        try await Task.sleep(for: .milliseconds(20))
        await harness.store.waitForWrites()
        let mainRows = harness.main.transcript.rows
        let before = try snapshot(of: folder)
        let usageBefore = try #require(before["usage.jsonl"])
        #expect(before["instant-actions.json"] != nil)
        let defaultsBefore = harness.defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("SummonPanel") || $0.key.hasPrefix("ToolInspector") || $0.key.hasPrefix("NSWindow") }

        await send("/incognito", in: harness.main)
        let session = try #require(harness.controller.session)
        let panel = try #require(harness.controller.panel)
        #expect(session.isIncognito)
        await send("a secret plan for saturday", in: session)
        session.draft = "xcode"
        session.submit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.opened() == ["Safari", "Xcode"])
        await send("/new", in: session)
        await send("another secret about saturday", in: session)
        // The owner moves and resizes the window, and opens the inspector width.
        panel.setFrame(CGRect(x: 100, y: 100, width: 600, height: 520), display: false)
        panel.performClose(nil)
        #expect(!harness.controller.isOpen)
        await harness.store.waitForWrites()

        // The model saw the incognito tools and instructions, never the kept thread.
        #expect(incognitoProvider.requests.count == 2)
        for request in incognitoProvider.requests {
            #expect(request.tools.map(\.name) == BuiltInTools.incognitoNames)
            #expect(request.instructions == AgentInstructions.assembleIncognito(editable: AgentInstructions.defaultEditable))
            #expect(!request.entries.contains { $0.item == .userMessage(text: "kept message") })
        }
        #expect(keptProvider.requests.count == 1)

        // On disk, only the usage log grew, by token counts with no content.
        var after = try snapshot(of: folder)
        let removedUsage = after.removeValue(forKey: "usage.jsonl")
        let usageAfter = try #require(removedUsage)
        var beforeWithoutUsage = before
        beforeWithoutUsage.removeValue(forKey: "usage.jsonl")
        #expect(after == beforeWithoutUsage)
        #expect(usageAfter.count > usageBefore.count)
        #expect(usageAfter.prefix(usageBefore.count) == usageBefore)
        #expect(!String(decoding: usageAfter, as: UTF8.self).contains("secret"))
        for (_, data) in after { #expect(data.range(of: Data("secret".utf8)) == nil) }
        #expect(await harness.thread.search("secret").isEmpty)
        #expect(await harness.thread.search("saturday").isEmpty)
        // Nothing learned, and nothing in the defaults.
        #expect(!harness.store.history.wasPicked("application:/Applications/Xcode.app", for: "xcode"))
        let defaultsAfter = harness.defaults.dictionaryRepresentation().filter { $0.key.hasPrefix("SummonPanel") || $0.key.hasPrefix("ToolInspector") || $0.key.hasPrefix("NSWindow") }
        #expect(defaultsAfter.keys.sorted() == defaultsBefore.keys.sorted())
        #expect(harness.defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        // The main panel is exactly as it was.
        #expect(harness.main.transcript.rows == mainRows)
        #expect(harness.main.kind == .kept)
    }

    @Test func openingAgainBringsTheSameWindowForward() async throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        harness.controller.open()
        let panel = try #require(harness.controller.panel)
        let session = try #require(harness.controller.session)
        await send("/incognito", in: harness.main)
        #expect(harness.controller.panel === panel)
        #expect(harness.controller.session === session)
        #expect(recorder.orderedIn == [true, true])
        // `/incognito` inside the window says so and sends nothing.
        await send("/incognito", in: session)
        #expect(session.transcript.rows.contains { $0.kind == .notice("This window is already incognito. Nothing from it is kept.") })
        #expect(incognitoProvider.requests.isEmpty)
        #expect(harness.controller.panel === panel)
    }

    @Test func itOpensBesideTheMainPanelWithNoLayouts() throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        let main = CGRect(x: 1700, y: 300, width: 640, height: 560)
        harness.controller.mainPanelFrame = { main }
        harness.controller.open()
        let panel = try #require(harness.controller.panel)
        #expect(panel.role == .incognito)
        #expect(panel.panelFrame == PanelGeometry.besideFrame(size: SummonPanel.incognitoSize, beside: main, in: StandInScreens.external.visible))
        #expect(!panel.panelFrame.intersects(main))
        #expect(!panel.placement.offersLayouts)
        #expect(panel.placement.preset == .centered)
    }

    @Test func itHasNoTimeout() async throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        harness.controller.open()
        let session = try #require(harness.controller.session)
        await send("first question", in: session)
        session.clock = { Date().addingTimeInterval(9 * 60 * 60) }
        harness.controller.panel?.summon()
        #expect(userTexts(session) == ["first question"])
        await send("second question", in: session)
        #expect(incognitoProvider.requests.last?.entries.map(\.item).filter { if case .userMessage = $0 { true } else { false } }
                == [.userMessage(text: "first question"), .userMessage(text: "second question")])
    }

    @Test func slashNewClearsAndKeepsTheWindowOpen() async throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        harness.controller.open()
        let session = try #require(harness.controller.session)
        await send("first question", in: session)
        await send("/new", in: session)
        #expect(harness.controller.isOpen)
        #expect(userTexts(session).isEmpty)
        #expect(session.transcript.rows.allSatisfy { $0.isEpisodeStart })
        await send("second question", in: session)
        #expect(incognitoProvider.requests.last?.entries.map(\.item) == [.userMessage(text: "second question")])
    }

    @Test func escapeNeverClosesIt() async throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        harness.controller.open()
        let panel = try #require(harness.controller.panel)
        let session = try #require(harness.controller.session)
        await send("open maps", in: session)
        // A suggestion first, then the inspector, then nothing.
        session.draft = "xcode"
        #expect(session.instantActions.suggestion != nil)
        panel.escape()
        #expect(session.instantActions.suggestion == nil)
        panel.inspector.open("some call")
        panel.escape()
        #expect(!panel.inspector.isOpen)
        panel.escape()
        panel.escape()
        #expect(panel.isPresented)
        #expect(harness.controller.isOpen)
        #expect(recorder.orderedAway == 0)
        #expect(userTexts(session) == ["open maps"])
    }

    @Test func anInstantLaunchKeepsTheWindowUp() async throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        harness.controller.open()
        let panel = try #require(harness.controller.panel)
        let session = try #require(harness.controller.session)
        session.draft = "open xcode"
        session.submit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(harness.opened() == ["Xcode"])
        #expect(panel.isPresented)
        #expect(incognitoProvider.requests.isEmpty)
        #expect(session.transcript.rows.allSatisfy { $0.isEpisodeStart })
    }

    @Test func closingWithNoTaskIsImmediate() throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        harness.controller.open()
        harness.controller.panel?.performClose(nil)
        #expect(!harness.controller.isOpen)
        #expect(harness.controller.session == nil)
        #expect(recorder.orderedAway == 1)
        // Opening again starts over.
        harness.controller.open()
        #expect(harness.controller.session?.transcript.rows.allSatisfy { $0.isEpisodeStart } == true)
    }

    @Test func closingWhileATaskRunsAsksFirst() async throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        incognitoProvider.holds = true
        harness.controller.open()
        let panel = try #require(harness.controller.panel)
        let session = try #require(harness.controller.session)
        session.draft = "a slow question"
        session.submit()
        #expect(session.isRunning)

        panel.performClose(nil)
        #expect(session.pendingDiscard == .close)
        #expect(harness.controller.isOpen)
        // Escape, like Keep Open, answers no.
        panel.escape()
        #expect(session.pendingDiscard == nil)
        #expect(harness.controller.isOpen)
        #expect(session.isRunning)

        harness.controller.requestClose()
        #expect(session.pendingDiscard == .close)
        session.confirmDiscard()
        #expect(!harness.controller.isOpen)
        #expect(!session.isRunning)
        #expect(session.transcript.rows.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        // The stopped task wrote nothing back into the discarded conversation.
        #expect(session.transcript.rows.isEmpty)
    }

    @Test func clearingWhileATaskRunsAsksThenStartsOver() async throws {
        defer { cleanUp() }
        let harness = try makeHarness()
        incognitoProvider.holds = true
        harness.controller.open()
        let session = try #require(harness.controller.session)
        session.draft = "a slow question"
        session.submit()
        session.requestDiscard(.clear)
        #expect(session.pendingDiscard == .clear)
        session.confirmDiscard()
        #expect(harness.controller.isOpen)
        #expect(!session.isRunning)
        #expect(session.transcript.rows.allSatisfy { $0.isEpisodeStart })
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.transcript.rows.allSatisfy { $0.isEpisodeStart }, "the old task's Stopped line never lands on the new page")

        incognitoProvider.holds = false
        await send("a new question", in: session)
        #expect(incognitoProvider.requests.last?.entries.map(\.item) == [.userMessage(text: "a new question")])
    }
}
