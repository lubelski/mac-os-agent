import AppKit
import MacOSAgentCore
import ObjectiveC
import SwiftUI
import Testing
@testable import mac_os_agent

/// Command-W, sent as a real key press through the real main menu, with each of the app's
/// windows as the key window: the main panel hides, the incognito window closes or asks, the
/// inspector closes, and Settings closes.
///
/// No window here goes on screen, so none can really become key, and making one key would take
/// keyboard focus from the owner. `StandInKeyWindow` makes `NSApp.keyWindow` answer the test's
/// window instead, which is where AppKit looks for the target of a menu item with none. The
/// press then takes the app's own route: the key window's `performKeyEquivalent(with:)`, and,
/// when nothing in the window takes it, the main menu's, which validates the item before it
/// sends the action.
@MainActor
@Suite(.serialized) struct CommandWTests {
    init() { _ = NSApplication.shared }

    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-command-w-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let suiteName = "mac-os-agent-command-w-tests-\(UUID().uuidString)"
    private let standIn = StandInScreens()

    private func cleanUp() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    private static func commandW() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    }

    /// Presses Command-W with `window` as the key window, the way the app hands a Command key
    /// press on: to the key window first, then to the main menu. Returns whether something took
    /// it, and whether the Close item was enabled when the menu was asked.
    @discardableResult
    private static func pressCommandW(in window: NSWindow) throws -> (handled: Bool, closeEnabled: Bool) {
        let previous = NSApp.mainMenu
        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previous }
        let close = try #require(TextInputTests.item(in: menu, key: "w", modifiers: .command))
        let event = try commandW()
        return StandInKeyWindow.with(window) {
            if window.performKeyEquivalent(with: event) { return (true, close.isEnabled) }
            let handled = menu.performKeyEquivalent(with: event)
            return (handled, close.isEnabled)
        }
    }

    private func makeMainPanel(session: AgentSession, preview: Bool = false) throws -> (SummonPanel, WindowRecorder) {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let standIn = standIn
        let recorder = WindowRecorder()
        let panel = SummonPanel(
            session: session, remembersFrame: false, placementDefaults: defaults,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        panel.orderIn = { _, makeKey in recorder.orderedIn.append(makeKey) }
        panel.orderAway = { _ in recorder.orderedAway += 1 }
        panel.drivesSlidesWithTheDisplay = false
        panel.contentView?.layoutSubtreeIfNeeded()
        PanelHarness.turnTheRunLoop()
        return (panel, recorder)
    }

    private func makeMainSession(provider: EchoProvider) throws -> AgentSession {
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        let loop = AgentLoop(provider: provider, thread: thread, tools: [], episodeTimeout: { 1800 })
        return AgentSession(loop: loop, authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
    }

    private func editor(in window: NSWindow) throws -> InputTextView {
        try #require(PanelHarness.first(InputTextView.self, in: window.contentView!) { _ in true })
    }

    // MARK: - The main panel

    @Test func commandWHidesTheMainPanelAndKeepsItsTaskGoing() async throws {
        defer { cleanUp() }
        let provider = EchoProvider()
        provider.holds = true
        let session = try makeMainSession(provider: provider)
        let (panel, recorder) = try makeMainPanel(session: session)
        panel.summon()
        #expect(panel.isPresented)
        session.draft = "tidy the desktop"
        session.submit()
        #expect(session.isRunning)

        let press = try Self.pressCommandW(in: panel)
        #expect(press.closeEnabled, "Close in the Window menu is enabled while the panel is key")
        #expect(press.handled)
        #expect(!panel.isPresented, "the panel hides")
        #expect(recorder.orderedAway == 1)
        #expect(session.isRunning, "hiding never stops the task")

        session.stop()
        await session.waitUntilIdle()
    }

    /// The field keeps its draft and its focus: Command-W types nothing into it, and the field
    /// has focus again when the panel comes back.
    @Test func commandWLeavesTheFieldAsItWas() throws {
        defer { cleanUp() }
        let session = try makeMainSession(provider: EchoProvider())
        session.draft = "half a thought"
        let (panel, _) = try makeMainPanel(session: session)
        panel.summon()
        let field = try editor(in: panel)
        if panel.firstResponder !== field { panel.makeFirstResponder(field) }

        try Self.pressCommandW(in: panel)
        #expect(!panel.isPresented)
        #expect(session.draft == "half a thought")
        #expect(field.string == "half a thought")
        #expect(panel.firstResponder === field, "the field keeps focus while the panel is hidden")

        panel.summon()
        PanelHarness.turnTheRunLoop()
        #expect(panel.isPresented)
        #expect(panel.firstResponder === field)
    }

    /// With the experiment on and the list under the field open, Command-W still hides the
    /// panel, and the list closes as it does whenever the panel hides.
    @Test func commandWWithTheSuggestionListOpenHidesThePanel() async throws {
        defer { cleanUp() }
        let session = AgentSession(previewEntries: FooterPreview.thread())
        FooterPreview.configure(session)
        session.suggestionList.forcedOn = true
        session.preferences = try #require(UserDefaults(suiteName: suiteName))
        session.instantActions.openApplication = { _ in }
        let (panel, recorder) = try makeMainPanel(session: session)
        panel.summon()
        let field = try editor(in: panel)
        if panel.firstResponder !== field { panel.makeFirstResponder(field) }
        field.insertText("chr", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<3 {
            PanelHarness.turnTheRunLoop()
            try? await Task.sleep(for: .milliseconds(10))
        }
        panel.sendEvent(TextInputTests.key("\u{F701}", code: 125, [.function, .numericPad], window: panel))
        #expect(session.suggestionList.isOpen)

        let press = try Self.pressCommandW(in: panel)
        #expect(press.closeEnabled)
        #expect(!panel.isPresented)
        #expect(recorder.orderedAway == 1)
        #expect(!session.suggestionList.isOpen)
        #expect(session.draft == "chr", "hiding leaves the text alone")
    }

    // MARK: - The incognito window

    private func makeIncognito(provider: EchoProvider) -> IncognitoWindowController {
        let standIn = standIn
        return IncognitoWindowController(
            makeSession: {
                AgentSession(
                    incognito: {
                        AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { .infinity })
                    },
                    signedIn: true)
            },
            makePanel: { session in
                let panel = SummonPanel(
                    session: session, role: .incognito, remembersFrame: false,
                    screens: { standIn.screens }, mouseLocation: { standIn.mouse })
                panel.orderIn = { _, _ in }
                panel.orderAway = { _ in }
                panel.drivesSlidesWithTheDisplay = false
                return panel
            })
    }

    @Test func commandWClosesTheIncognitoWindowWithNoTask() throws {
        let controller = makeIncognito(provider: EchoProvider())
        controller.open()
        let panel = try #require(controller.panel)

        let press = try Self.pressCommandW(in: panel)
        #expect(press.closeEnabled)
        #expect(press.handled)
        #expect(!controller.isOpen, "the window closes and its conversation is discarded")
        #expect(!panel.isPresented)
    }

    @Test func commandWAsksBeforeDiscardingARunningTask() async throws {
        let provider = EchoProvider()
        provider.holds = true
        let controller = makeIncognito(provider: provider)
        controller.open()
        let panel = try #require(controller.panel)
        let session = try #require(controller.session)
        session.draft = "a secret"
        session.submit()
        #expect(session.isRunning)

        let press = try Self.pressCommandW(in: panel)
        #expect(press.closeEnabled)
        #expect(session.pendingDiscard == .close, "it asks, as Close and Discard in its menu does")
        #expect(controller.isOpen)
        #expect(session.isRunning)

        session.confirmDiscard()
        #expect(!controller.isOpen)
        session.stop()
        await session.waitUntilIdle()
    }

    // MARK: - The inspector

    @Test func commandWClosesTheInspectorAndLeavesThePanelUp() throws {
        defer { cleanUp() }
        let session = try #require(PanelPreview.session(named: "inspector-json"))
        let (panel, recorder) = try makeMainPanel(session: session)
        panel.summon()
        let callID = try #require(session.transcript.rows.first { if case .tool = $0.kind { true } else { false } }?.id)
        panel.inspector.open(callID)
        #expect(panel.inspector.isOpen)

        let press = try Self.pressCommandW(in: panel.inspectorWindow)
        #expect(press.closeEnabled, "Close in the Window menu is enabled while the inspector is key")
        #expect(press.handled)
        #expect(!panel.inspector.isOpen, "the inspector closes")
        #expect(panel.isPresented, "the panel stays up")
        #expect(recorder.orderedAway == 0)
    }

    // MARK: - Settings

    @Test func commandWStillClosesSettings() throws {
        let harness = try SettingsWindowHarness(section: .general)
        defer { harness.tearDown() }
        harness.layOut()
        let window = harness.window
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in
            closed = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let press = try Self.pressCommandW(in: window)
        #expect(press.closeEnabled)
        #expect(press.handled)
        #expect(closed, "Settings closes")
    }

    // MARK: - The other window items

    /// The Window menu has only Close: no Minimize, Zoom, or Bring All to Front, which a
    /// borderless panel would turn down. The app has no File menu.
    @Test func theWindowMenuHasOnlyClose() {
        let menu = MainMenu.make()
        #expect(menu.items.map(\.title) == ["mac-os-agent", "Edit", "Task", "Window"])
        #expect(MainMenu.windowMenu().items.map(\.title) == ["Close"])
    }
}

/// Makes `NSApp.keyWindow` answer a window of the test's while `body` runs, so a menu item with
/// no target finds it as it would find the real key window. `body` must not suspend: the
/// stand-in is process-wide while it is in place.
@MainActor
enum StandInKeyWindow {
    static func with<T>(_ window: NSWindow, _ body: () throws -> T) rethrows -> T {
        let selector = #selector(getter: NSApplication.keyWindow)
        let method = class_getInstanceMethod(NSApplication.self, selector)!
        let original = method_getImplementation(method)
        let standIn: @convention(block) (NSApplication) -> NSWindow? = { _ in window }
        method_setImplementation(method, imp_implementationWithBlock(standIn))
        defer { method_setImplementation(method, original) }
        return try body()
    }
}
