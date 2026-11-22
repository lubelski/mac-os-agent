import AppKit
import Foundation
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// The instant action row in the real panel, driven with key presses as in `TextInputTests`.
/// The panel is never put on screen, and no app is opened: the opener is a stand-in.
@MainActor
@Suite(.serialized) struct InstantActionInputTests {
    init() { _ = NSApplication.shared }

    final class Recorder {
        var opened: [String] = []
        var hides = 0
    }

    /// The panel with the stand-in apps from the preview, an empty field, and nothing opened for real.
    private func makeHarness() throws -> (PanelHarness, Recorder) {
        let harness = try PanelHarness(draft: "", preview: "instant-one")
        let recorder = Recorder()
        harness.session.instantActions.openApplication = { recorder.opened.append($0.name) }
        harness.session.hidePanel = { recorder.hides += 1 }
        return (harness, recorder)
    }

    private var returnKey: (String, UInt16) { ("\r", 36) }

    @Test func returnOpensTheAppAndHidesThePanelWithoutSendingAnything() async throws {
        let (harness, recorder) = try makeHarness()
        let rowsBefore = harness.session.visibleTranscript.rows.count
        harness.type("open safari")
        await harness.settle()
        #expect(harness.session.instantActions.suggestion?.choices.map(\.title) == ["Safari"])
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Safari"])
        #expect(recorder.hides == 1)
        #expect(harness.session.draft == "")
        #expect(harness.session.instantActions.suggestion == nil)
        #expect(harness.session.visibleTranscript.rows.count == rowsBefore, "nothing is added to the conversation")
        #expect(!harness.session.isRunning)
    }

    @Test func returnRightAfterTypingUsesTheTextOnScreen() async throws {
        let (harness, recorder) = try makeHarness()
        // No settle between typing and Return, as with a fast typist.
        harness.type("xco")
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Xcode"])
    }

    @Test func commandReturnSendsToTheAgentInstead() async throws {
        let (harness, recorder) = try makeHarness()
        harness.type("open safari")
        await harness.settle()
        #expect(harness.session.instantActions.suggestion != nil)
        harness.press("\r", code: 36, [.command])
        await harness.settle()
        #expect(recorder.opened.isEmpty)
        #expect(recorder.hides == 0)
        #expect(harness.session.draft == "open safari", "the preview has no model, so the agent path leaves the text in place")
    }

    @Test func commandReturnReachesTheSendToAgentAction() async throws {
        let session = AgentSession(previewEntries: [])
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        var sends = 0, agentSends = 0
        window.contentView = NSHostingView(rootView: InputField(
            text: Bindable(session).draft, placeholder: "", isEnabled: true, focusRequest: 1,
            onSubmit: { sends += 1 }, onCancel: {}, onSubmitToAgent: { agentSends += 1 }))
        window.contentView?.layoutSubtreeIfNeeded()
        PanelHarness.turnTheRunLoop()
        let editor = try #require(PanelHarness.first(InputTextView.self, in: window.contentView!) { _ in true })
        window.makeFirstResponder(editor)
        editor.insertText("open safari", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.sendEvent(TextInputTests.key("\r", code: 36, [.command], window: window))
        #expect(agentSends == 1)
        #expect(sends == 0)
        #expect(session.draft == "open safari", "no line was added")
        #expect(InputCommand(#selector(NSResponder.insertNewline(_:)), modifiers: .command, composing: false) == .sendToAgent)
        #expect(InputCommand(#selector(NSResponder.insertNewline(_:)), modifiers: .command, composing: true) == .standard)
    }

    @Test func withNoConfidentMatchReturnGoesToTheAgent() async throws {
        let (harness, recorder) = try makeHarness()
        harness.type("what is safari")
        await harness.settle()
        #expect(harness.session.instantActions.suggestion == nil)
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened.isEmpty)
        #expect(recorder.hides == 0)
    }

    @Test func theArrowsAndTabChooseBetweenMatches() async throws {
        let (harness, recorder) = try makeHarness()
        harness.type("cal")
        await harness.settle()
        let actions = harness.session.instantActions
        #expect(actions.suggestion?.choices.map(\.title) == ["Calendar", "Calculator"])
        #expect(actions.selection == 0)
        harness.press("\u{F701}", code: 125, [.function, .numericPad]) // Down
        #expect(actions.selection == 1)
        harness.press("\u{F701}", code: 125, [.function, .numericPad]) // Down wraps
        #expect(actions.selection == 0)
        harness.press("\u{F700}", code: 126, [.function, .numericPad]) // Up wraps
        #expect(actions.selection == 1)
        harness.press("\t", code: 48, []) // Tab
        #expect(actions.selection == 0)
        harness.press("\u{19}", code: 48, [.shift]) // Shift-Tab
        #expect(actions.selection == 1)
        #expect(harness.session.draft == "cal", "no key added a tab or moved the text")
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Calculator"])
    }

    @Test func theArrowsMoveTheCursorWhenThereIsNothingToChoose() async throws {
        let (harness, _) = try makeHarness()
        harness.type("open safari")
        harness.press("\u{F700}", code: 126, [.function, .numericPad]) // Up goes to the start
        harness.type("x")
        await harness.settle()
        #expect(harness.session.draft == "xopen safari")
        harness.press("\t", code: 48, [])
        await harness.settle()
        #expect(harness.session.draft.contains("\t"), "Tab types a tab as before")
    }

    @Test func escapeDismissesTheSuggestionThenClosesTheInspectorThenHidesThePanel() async throws {
        let (harness, recorder) = try makeHarness()
        let panel = try #require(harness.panel as? SummonPanel)
        let callID = try #require(harness.session.visibleTranscript.toolCallIDs.first)
        panel.inspector.open(callID)
        harness.type("cal")
        await harness.settle()
        #expect(harness.session.instantActions.suggestion != nil)

        // The arrows choose between matches while there is text, and leave the inspector alone.
        harness.press("\u{F701}", code: 125, [.function, .numericPad])
        #expect(panel.inspector.selectedCallID == callID)
        #expect(harness.session.instantActions.selection == 1)

        harness.press("\u{1B}", code: 53, [])
        #expect(harness.session.instantActions.suggestion == nil)
        #expect(panel.inspector.isOpen, "the first Escape only dismissed the suggestion")
        #expect(harness.session.draft == "cal")

        harness.press("\u{1B}", code: 53, [])
        #expect(!panel.inspector.isOpen, "the second Escape closes the inspector")

        // Return after dismissing sends to the agent.
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened.isEmpty)
    }

    @Test func aDismissedSuggestionStaysAwayWhileTheOwnerKeepsTyping() async throws {
        let (harness, _) = try makeHarness()
        let actions = harness.session.instantActions
        harness.type("saf")
        #expect(actions.suggestion != nil)
        _ = actions.dismiss()
        harness.type("a")
        #expect(actions.suggestion == nil)
        harness.session.draft = ""
        harness.session.draft = "safari"
        #expect(actions.suggestion?.top.title == "Safari", "clearing the field ends the dismissal")
    }

    @Test func theSuggestionAlwaysAnswersTheCurrentText() async throws {
        let (harness, _) = try makeHarness()
        let actions = harness.session.instantActions
        for (index, character) in "open safari and mail".enumerated() {
            harness.type(String(character))
            let text = harness.session.draft
            if let suggestion = actions.suggestion {
                #expect(suggestion.input == text, "step \(index)")
            }
        }
        #expect(actions.suggestion == nil)
    }

    @Test func aSlashCommandNeverShowsTheRow() async throws {
        let (harness, _) = try makeHarness()
        harness.type("/new")
        #expect(harness.session.instantActions.suggestion == nil)
    }
}

/// Against a real loop and thread, so it is plain what reaches the model and the files.
@MainActor
@Suite(.serialized) struct InstantActionSessionTests {
    private let folder = FileManager.default.temporaryDirectory
        .appending(path: "mac-os-agent-instant-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    private final class CountingProvider: ModelProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var requests: Int { lock.withLock { count } }
        func streamReply(to request: ModelRequest) -> AsyncThrowingStream<ModelStreamEvent, Error> {
            lock.withLock { count += 1 }
            return AsyncThrowingStream { continuation in
                continuation.yield(.item(.assistantMessage(.init(text: "ok", provider: "test", model: "test-model"))))
                continuation.finish()
            }
        }
    }

    private func makeSession(provider: CountingProvider, store: InstantActionHistoryStore, opened: @escaping (String) -> Void) throws -> AgentSession {
        let thread = try ThreadStore(fileURL: folder.appending(path: "thread.jsonl"), searchIndexURL: folder.appending(path: "history-index.sqlite"))
        let loop = AgentLoop(provider: provider, thread: thread, tools: [], episodeTimeout: { 1800 })
        let session = AgentSession(
            loop: loop, authenticator: nil,
            makeIncognitoLoop: { AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { 1800 }) },
            episodeTimeout: { 1800 }, signedIn: true)
        session.instantActions = InstantActions(
            applications: InstantActionPreview.applications, store: store,
            open: { opened($0.name) })
        return session
    }

    @Test func anInstantLaunchNeverReachesTheModelOrTheThread() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let provider = CountingProvider()
        let store = InstantActionHistoryStore(fileURL: folder.appending(path: "instant-actions.json"))
        var opened: [String] = []
        let session = try makeSession(provider: provider, store: store) { opened.append($0) }

        session.draft = "hello"
        session.submit()
        await session.waitUntilIdle()
        #expect(provider.requests == 1)
        let threadAfterMessage = try Data(contentsOf: folder.appending(path: "thread.jsonl"))

        session.draft = "open safari"
        session.submit()
        await session.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(20))
        #expect(opened == ["Safari"])
        #expect(provider.requests == 1, "no model request")
        #expect(try Data(contentsOf: folder.appending(path: "thread.jsonl")) == threadAfterMessage, "nothing written to the thread")

        // Command-Return's path sends the same text to the agent.
        session.draft = "open safari"
        session.submitToAgent()
        await session.waitUntilIdle()
        #expect(provider.requests == 2)
        #expect(opened == ["Safari"])

        await store.waitForWrites()
        #expect(store.history.wasPicked("application:/Applications/Safari.app", for: "safari"))
    }

    @Test func anIncognitoEpisodeLearnsNothingAndWritesNoFile() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "instant-actions.json")
        let store = InstantActionHistoryStore(fileURL: file)
        var opened: [String] = []
        let session = try makeSession(provider: CountingProvider(), store: store) { opened.append($0) }
        session.perform(.incognito)
        #expect(session.isIncognito)
        session.draft = "xcode"
        session.submit()
        try await Task.sleep(for: .milliseconds(20))
        await store.waitForWrites()
        #expect(opened == ["Xcode"])
        #expect(store.history == InstantActionHistory())
        #expect(!FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
    }

    @Test func whatTheOwnerPicksRanksFirstNextTime() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = InstantActionHistoryStore(fileURL: folder.appending(path: "instant-actions.json"))
        var opened: [String] = []
        let session = try makeSession(provider: CountingProvider(), store: store) { opened.append($0) }
        session.draft = "cal"
        #expect(session.instantActions.suggestion?.choices.map(\.title) == ["Calendar", "Calculator"])
        _ = session.instantActions.move(by: 1)
        session.submit()
        try await Task.sleep(for: .milliseconds(20))
        #expect(opened == ["Calculator"])
        session.draft = "cal"
        #expect(session.instantActions.suggestion?.choices.map(\.title) == ["Calculator"])
    }

    @Test func aFailedLaunchBringsThePanelBackWithTheTextAndALine() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        struct Gone: LocalizedError { var errorDescription: String? { "The app is no longer there." } }
        let session = try makeSession(provider: CountingProvider(), store: InstantActionHistoryStore(fileURL: folder.appending(path: "instant-actions.json"))) { _ in }
        session.instantActions.openApplication = { _ in throw Gone() }
        var shown = 0
        session.showPanel = { shown += 1 }
        session.draft = "xcode"
        session.submit()
        try await Task.sleep(for: .milliseconds(50))
        #expect(shown == 1)
        #expect(session.draft == "xcode")
        #expect(session.problems.problems.count == 1)
    }

    /// Return to the open call, with a stand-in opener, so this is the app's own share of the time.
    @Test func timesReturnToLaunch() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var opened = ContinuousClock.now
        let session = try makeSession(provider: CountingProvider(), store: InstantActionHistoryStore(fileURL: folder.appending(path: "instant-actions.json"))) { _ in opened = .now }
        session.draft = "xcode"
        let start = ContinuousClock.now
        session.submit()
        try await Task.sleep(for: .milliseconds(250))
        let elapsed = opened - start
        print("instant-actions: Return to the open call \(elapsed)")
        #expect(elapsed < .milliseconds(200))
    }
}
