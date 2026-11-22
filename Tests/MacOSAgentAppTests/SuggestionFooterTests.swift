import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

private let up = ("\u{F700}", UInt16(126))
private let down = ("\u{F701}", UInt16(125))
private let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]

/// Polls until the condition holds, for work that finishes on a later turn of the run loop.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// What the footer says in each state, for each setting that changes it.
@MainActor
struct InputFooterContentTests {
    private func make(_ state: InputFooterContent.State, name: String = "Iris", recall: Bool = true, queue: Bool = false) -> InputFooterContent {
        .make(state, agentName: name, modelName: "GPT-6 Luna", recallsMessages: recall, queuesWhileRunning: queue)
    }

    @Test func idleSaysWhatAnEmptyFieldCanDoAndTheModel() {
        let content = make(.idle)
        #expect(content.leading.map(\.text) == ["↑ earlier messages", "/ commands"])
        #expect(content.trailing?.text == "GPT-6 Luna")
        #expect(make(.idle, recall: false).leading.map(\.text) == ["/ commands"], "only hints that are true for the settings")
    }

    @Test func typingAMessage() {
        let content = make(.typing, name: "Juno")
        #expect(content.leading.map(\.text) == ["↵ ask Juno", "⇧↵ new line"])
        #expect(content.trailing?.text == "GPT-6 Luna")
    }

    @Test func whileATaskRuns() {
        #expect(make(.running(queuedCount: 0)).leading.map(\.text) == ["⌘. stop"])
        #expect(make(.running(queuedCount: 0), queue: true).leading.map(\.text) == ["⌘. stop", "↵ queue"])
        #expect(make(.running(queuedCount: 2), queue: true).leading.map(\.text) == ["⌘. stop", "↵ queue", "↑ edit queued"])
    }

    @Test func whileASuggestionShows() {
        let app = InstantActionTarget.application(FooterPreview.applications[0])
        let content = make(.suggestion(app, others: 2), name: "Juno")
        #expect(content.leading.map(\.text) == ["↵ open", "↓ 2 more"])
        #expect(content.trailing?.text == "⌘↵ ask Juno", "the agent's name comes from the setting")
        #expect(make(.suggestion(.quickAction(id: "x"), others: 0)).leading.map(\.text) == ["↵ run"])
    }

    @Test func withTheListOpen() {
        let app = InstantActionTarget.application(FooterPreview.applications[0])
        #expect(make(.list(app)).leading.map(\.text) == ["↵ open", "↑↓ choose", "esc close"])
        #expect(make(.list(.quickAction(id: "x"))).leading.first?.text == "↵ run")
        #expect(make(.list(nil)).leading.first?.text == "↵ ask", "on the Ask row")
        #expect(make(.list(app)).trailing?.text == "⌘↵ ask Iris")
    }

    @Test func withTheSlashList() {
        #expect(make(.commands(count: 3, completes: true)).leading.map(\.text) == ["↵ complete", "↑↓ choose", "esc close"])
        #expect(make(.commands(count: 1, completes: false)).leading.map(\.text) == ["↵ run", "esc close"])
    }

    @Test func voiceOverReadsTheKeysInWords() {
        let content = make(.suggestion(.application(FooterPreview.applications[0]), others: 2))
        #expect(content.spoken == "Return, open. Down Arrow, 2 more. Command-Return, ask Iris")
    }

    @Test func theModelIsShownByItsName() {
        #expect(InputFooterContent.modelName(id: "gpt-6-luna") == "GPT-6 Luna")
        #expect(InputFooterContent.modelName(id: "some-custom-model") == "some-custom-model")
    }
}

/// The experiment in the real panel, driven with key presses as in `TextInputTests`. The panel
/// is never put on screen and no app is opened: the opener is a stand-in. Since it is never
/// shown, the window cannot grow, so the list is drawn over the conversation here. The
/// growing is tested in `SuggestionListPlacementTests`.
@MainActor
@Suite(.serialized) struct SuggestionFooterTests {
    init() { _ = NSApplication.shared }

    final class Recorder {
        var opened: [String] = []
    }

    private func harness(on: Bool = true, incognito: Bool = false, preferences: StandInPreferences? = nil) throws -> (PanelHarness, Recorder) {
        let session = AgentSession(previewEntries: FooterPreview.thread(), incognito: incognito)
        FooterPreview.configure(session)
        session.suggestionList.forcedOn = on
        if let preferences { session.preferences = preferences.defaults }
        let recorder = Recorder()
        session.instantActions.openApplication = { recorder.opened.append($0.name) }
        session.hidePanel = {}
        return (try PanelHarness(session: session), recorder)
    }

    private func press(_ harness: PanelHarness, _ key: (String, UInt16), _ flags: NSEvent.ModifierFlags = arrowFlags) {
        harness.press(key.0, code: key.1, flags)
    }

    private func completionView(_ harness: PanelHarness) -> InlineCompletionView? {
        harness.editor.subviews.compactMap { $0 as? InlineCompletionView }.first
    }

    // MARK: - Switch off

    @Test func withTheSwitchOffNothingChanges() async throws {
        let (harness, _) = try harness(on: false)
        harness.type("cal")
        await harness.settle()
        let session = harness.session
        #expect(session.instantActions.suggestion?.choices.count ?? 0 > 1, "the stand-in apps offer a few choices for cal")
        #expect(session.suggestionRows.isEmpty)
        #expect(session.returnTarget == nil)
        #expect(session.inlineCompletion == nil)
        #expect(harness.editor.inlineCompletion == nil)
        #expect(completionView(harness) == nil, "no gray text is drawn")
        // Down chooses between the matches in the row above the field, as before.
        press(harness, down)
        #expect(session.instantActions.selection == 1)
        #expect(!session.suggestionList.isOpen)
        // The slash list is today's, above the field.
        harness.session.draft = "/"
        await harness.settle()
        #expect(session.suggestionRows.isEmpty)
        #expect(!session.commandSuggestions.isEmpty)
    }

    @Test func theSwitchIsOffByDefault() {
        let preferences = StandInPreferences()
        defer { preferences.forget() }
        let session = AgentSession(previewEntries: [])
        session.preferences = preferences.defaults
        #expect(!session.suggestionsInFooter)
        Experiment.suggestionsInFieldAndFooter.set(true, preferences.defaults)
        #expect(session.suggestionsInFooter)
    }

    // MARK: - The footer's state

    @Test func theFooterFollowsTheWindow() async throws {
        let (harness, _) = try harness()
        let session = harness.session
        #expect(session.footerState == .idle)
        harness.type("light mode please")
        await harness.settle()
        #expect(session.footerState == .typing)
        session.draft = "chr"
        await harness.settle()
        guard case .suggestion(.application(let app), let others) = session.footerState else {
            Issue.record("expected a suggestion, got \(session.footerState)")
            return
        }
        #expect(app.name == "Google Chrome")
        #expect(others == (session.instantActions.suggestion?.matches.count ?? 1) - 1)
        #expect(others > 0)
        press(harness, down)
        #expect(session.footerState == .list(.application(app)))
        session.draft = "/"
        await harness.settle()
        #expect(session.footerState == .commands(count: session.commandSuggestions.count, completes: true))
    }

    // MARK: - The mark and the gray text

    @Test func theMarkAndTheGrayTextShowWhatReturnWillActOn() async throws {
        let (harness, _) = try harness()
        harness.type("chr")
        await harness.settle()
        let session = harness.session
        #expect(session.returnTarget?.title == "Google Chrome")
        #expect(session.inlineCompletion == InlineCompletion(rest: "ome", name: "Google Chrome"))
        #expect(harness.editor.inlineCompletion == session.inlineCompletion)
        #expect(harness.editor.isShowingInlineCompletion)
        let view = try #require(completionView(harness))
        #expect(view.completion == InlineCompletion(rest: "ome", name: "Google Chrome"))
        #expect(view.origin.x > 0, "after the typed text")
        // The gray text is never in the text: what is sent, copied, or recalled is "chr".
        #expect(harness.editor.string == "chr")
        #expect(session.draft == "chr")
        // A message, not a match: the mark is `›` and there is no gray text.
        session.draft = "light mode please"
        await harness.settle()
        #expect(session.returnTarget == nil)
        #expect(session.inlineCompletion == nil)
        #expect(!harness.editor.isShowingInlineCompletion)
    }

    @Test func theGrayTextShowsOnlyAtTheEndOfASingleLine() async throws {
        #expect(InputTextView.showsInlineCompletion(text: "chr", selection: NSRange(location: 3, length: 0), composing: false))
        #expect(!InputTextView.showsInlineCompletion(text: "chr", selection: NSRange(location: 1, length: 0), composing: false),
                "the insertion point in the middle of the text")
        #expect(!InputTextView.showsInlineCompletion(text: "chr", selection: NSRange(location: 0, length: 3), composing: false),
                "text selected")
        #expect(!InputTextView.showsInlineCompletion(text: "chr\nome", selection: NSRange(location: 7, length: 0), composing: false),
                "several lines")
        #expect(!InputTextView.showsInlineCompletion(text: "chr", selection: NSRange(location: 3, length: 0), composing: true),
                "an input method composing")

        let (harness, _) = try harness()
        harness.type("chr")
        await harness.settle()
        #expect(harness.editor.isShowingInlineCompletion)
        harness.editor.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!harness.editor.isShowingInlineCompletion)
        #expect(completionView(harness)?.completion == nil, "the drawing follows the insertion point")
        harness.editor.setSelectedRange(NSRange(location: 3, length: 0))
        #expect(completionView(harness)?.completion != nil)
        harness.editor.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!harness.editor.isShowingInlineCompletion)
        #expect(completionView(harness)?.completion == nil)
        harness.editor.unmarkText()
    }

    @Test func aQuickActionShowsItsSymbolAndRuns() async throws {
        let (harness, _) = try harness()
        harness.type("chrome incognito")
        await harness.settle()
        let target = try #require(harness.session.returnTarget)
        #expect(target.target == .quickAction(id: "chrome-incognito"))
        guard case .suggestion(.quickAction, _) = harness.session.footerState else {
            Issue.record("expected a quick action, got \(harness.session.footerState)")
            return
        }
    }

    // MARK: - The list

    @Test func downOpensTheListAndTheArrowsMoveThroughIt() async throws {
        let (harness, _) = try harness()
        harness.type("chr")
        await harness.settle()
        let session = harness.session
        let matches = try #require(session.instantActions.suggestion?.matches)
        #expect(matches.count > 1)
        press(harness, down)
        #expect(session.suggestionList.isOpen)
        #expect(session.highlightedRowIndex == 0, "it opens on what the field already shows")
        #expect(session.suggestionRows.count == matches.count + 1)
        #expect(session.suggestionRows.last == .ask("chr"))
        press(harness, down)
        #expect(session.highlightedRowIndex == 1)
        #expect(session.returnTarget == matches[1], "the field shows the highlighted row")
        #expect(session.inlineCompletion == InlineCompletion.forName(matches[1].title, typed: "chr"))
        // Down stops at the Ask row, which shows `›` and no gray text.
        for _ in 0..<10 { press(harness, down) }
        #expect(session.highlightedRow == .ask("chr"))
        #expect(session.returnTarget == nil)
        #expect(session.inlineCompletion == nil)
        #expect(session.footerState == .list(nil))
        // Up goes back, and Up from the first row closes the list.
        for _ in 0..<session.suggestionRows.count - 1 { press(harness, up) }
        #expect(session.highlightedRowIndex == 0)
        #expect(session.suggestionList.isOpen)
        press(harness, up)
        #expect(!session.suggestionList.isOpen)
        #expect(session.draft == "chr", "closing the list leaves the text alone")
    }

    @Test func returnOpensTheHighlightedApp() async throws {
        let (harness, recorder) = try harness()
        harness.type("chr")
        await harness.settle()
        let matches = try #require(harness.session.instantActions.suggestion?.matches)
        let canary = try #require(matches.firstIndex { $0.title == "Google Chrome Canary" })
        #expect(canary > 0)
        press(harness, down)
        for _ in 0..<canary { press(harness, down) }
        #expect(harness.session.returnTarget?.title == "Google Chrome Canary")
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Google Chrome Canary"])
        #expect(harness.session.draft == "")
        #expect(!harness.session.suggestionList.isOpen)
        #expect(harness.session.instantActions.history.wasPicked(matches[canary].id, for: "chr"), "the choice is learned")
    }

    @Test func returnOnAQuickActionRowTakesIt() async throws {
        let (harness, recorder) = try harness()
        harness.type("chr")
        await harness.settle()
        let matches = try #require(harness.session.instantActions.suggestion?.matches)
        let action = try #require(matches.firstIndex { $0.target == .quickAction(id: "chrome-incognito") })
        press(harness, down)
        for _ in 0..<action { press(harness, down) }
        #expect(harness.session.footerState == .list(.quickAction(id: "chrome-incognito")))
        harness.press("\r", code: 36, [])
        await harness.settle()
        // The preview has no loop to run it with, so only what Return took is checked.
        #expect(recorder.opened.isEmpty)
        #expect(harness.session.instantActions.history.wasPicked(matches[action].id, for: "chr"))
        #expect(!harness.session.suggestionList.isOpen)
    }

    @Test func returnWithTheListClosedTakesTheFirstMatch() async throws {
        let (harness, recorder) = try harness()
        harness.type("chr")
        await harness.settle()
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Google Chrome"])
    }

    @Test func returnOnTheAskRowAndCommandReturnSendToTheAgent() async throws {
        let provider = GateProvider(open: true)
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        FooterPreview.configure(session)
        var opened: [String] = []
        session.instantActions.openApplication = { opened.append($0.name) }
        let harness = try PanelHarness(session: session)
        harness.type("chr")
        await harness.settle()
        press(harness, down)
        for _ in 0..<10 { press(harness, down) }
        #expect(session.highlightedRow == .ask("chr"))
        harness.press("\r", code: 36, [])
        #expect(await eventually { provider.messages == ["chr"] })
        await session.waitUntilIdle()
        #expect(!session.suggestionList.isOpen)
        await harness.settle()
        #expect(harness.editor.string == "", "the field cleared after sending")

        harness.type("chr")
        await harness.settle()
        press(harness, down)
        harness.press("\r", code: 36, [.command])
        #expect(await eventually { provider.messages == ["chr", "chr"] }, "Command-Return always sends to the agent")
        await session.waitUntilIdle()
        #expect(opened.isEmpty)
    }

    @Test func escapeClosesTheListThenGoesOnAsBefore() async throws {
        let (harness, _) = try harness()
        let panel = try #require(harness.panel as? SummonPanel)
        harness.type("chr")
        await harness.settle()
        press(harness, down)
        #expect(harness.session.suggestionList.isOpen)
        panel.escape()
        #expect(!harness.session.suggestionList.isOpen)
        #expect(harness.session.instantActions.suggestion != nil, "the first press only closes the list")
        panel.escape()
        #expect(harness.session.instantActions.suggestion == nil, "the second dismisses the suggestion, as before")
        #expect(harness.session.returnTarget == nil)
    }

    @Test func typingFiltersTheListAndClosesItWhenNothingMatches() async throws {
        let (harness, _) = try harness()
        harness.type("chr")
        await harness.settle()
        let matches = try #require(harness.session.instantActions.suggestion?.matches)
        let canary = try #require(matches.firstIndex { $0.title == "Google Chrome Canary" })
        press(harness, down)
        for _ in 0..<canary { press(harness, down) }
        let highlighted = try #require(harness.session.returnTarget)
        #expect(highlighted.title == "Google Chrome Canary")
        harness.type("o")
        await harness.settle()
        #expect(harness.session.suggestionList.isOpen, "typing keeps the list open")
        #expect(harness.session.returnTarget?.id == highlighted.id, "on the same match")
        #expect(harness.session.suggestionRows.last == .ask("chro"))
        harness.type("zzz")
        await harness.settle()
        #expect(!harness.session.suggestionList.isOpen)
        #expect(harness.session.suggestionRows.isEmpty)
    }

    @Test func downBelongsToRecallWhileRecalling() async throws {
        let preferences = StandInPreferences(recall: true)
        defer { preferences.forget() }
        let session = AgentSession(previewEntries: [
            ThreadEntry(date: Date().addingTimeInterval(-60), item: .userMessage(text: "chr")),
            ThreadEntry(date: Date().addingTimeInterval(-55), item: .assistantMessage(.init(text: "ok", provider: "t", model: "t"))),
            ThreadEntry(date: Date().addingTimeInterval(-50), item: .userMessage(text: "light mode")),
            ThreadEntry(date: Date().addingTimeInterval(-45), item: .assistantMessage(.init(text: "ok", provider: "t", model: "t"))),
        ])
        FooterPreview.configure(session)
        session.preferences = preferences.defaults
        let harness = try PanelHarness(session: session)
        await harness.settle()
        press(harness, up)
        press(harness, up)
        #expect(session.draft == "chr")
        #expect(session.instantActions.suggestion != nil, "the recalled text is a match")
        press(harness, down)
        #expect(!session.suggestionList.isOpen, "Down comes forward through the earlier messages")
        #expect(session.draft == "light mode")
    }

    @Test func theListDoesNotOpenWhileATaskRuns() async throws {
        let preferences = StandInPreferences(queue: true)
        defer { preferences.forget() }
        let session = AgentSession(previewEntries: [], isRunning: true)
        FooterPreview.configure(session)
        session.preferences = preferences.defaults
        session.draft = "chr"
        #expect(!session.chooseInFooter(by: 1))
        #expect(session.returnTarget == nil, "Return does not run it while a task runs")
        #expect(session.footerState == .running(queuedCount: 0))
    }

    @Test func clickingARowActsOnIt() async throws {
        let (harness, recorder) = try harness()
        harness.type("chr")
        await harness.settle()
        press(harness, down)
        let matches = try #require(harness.session.instantActions.suggestion?.matches)
        let canary = try #require(matches.firstIndex { $0.title == "Google Chrome Canary" })
        harness.session.activateSuggestionRow(canary)
        await harness.settle()
        #expect(recorder.opened == ["Google Chrome Canary"])
    }

    // MARK: - From the first character

    /// A session that sends to a stand-in model, with the stand-in apps and two whose names
    /// start with a one-letter word.
    private func sendingHarness(on: Bool) throws -> (PanelHarness, GateProvider, Recorder) {
        let provider = GateProvider(open: true)
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        FooterPreview.configure(session)
        session.suggestionList.forcedOn = on
        session.instantActions.setApplications(FooterPreview.applications + [
            InstalledApplication(name: "iMovie", bundleIdentifier: "com.apple.iMovieApp",
                                 url: URL(filePath: "/Applications/iMovie.app", directoryHint: .isDirectory)),
            InstalledApplication(name: "App Store", bundleIdentifier: "com.apple.AppStore",
                                 url: URL(filePath: "/System/Applications/App Store.app", directoryHint: .isDirectory)),
        ])
        let recorder = Recorder()
        session.instantActions.openApplication = { recorder.opened.append($0.name) }
        session.hidePanel = {}
        return (try PanelHarness(session: session), provider, recorder)
    }

    /// True when a word of the name starts with the text, ignoring case.
    private func startsAWord(_ name: String, _ text: String) -> Bool {
        name.lowercased().split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix(text) }
    }

    @Test func oneCharacterShowsTheBestMatchAndDownOpensTheList() async throws {
        let (harness, _) = try harness()
        let session = harness.session
        harness.type("x")
        await harness.settle()
        #expect(session.returnTarget?.title == "Xcode")
        #expect(session.inlineCompletion == InlineCompletion(rest: "code"))
        #expect(harness.editor.isShowingInlineCompletion)
        #expect(session.footerState == .suggestion(session.returnTarget!.target, others: 0))

        session.draft = ""

        await harness.settle()
        harness.type("c")
        await harness.settle()
        let suggestion = try #require(session.instantActions.suggestion)
        #expect(suggestion.matches.count > 1, "many names start with c")
        let target = try #require(session.returnTarget)
        #expect(target == suggestion.matches[0], "the best match")
        #expect(startsAWord(target.title, "c"))
        guard case .suggestion(_, let others) = session.footerState else {
            Issue.record("expected a suggestion, got \(session.footerState)")
            return
        }
        #expect(others == suggestion.matches.count - 1)
        press(harness, down)
        #expect(session.suggestionList.isOpen)
        #expect(session.suggestionRows == suggestion.matches.map(SuggestionRow.candidate) + [.ask("c")])
        press(harness, down)
        #expect(session.returnTarget == suggestion.matches[1])
        // Typing on filters the list, as it does for longer input.
        harness.type("h")
        await harness.settle()
        #expect(session.suggestionList.isOpen)
        #expect(session.suggestionRows.allSatisfy {
            if case .candidate(let candidate) = $0 { startsAWord(candidate.title, "ch") } else { true }
        })
    }

    @Test func returnOnOneCharacterRunsTheSuggestion() async throws {
        let (harness, recorder) = try harness()
        harness.type("x")
        await harness.settle()
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Xcode"])
        #expect(harness.session.draft == "")
        #expect(harness.session.instantActions.history.wasPicked("application:/Applications/Xcode.app", for: "x"))
    }

    @Test func commandReturnSendsTheCharacterToTheAgent() async throws {
        let (harness, provider, recorder) = try sendingHarness(on: true)
        harness.type("x")
        await harness.settle()
        #expect(harness.session.returnTarget?.title == "Xcode")
        harness.press("\r", code: 36, [.command])
        #expect(await eventually { provider.messages == ["x"] })
        await harness.session.waitUntilIdle()
        #expect(recorder.opened.isEmpty)
    }

    @Test func aOneLetterWordSuggestsThenGoesAwayAndTheSentenceIsSent() async throws {
        let (harness, provider, recorder) = try sendingHarness(on: true)
        let session = harness.session
        for (letter, name) in [("i", "iMovie"), ("a", "App Store")] {
            session.draft = ""
            await harness.settle()
            harness.type(letter)
            await harness.settle()
            #expect(session.returnTarget?.title == name)
            // A space makes it a word that starts a sentence: the mark, the gray text, and the
            // footer go back at once.
            harness.type(" ")
            await harness.settle()
            #expect(session.returnTarget == nil)
            #expect(session.inlineCompletion == nil)
            #expect(completionView(harness)?.completion == nil, "no gray text is drawn")
            #expect(session.footerState == .typing)
            press(harness, down)
            #expect(!session.suggestionList.isOpen, "Down has nothing to open")
        }
        session.draft = ""
        await harness.settle()
        harness.type("i")
        await harness.settle()
        press(harness, down)
        #expect(session.suggestionList.isOpen)
        harness.type(" want to rename photos")
        await harness.settle()
        #expect(!session.suggestionList.isOpen, "the list closes once nothing matches")
        #expect(session.returnTarget == nil)
        harness.press("\r", code: 36, [])
        #expect(await eventually { provider.messages == ["i want to rename photos"] })
        await session.waitUntilIdle()
        #expect(recorder.opened.isEmpty)
    }

    @Test func aSlashASpaceOrPunctuationFirstSuggestsNothing() async throws {
        let (harness, _) = try harness()
        let session = harness.session
        harness.type("/")
        await harness.settle()
        #expect(!session.commandSuggestions.isEmpty, "the slash list")
        #expect(session.suggestionRows.first == .command(.builtIn(.new)))
        #expect(session.returnTarget == nil)
        for text in [" ", " x", ".", ",", "?", "-"] {
            session.draft = ""
            await harness.settle()
            harness.type(text)
            await harness.settle()
            #expect(session.instantActions.suggestion == nil, "\(text.debugDescription)")
            #expect(session.returnTarget == nil)
            #expect(session.suggestionRows.isEmpty)
        }
    }

    @Test func nothingShowsWhileAnInputMethodComposes() async throws {
        let (harness, _) = try harness()
        let session = harness.session
        // A romaji or pinyin input method shows the Latin letter typed while it composes.
        harness.editor.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        await harness.settle()
        #expect(harness.editor.hasMarkedText())
        #expect(session.returnTarget == nil)
        #expect(session.inlineCompletion == nil || !harness.editor.isShowingInlineCompletion)
        #expect(session.footerState == .typing || session.footerState == .idle)
        press(harness, down)
        #expect(!session.suggestionList.isOpen)
        // What the input method puts in the field is judged as typed text.
        harness.editor.insertText("か", replacementRange: NSRange(location: 0, length: 1))
        await harness.settle()
        #expect(!harness.editor.hasMarkedText())
        #expect(session.draft == "か")
        #expect(session.returnTarget == nil)
        session.draft = ""
        await harness.settle()
        harness.editor.setMarkedText("x", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        harness.editor.unmarkText()
        await harness.settle()
        #expect(session.returnTarget?.title == "Xcode", "the letter, once it is in the field")
    }

    @Test func withTheSwitchOffOneCharacterStillSuggestsNothing() async throws {
        let (harness, provider, recorder) = try sendingHarness(on: false)
        let session = harness.session
        for letter in ["x", "c", "s", "i", "a", "1"] {
            session.draft = ""
            await harness.settle()
            harness.type(letter)
            await harness.settle()
            #expect(session.instantActions.mode == .row)
            #expect(session.instantActions.suggestion == nil, "\(letter) offered \(session.instantActions.suggestion?.choices.map(\.title) ?? [])")
            #expect(session.returnTarget == nil)
        }
        // Two letters with no clear leader offer nothing in the row either, as before.
        session.draft = ""
        await harness.settle()
        harness.type("ca")
        await harness.settle()
        #expect(session.instantActions.suggestion == nil)
        // Return sends the letter to the agent.
        session.draft = ""
        await harness.settle()
        harness.type("x")
        await harness.settle()
        harness.press("\r", code: 36, [])
        #expect(await eventually { provider.messages == ["x"] })
        await session.waitUntilIdle()
        #expect(recorder.opened.isEmpty)
        await harness.settle()
        // Turned on in Settings with the letter in the field, Return takes the suggestion.
        harness.type("x")
        await harness.settle()
        session.suggestionList.forcedOn = true
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Xcode"])
    }

    // MARK: - Slash commands

    @Test func slashOpensTheListByItself() async throws {
        let (harness, _) = try harness()
        harness.session.skillCommands = SkillCommandsModel(menu: FooterPreview.skills)
        harness.type("/")
        await harness.settle()
        let session = harness.session
        #expect(session.suggestionRows.count == session.commandSuggestions.count)
        #expect(session.suggestionRows.first == .command(.builtIn(.new)))
        #expect(session.inlineCompletion == InlineCompletion(rest: "new"))
        #expect(session.returnTarget == nil, "the mark stays `›`")
        // Up and Down choose as before, and the gray text follows.
        press(harness, down)
        #expect(session.hintSelection == 1)
        #expect(session.inlineCompletion == InlineCompletion(rest: "incognito"))
        harness.type("re")
        await harness.settle()
        #expect(session.inlineCompletion == InlineCompletion(rest: "name-photos"))
        // Return on a partial name completes it, as before.
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(session.draft == "/rename-photos ")
        #expect(session.inlineCompletion == nil, "a skill's text is being typed")
        // Escape hides the list for the draft, as before.
        session.draft = "/"
        (harness.panel as? SummonPanel)?.escape()
        #expect(session.suggestionRows.isEmpty)
    }

    // MARK: - Incognito

    @Test func theIncognitoWindowListsAppsOnly() async throws {
        let (harness, recorder) = try harness(incognito: true)
        harness.type("chr")
        await harness.settle()
        press(harness, down)
        let rows = harness.session.suggestionRows
        #expect(!rows.isEmpty)
        #expect(!rows.contains { if case .candidate(let c) = $0, case .quickAction = c.target { true } else { false } },
                "it has no quick actions")
        harness.press("\r", code: 36, [])
        await harness.settle()
        #expect(recorder.opened == ["Google Chrome"])
        #expect(!harness.session.instantActions.learns)
        harness.session.draft = "/"
        await harness.settle()
        #expect(harness.session.suggestionRows == [.command(.builtIn(.new)), .command(.builtIn(.incognito))])
    }
}

/// The window growing downward for the list, and everything that must not see it, through the
/// real panel with stand-in screens and a defaults suite of its own. Nothing goes on screen.
@MainActor
@Suite(.serialized) struct SuggestionListPlacementTests {
    init() { _ = NSApplication.shared }

    private let suiteName = "mac-os-agent-footer-tests-\(UUID().uuidString)"
    private let standIn = StandInScreens()

    private var laptop: CGRect { StandInScreens.laptop.visible }

    private func makePanel(frame: CGRect = CGRect(x: 300, y: 200, width: 640, height: 560), role: SummonPanel.Role = .main)
        throws -> (SummonPanel, AgentSession, UserDefaults)
    {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let session = AgentSession(previewEntries: FooterPreview.thread(), incognito: role == .incognito)
        FooterPreview.configure(session)
        session.instantActions.openApplication = { _ in }
        let standIn = standIn
        let panel = SummonPanel(
            session: session, role: role, remembersFrame: false, placementDefaults: defaults,
            screens: { standIn.screens }, mouseLocation: { standIn.mouse })
        panel.orderIn = { _, _ in }
        panel.orderAway = { _ in }
        panel.drivesSlidesWithTheDisplay = false
        panel.reduceMotion = { false }
        panel.summon()
        panel.setFrame(frame, display: false)
        return (panel, session, defaults)
    }

    private func cleanUp(_ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Types "chr" and opens the list with Down.
    private func openList(_ session: AgentSession) {
        session.draft = "chr"
        #expect(session.chooseInFooter(by: 1))
    }

    @Test func theWindowGrowsDownwardAndNothingAboveMoves() throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        openList(session)
        let height = session.suggestionListHeight
        #expect(height > 0)
        #expect(panel.footerGrowth == height)
        #expect(session.suggestionList.growth == height)
        #expect(panel.frame.maxY == before.maxY, "the top stays where it was")
        #expect(panel.frame.minY == before.minY - height, "the bottom edge moves down by the list's height")
        #expect(panel.panelFrame == before, "the panel's own frame does not change")
        #expect(panel.glassFrameOnScreen.height == before.height + height, "the glass covers the list")
        // Moving through the list keeps the size. Closing it shrinks the window back.
        _ = session.chooseInFooter(by: 1)
        #expect(panel.frame.minY == before.minY - height)
        _ = session.chooseInFooter(by: -1)
        _ = session.chooseInFooter(by: -1)
        #expect(!session.suggestionList.isOpen)
        #expect(panel.frame == before)
        #expect(panel.footerGrowth == 0)
        #expect(session.suggestionList.growth == 0)
    }

    @Test func typingResizesTheGrowthToTheList() async throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        openList(session)
        let grown = panel.footerGrowth
        session.draft = "chrome canary"
        // Typing reaches the window a turn later.
        #expect(await eventually { panel.footerGrowth == session.suggestionListHeight })
        #expect(panel.footerGrowth < grown)
        #expect(panel.frame.maxY == before.maxY)
        session.draft = "chrzzz"
        #expect(await eventually { panel.footerGrowth == 0 })
        #expect(panel.frame == before)
    }

    @Test func theGrowthIsNeverSaved() throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        // The real panel saves its frame under an autosave name. A test name stands in for it.
        let name = "mac-os-agent-footer-test-\(UUID().uuidString)"
        #expect(panel.setFrameAutosaveName(name))
        defer {
            panel.setFrameAutosaveName("")
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)")
        }
        let before = panel.frame
        let saved = UserDefaults.standard.string(forKey: "NSWindow Frame \(name)")
        openList(session)
        #expect(panel.frameAutosaveName.isEmpty, "set aside while grown")
        #expect(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)") == saved)
        panel.dismiss()
        #expect(panel.frameAutosaveName == name)
        #expect(panel.frame == before)
        // The saved descriptor starts with the frame: x, y, width, height.
        let descriptor = try #require(UserDefaults.standard.string(forKey: "NSWindow Frame \(name)"))
        let numbers = descriptor.split(separator: " ").prefix(4).compactMap { Double($0) }.map { CGFloat($0) }
        #expect(numbers == [before.minX, before.minY, before.width, before.height], "the panel's own frame is what is saved")
    }

    @Test func choosingALayoutWhileGrownKeepsThePanelsOwnFrame() throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        openList(session)
        panel.choose(.slideOverLeft)
        #expect(!session.suggestionList.isOpen)
        #expect(panel.footerGrowth == 0)
        #expect(defaults.string(forKey: SummonPanel.centeredFrameKey) == NSStringFromRect(before), "the saved centered frame")
        #expect(panel.frame == PanelGeometry.slideOverWindowFrame(
            panel: PanelGeometry.slideOverFrame(.left, width: 640, minimumWidth: 440, in: laptop), edge: .left, in: laptop))
        #expect(defaults.double(forKey: SummonPanel.slideOverWidthKey) == 0 || defaults.double(forKey: SummonPanel.slideOverWidthKey) == 640)
        panel.choose(.centered)
        #expect(panel.frame == before, "comes back to the frame from before, not the grown one")
    }

    @Test func slideOverHasNoRoomSoTheListCoversTheConversation() throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        panel.choose(.slideOverRight)
        let before = panel.frame
        openList(session)
        #expect(session.suggestionList.isOpen)
        #expect(!session.suggestionRows.isEmpty)
        #expect(!panel.canGrowDownward(by: session.suggestionListHeight))
        #expect(panel.footerGrowth == 0)
        #expect(session.suggestionList.growth == 0, "growth zero draws the list over the conversation")
        #expect(panel.frame == before)
        #expect(defaults.double(forKey: SummonPanel.slideOverWidthKey) == panel.panelFrame.width || defaults.double(forKey: SummonPanel.slideOverWidthKey) == 0)
    }

    @Test(arguments: [CGFloat(4), 60, 120])
    func aPanelNearTheBottomOfTheScreenCoversTheConversationInstead(_ room: CGFloat) throws {
        let (panel, session, defaults) = try makePanel(frame: CGRect(x: 300, y: laptop.minY + room, width: 640, height: 560))
        defer { cleanUp(defaults) }
        session.draft = "chr"
        let height = SuggestionListView.height(rowCount: (session.instantActions.suggestion?.matches.count ?? 0) + 1)
        _ = session.chooseInFooter(by: 1)
        let fits = room >= height + SummonPanel.footerGrowthMargin
        #expect(panel.footerGrowth == (fits ? height : 0))
        #expect(panel.panelFrame.minY == laptop.minY + room)
    }

    @Test func theChoiceOfWhereTheListGoes() throws {
        let (panel, _, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        #expect(panel.canGrowDownward(by: 100), "a centered panel with room below")
        #expect(!panel.canGrowDownward(by: 200 - SummonPanel.footerGrowthMargin + 1), "not quite enough room")
        panel.dismiss()
        #expect(!panel.canGrowDownward(by: 100), "a hidden panel does not grow")
        panel.summon()
        panel.choose(.slideOverLeft)
        #expect(!panel.canGrowDownward(by: 10), "slide over is full height")
    }

    @Test func returnToThePresetAndTheDoubleClickResetIgnoreTheGrowth() throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        openList(session)
        panel.returnToPresetFrame()
        #expect(!session.suggestionList.isOpen)
        #expect(panel.footerGrowth == 0)
        #expect(panel.frame.size == SummonPanel.defaultSize)
        openList(session)
        #expect(panel.footerGrowth > 0)
        panel.resetToDefaultPlace()
        #expect(panel.footerGrowth == 0)
        #expect(panel.frame.size == SummonPanel.defaultSize)
    }

    @Test func flushEdgesTheInspectorAndTheIncognitoWindowSeeThePanelsOwnFrame() throws {
        // A panel whose bottom is just above the bottom of the screen: grown, its glass would be
        // close to the edge, but the corners are worked out from its own frame.
        let (panel, session, defaults) = try makePanel(frame: CGRect(x: 0, y: 300, width: 640, height: 560))
        defer { cleanUp(defaults) }
        let before = panel.panelFrame
        let edgesBefore = panel.squareEdges
        openList(session)
        #expect(panel.footerGrowth > 0)
        #expect(panel.placement.panelFrame == before, "what the inspector and the corners read")
        #expect(panel.squareEdges == edgesBefore)
        #expect(panel.placedFrame == before, "where the incognito window opens beside")
    }

    @Test func hidingClosesTheListAndShrinksTheWindow() throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        openList(session)
        panel.dismiss()
        #expect(!session.suggestionList.isOpen)
        #expect(panel.footerGrowth == 0)
        #expect(panel.frame == before)
    }

    @Test func theOwnersResizeWhileGrownIsKept() throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        openList(session)
        var resized = panel.frame
        resized.size.height += 40
        resized.origin.y -= 40
        panel.setFrame(resized, display: false)
        #expect(panel.footerGrowth == 0)
        #expect(!session.suggestionList.isOpen)
        #expect(panel.frame == resized)
        #expect(panel.panelFrame == resized)
    }

    @Test func theOwnersMoveWhileGrownKeepsTheList() throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        let before = panel.frame
        openList(session)
        let growth = panel.footerGrowth
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + 50, y: panel.frame.minY + 30))
        #expect(session.suggestionList.isOpen)
        #expect(panel.footerGrowth == growth)
        #expect(panel.panelFrame == before.offsetBy(dx: 50, dy: 30))
        _ = session.closeSuggestionList()
        #expect(panel.frame == before.offsetBy(dx: 50, dy: 30))
    }

    @Test func theSlashListGrowsTheWindowByItself() async throws {
        let (panel, session, defaults) = try makePanel()
        defer { cleanUp(defaults) }
        session.skillCommands = SkillCommandsModel(menu: FooterPreview.skills)
        let before = panel.frame
        session.draft = "/"
        #expect(await eventually { panel.footerGrowth == session.suggestionListHeight })
        #expect(panel.frame.maxY == before.maxY)
        session.draft = ""
        #expect(await eventually { panel.footerGrowth == 0 })
        #expect(panel.frame == before)
    }

    @Test func theIncognitoWindowGrowsTheSameWay() throws {
        let (panel, session, defaults) = try makePanel(role: .incognito)
        defer { cleanUp(defaults) }
        let before = panel.panelFrame
        openList(session)
        #expect(panel.footerGrowth == session.suggestionListHeight)
        #expect(panel.panelFrame == before)
        panel.dismiss()
        #expect(panel.footerGrowth == 0)
    }
}
