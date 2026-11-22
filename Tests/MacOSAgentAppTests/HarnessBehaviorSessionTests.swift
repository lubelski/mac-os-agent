import AppKit
import Foundation
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// A model that holds each reply until released, or fails, and records the owner's message
/// each request ends with.
final class GateProvider: ModelProvider, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "The stand-in model failed." }
    }

    private let lock = NSLock()
    private var isOpen: Bool
    private var failing = false
    private var recorded: [String] = []

    init(open: Bool = false) {
        isOpen = open
    }

    var messages: [String] { lock.withLock { recorded } }
    func open() { lock.withLock { isOpen = true } }
    func fail() { lock.withLock { failing = true; isOpen = true } }

    func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
        let text = request.entries.reversed().lazy.compactMap { entry -> String? in
            if case .userMessage(let text, _, _) = entry.item { text } else { nil }
        }.first ?? ""
        lock.withLock { recorded.append(text) }
        return AsyncThrowingStream { continuation in
            let task = Task {
                while !Task.isCancelled, !self.lock.withLock({ self.isOpen }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                if Task.isCancelled {
                    continuation.finish(throwing: CancellationError())
                    return
                }
                if self.lock.withLock({ self.failing }) {
                    continuation.finish(throwing: Failure())
                    return
                }
                continuation.yield(.item(.assistantMessage(.init(text: "ok", provider: "test", model: "test-model"))))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Preferences of a test's own, so nothing reads or writes the owner's or the previews'.
@MainActor
final class StandInPreferences {
    let name = "mac-os-agent-behavior-tests-\(UUID().uuidString)"
    let defaults: UserDefaults

    init(recall: Bool? = nil, controlC: Bool? = nil, queue: Bool? = nil) {
        defaults = UserDefaults(suiteName: name)!
        if let recall { HarnessBehavior.recallEarlierMessages.set(recall, defaults) }
        if let controlC { HarnessBehavior.controlCStopsOrClears.set(controlC, defaults) }
        if let queue { Experiment.queueMessagesWhileRunning.set(queue, defaults) }
    }

    func forget() {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

private let up = ("\u{F700}", UInt16(126))
private let down = ("\u{F701}", UInt16(125))
private let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

private func controlC(window: NSWindow) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .control, timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber, context: nil, characters: "\u{3}", charactersIgnoringModifiers: "c",
        isARepeat: false, keyCode: 8)!
}

@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// The owner's messages as stand-in thread entries, oldest first, each with a reply.
private func entries(_ messages: [String]) -> [ThreadEntry] {
    var date = Date().addingTimeInterval(-600)
    return messages.flatMap { message -> [ThreadEntry] in
        date = date.addingTimeInterval(10)
        return [
            ThreadEntry(date: date, item: .userMessage(text: message)),
            ThreadEntry(date: date.addingTimeInterval(1), item: .assistantMessage(.init(text: "ok", provider: "test", model: "test-model"))),
        ]
    }
}

/// Up Arrow recalling earlier messages, driven with key presses in the real panel, which is
/// never put on screen.
@MainActor
@Suite(.serialized) struct MessageRecallInputTests {
    init() { _ = NSApplication.shared }

    private func harness(_ messages: [String] = ["first", "second", "second", "third"], recall: Bool? = nil, draft: String = "") throws -> (PanelHarness, StandInPreferences) {
        let preferences = StandInPreferences(recall: recall)
        let session = AgentSession(previewEntries: entries(messages))
        session.preferences = preferences.defaults
        return (try PanelHarness(session: session, draft: draft), preferences)
    }

    @Test func upGoesBackThroughEarlierMessagesAndDownRestoresTheDraft() async throws {
        let (harness, preferences) = try harness(draft: "half typed")
        defer { preferences.forget() }
        await harness.settle()
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.draft == "third")
        #expect(harness.editor.string == "third")
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.draft == "second", "the repeated message counts once")
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.draft == "first")
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.draft == "first", "nothing older")
        harness.press(down.0, code: down.1, arrowFlags)
        #expect(harness.session.draft == "second")
        harness.press(down.0, code: down.1, arrowFlags)
        #expect(harness.session.draft == "third")
        harness.press(down.0, code: down.1, arrowFlags)
        #expect(harness.session.draft == "half typed")
        #expect(harness.editor.string == "half typed")
    }

    @Test func upInTheMiddleOfAMultiLineDraftMovesTheInsertionPoint() async throws {
        let (harness, preferences) = try harness(draft: "line one\nline two")
        defer { preferences.forget() }
        await harness.settle()
        harness.editor.setSelectedRange(NSRange(location: 15, length: 0))
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.draft == "line one\nline two", "the second line's Up moves up a line")
        #expect(harness.editor.selectedRange().location < 9)
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.draft == "third", "the first line's Up recalls")
    }

    @Test func downOnTheFirstLineOfAMultiLineMessageMovesTheInsertionPoint() async throws {
        let (harness, preferences) = try harness(["older", "one\ntwo"])
        defer { preferences.forget() }
        await harness.settle()
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.draft == "one\ntwo")
        #expect(harness.editor.selectedRange().location == 0, "after Up the insertion point is at the start")
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.draft == "older", "so Up again goes further back")
        harness.press(down.0, code: down.1, arrowFlags)
        #expect(harness.session.draft == "one\ntwo")
        #expect(harness.editor.selectedRange().location == 7, "after Down it is at the end")
        harness.editor.setSelectedRange(NSRange(location: 1, length: 0))
        harness.press(down.0, code: down.1, arrowFlags)
        #expect(harness.session.draft == "one\ntwo", "Down on the first line moves down a line")
        harness.press(down.0, code: down.1, arrowFlags)
        #expect(harness.session.draft == "", "Down on the last line comes forward to the empty draft")
    }

    @Test func theCommandListKeepsTheArrows() async throws {
        let (harness, preferences) = try harness()
        defer { preferences.forget() }
        harness.type("/")
        await harness.settle()
        #expect(harness.session.commandSuggestions.count > 1)
        harness.press(down.0, code: down.1, arrowFlags)
        #expect(harness.session.hintSelection == 1)
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(harness.session.hintSelection == 0)
        #expect(harness.session.draft == "/", "nothing was recalled")
    }

    @Test func theInstantRowKeepsTheArrows() async throws {
        let (harness, preferences) = try harness()
        defer { preferences.forget() }
        harness.session.instantActions = InstantActions(applications: InstantActionPreview.applications)
        harness.type("cal")
        await harness.settle()
        let actions = harness.session.instantActions
        #expect(actions.suggestion?.choices.count == 2)
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(actions.selection == 1)
        #expect(harness.session.draft == "cal", "nothing was recalled")
    }

    @Test func withTheSwitchOffUpMovesTheInsertionPointAsBefore() async throws {
        let (harness, preferences) = try harness(recall: false)
        defer { preferences.forget() }
        harness.type("abc")
        harness.press(up.0, code: up.1, arrowFlags)
        harness.type("x")
        await harness.settle()
        #expect(harness.session.draft == "xabc")
    }
}

/// Recall over the kept thread and in the incognito window, and sending an edited message.
@MainActor
@Suite(.serialized) struct MessageRecallSessionTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-recall-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    @Test func anEditedRecalledMessageGoesOutAsANewMessage() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = StandInPreferences()
        defer { preferences.forget() }
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        for entry in entries(["earlier episode", "rename the photos"]) {
            try await thread.append(entry.item, date: entry.date)
        }
        let provider = GateProvider(open: true)
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: thread, tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.preferences = preferences.defaults
        await session.start()
        #expect(session.recallHistory == ["rename the photos", "earlier episode"])
        #expect(session.recallMessage(by: -1))
        session.draft += " by date"
        session.submit()
        await session.waitUntilIdle()
        #expect(provider.messages == ["rename the photos by date"])
        #expect(session.recallHistory == ["rename the photos by date", "rename the photos", "earlier episode"])
        #expect(session.draft == "")
        #expect(session.recallMessage(by: -1))
        #expect(session.draft == "rename the photos by date", "recall starts over from the newest after a send")
    }

    @Test func theIncognitoWindowRecallsOnlyItsOwnMessages() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let preferences = StandInPreferences()
        defer { preferences.forget() }
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"))
        for entry in entries(["kept secret"]) {
            try await thread.append(entry.item, date: entry.date)
        }
        let main = AgentSession(
            loop: AgentLoop(provider: GateProvider(open: true), thread: thread, tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        main.preferences = preferences.defaults
        await main.start()
        let incognito = AgentSession(
            incognito: { AgentLoop(provider: GateProvider(open: true), thread: InMemoryThreadStore(), tools: []) },
            signedIn: true)
        incognito.preferences = preferences.defaults
        #expect(!incognito.recallMessage(by: -1), "nothing to recall yet")
        incognito.draft = "open maps"
        incognito.submitToAgent()
        await incognito.waitUntilIdle()
        #expect(incognito.recallHistory == ["open maps"])
        #expect(main.recallHistory == ["kept secret"])
        #expect(incognito.recallMessage(by: -1))
        #expect(incognito.draft == "open maps")
        #expect(!incognito.recallMessage(by: -1), "and nothing from the main thread")
    }
}

/// Control-C in the real panel.
@MainActor
@Suite(.serialized) struct ControlCTests {
    init() { _ = NSApplication.shared }

    private func harness(on: Bool, provider: GateProvider) throws -> (PanelHarness, StandInPreferences) {
        let preferences = StandInPreferences(controlC: on)
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.preferences = preferences.defaults
        return (try PanelHarness(session: session), preferences)
    }

    @Test func itStopsARunningTask() async throws {
        let (harness, preferences) = try harness(on: true, provider: GateProvider())
        defer { preferences.forget() }
        harness.session.draft = "go"
        harness.session.submit()
        #expect(harness.session.isRunning)
        await harness.settle()
        harness.panel.sendEvent(controlC(window: harness.panel))
        let settled = await eventually { !harness.session.isRunning }
        #expect(settled)
        #expect(harness.session.transcript.rows.last?.kind == .notice("Stopped."))
    }

    @Test func withNoTaskItClearsTheDraft() async throws {
        let (harness, preferences) = try harness(on: true, provider: GateProvider())
        defer { preferences.forget() }
        harness.type("never mind")
        await harness.settle()
        harness.panel.sendEvent(controlC(window: harness.panel))
        await harness.settle()
        #expect(harness.session.draft == "")
        #expect(harness.editor.string == "")
    }

    @Test func withAnEmptyDraftAndNoTaskItDoesNothing() async throws {
        let (harness, preferences) = try harness(on: true, provider: GateProvider())
        defer { preferences.forget() }
        let rows = harness.session.transcript.rows
        #expect(!harness.session.interrupt())
        harness.panel.sendEvent(controlC(window: harness.panel))
        await harness.settle()
        #expect(harness.session.draft == "")
        #expect(harness.session.transcript.rows == rows)
        #expect(!harness.session.isRunning)
    }

    @Test func withTheSwitchOffItNeitherClearsNorStops() async throws {
        let provider = GateProvider()
        let (harness, preferences) = try harness(on: false, provider: provider)
        defer { preferences.forget() }
        harness.type("keep this")
        await harness.settle()
        harness.panel.sendEvent(controlC(window: harness.panel))
        await harness.settle()
        #expect(harness.session.draft == "keep this")
        harness.session.submit()
        #expect(harness.session.isRunning)
        harness.panel.sendEvent(controlC(window: harness.panel))
        await harness.settle()
        #expect(harness.session.isRunning, "the task keeps running")
        harness.session.stop()
        await harness.session.waitUntilIdle()
    }

    @Test func commandCIsNotControlC() {
        let commandC = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
        #expect(!InputTextView.isControlC(commandC))
        #expect(InputTextView.isControlC(controlC(window: NSWindow())))
    }
}

/// The message queue experiment, on the session and with keys in the real panel.
@MainActor
@Suite(.serialized) struct MessageQueueSessionTests {
    init() { _ = NSApplication.shared }

    private func session(provider: GateProvider, queue: Bool = true) -> (AgentSession, StandInPreferences) {
        let preferences = StandInPreferences(queue: queue)
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.preferences = preferences.defaults
        return (session, preferences)
    }

    private func send(_ text: String, in session: AgentSession) {
        session.draft = text
        session.submit()
    }

    @Test func queuedMessagesGoOutInOrderEachAsItsOwnTurn() async throws {
        let provider = GateProvider()
        let (session, preferences) = session(provider: provider)
        defer { preferences.forget() }
        send("one", in: session)
        #expect(session.isRunning)
        send("two", in: session)
        send("three", in: session)
        #expect(session.queue.items.map(\.text) == ["two", "three"])
        #expect(session.draft == "")
        let asked = await eventually { provider.messages == ["one"] }
        #expect(asked)
        provider.open()
        let settled = await eventually { provider.messages.count == 3 && !session.isRunning }
        #expect(settled)
        #expect(provider.messages == ["one", "two", "three"])
        #expect(session.queue.isEmpty)
        let users = session.transcript.rows.compactMap { row -> String? in
            if case .user(let text, _, _) = row.kind { text } else { nil }
        }
        #expect(users == ["one", "two", "three"], "each is an ordinary message")
    }

    @Test func stoppingPausesTheQueueAndSendResumesIt() async throws {
        let provider = GateProvider()
        let (session, preferences) = session(provider: provider)
        defer { preferences.forget() }
        send("one", in: session)
        send("two", in: session)
        let asked = await eventually { provider.messages == ["one"] }
        #expect(asked)
        session.stop()
        await session.waitUntilIdle()
        let settled = await eventually { !session.isRunning }
        #expect(settled)
        #expect(session.queue.pauseReason == .stopped)
        #expect(session.queue.items.map(\.text) == ["two"])
        #expect(provider.messages == ["one"], "nothing was sent after the stop")
        provider.open()
        session.resumeQueue()
        await session.waitUntilIdle()
        #expect(provider.messages == ["one", "two"])
        #expect(session.queue.isEmpty)
        #expect(session.queue.pauseReason == nil)
    }

    @Test func anErrorPausesTheQueue() async throws {
        let provider = GateProvider()
        let (session, preferences) = session(provider: provider)
        defer { preferences.forget() }
        send("one", in: session)
        send("two", in: session)
        provider.fail()
        await session.waitUntilIdle()
        let settled = await eventually { !session.isRunning }
        #expect(settled)
        #expect(session.queue.pauseReason == .failed)
        #expect(session.queue.items.map(\.text) == ["two"])
        session.clearQueue()
        #expect(session.queue.isEmpty)
    }

    @Test func aQueuedMessageCanBeRemovedOrTakenBackToEdit() async throws {
        let provider = GateProvider()
        let (session, preferences) = session(provider: provider)
        defer { preferences.forget() }
        send("one", in: session)
        send("two", in: session)
        send("three", in: session)
        send("four", in: session)
        session.removeQueued(session.queue.items[0].id)
        #expect(session.queue.items.map(\.text) == ["three", "four"])
        session.editQueued(session.queue.items[0].id)
        #expect(session.draft == "three")
        session.editQueued(session.queue.items[0].id)
        #expect(session.draft == "three", "Edit waits for an empty field, so nothing typed is lost")
        #expect(session.queue.items.map(\.text) == ["four"])
        session.stop()
        await session.waitUntilIdle()
    }

    @Test func upOnAnEmptyFieldTakesBackTheNewestQueuedMessageBeforeHistory() async throws {
        let provider = GateProvider()
        let (session, preferences) = session(provider: provider)
        defer { preferences.forget() }
        let harness = try PanelHarness(session: session)
        send("one", in: session)
        send("two", in: session)
        send("three", in: session)
        await harness.settle()
        #expect(harness.editor.isEditable, "the field stays open while the task runs")
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(session.draft == "three")
        #expect(session.queue.items.map(\.text) == ["two"])
        harness.press(up.0, code: up.1, arrowFlags)
        #expect(session.draft == "one", "with text in the field, Up recalls history as before")
        #expect(session.queue.items.map(\.text) == ["two"])
        session.stop()
        await session.waitUntilIdle()
    }

    @Test func theAppsOwnCommandsAndInstantActionsAreNotQueued() async throws {
        let provider = GateProvider()
        let (session, preferences) = session(provider: provider)
        defer { preferences.forget() }
        var opened: [String] = []
        session.instantActions = InstantActions(applications: InstantActionPreview.applications, open: { opened.append($0.name) })
        send("one", in: session)
        send("/new", in: session)
        #expect(session.queue.isEmpty)
        #expect(session.draft == "/new", "it waits in the field")
        send("open safari", in: session)
        #expect(session.queue.isEmpty)
        #expect(session.draft == "open safari")
        #expect(opened.isEmpty)
        session.submitToAgent()
        #expect(session.queue.items.map(\.text) == ["open safari"], "Command-Return queues it as a message")
        session.stop()
        await session.waitUntilIdle()
    }

    @Test func withTheSwitchOffReturnDoesNothingWhileATaskRuns() async throws {
        let provider = GateProvider()
        let (session, preferences) = session(provider: provider, queue: false)
        defer { preferences.forget() }
        let harness = try PanelHarness(session: session)
        send("one", in: session)
        await harness.settle()
        #expect(!harness.editor.isEditable, "the field is closed while the task runs, as before")
        send("two", in: session)
        #expect(session.queue.isEmpty)
        #expect(session.draft == "two")
        provider.open()
        await session.waitUntilIdle()
        #expect(provider.messages == ["one"])
    }

    @Test func theIncognitoWindowHasAQueueOfItsOwn() async throws {
        let provider = GateProvider()
        let (main, preferences) = session(provider: provider)
        defer { preferences.forget() }
        let incognitoProvider = GateProvider()
        let incognito = AgentSession(
            incognito: { AgentLoop(provider: incognitoProvider, thread: InMemoryThreadStore(), tools: []) }, signedIn: true)
        incognito.preferences = preferences.defaults
        send("main one", in: main)
        send("main two", in: main)
        send("incognito one", in: incognito)
        send("incognito two", in: incognito)
        #expect(main.queue.items.map(\.text) == ["main two"])
        #expect(incognito.queue.items.map(\.text) == ["incognito two"])
        incognito.requestDiscard(.clear)
        incognito.confirmDiscard()
        #expect(incognito.queue.isEmpty, "clearing the conversation drops its queue")
        #expect(main.queue.items.map(\.text) == ["main two"])
        main.stop()
        await main.waitUntilIdle()
    }
}

/// Renders the queued messages above the text field offscreen, running and paused, for a pull
/// request when screen capture is not available. Run with MAC_OS_AGENT_RENDER_QUEUE set to a
/// folder. The glass is drawn as its fallback fill.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_QUEUE"] != nil))
struct MessageQueueRenders {
    @Test func rendersTheQueue() async throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_QUEUE"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preferences = StandInPreferences(queue: true)
        defer { preferences.forget() }
        let provider = GateProvider()
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.preferences = preferences.defaults
        for text in ["clean up my downloads folder", "then empty the trash", "and tell me how much space that freed"] {
            session.draft = text
            session.submit()
        }
        for state in ["running", "paused"] {
            if state == "paused" {
                let asked = await eventually { !provider.messages.isEmpty }
                #expect(asked)
                session.stop()
                await session.waitUntilIdle()
            }
            for scheme in [ColorScheme.dark, .light] {
                let theme = try #require(BuiltInThemes.all.first { $0.id == "glass" }?.theme)
                let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
                let view = VStack(spacing: 0) {
                    MessageQueueRows(session: session)
                    PanelDivider()
                    HStack {
                        Text(verbatim: Mark.prompt).font(.system(size: 17, design: .monospaced)).foregroundStyle(.secondary)
                        Text("Tell your Mac what to do").font(.system(size: 15)).foregroundStyle(.tertiary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
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
                try data.write(to: folder.appending(path: "queue-\(state)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
