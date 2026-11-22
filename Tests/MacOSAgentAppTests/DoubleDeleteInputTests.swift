import AppKit
import Foundation
import MacOSAgentCore
import Testing
@testable import mac_os_agent

/// Delete twice in an empty field, driven with key presses in the real panel, which is never
/// put on screen. Each press has a timestamp of the test's own, and the interval is fixed, so
/// the owner's double-click setting does not change the outcome.
@MainActor
@Suite(.serialized) struct DoubleDeleteInputTests {
    init() { _ = NSApplication.shared }

    static let interval: TimeInterval = 0.5

    private struct Setup {
        let harness: PanelHarness
        let preferences: StandInPreferences
        let provider: GateProvider
        var session: AgentSession { harness.session }
    }

    /// The main panel over a kept session with one exchange in its episode.
    private func mainPanel(doubleDelete: Bool? = nil, queue: Bool? = nil) async throws -> Setup {
        let preferences = StandInPreferences(queue: queue)
        if let doubleDelete { HarnessBehavior.doubleDeleteStartsNewEpisode.set(doubleDelete, preferences.defaults) }
        let provider = GateProvider(open: true)
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.preferences = preferences.defaults
        session.draft = "first"
        session.submit()
        await session.waitUntilIdle()
        let harness = try PanelHarness(session: session)
        harness.editor.doubleDeleteInterval = { Self.interval }
        await harness.settle()
        return Setup(harness: harness, preferences: preferences, provider: provider)
    }

    private func delete(_ harness: PanelHarness, at time: TimeInterval, repeating: Bool = false) {
        harness.panel.sendEvent(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: time,
            windowNumber: harness.panel.windowNumber, context: nil, characters: "\u{7F}",
            charactersIgnoringModifiers: "\u{7F}", isARepeat: repeating, keyCode: 51)!)
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    @Test func twoPressesOnAnEmptyFieldStartAnEpisodeAsSlashNewDoes() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        let rowsBefore = setup.session.transcript.rows.count
        #expect(!setup.session.transcript.hasPendingEpisode)
        let start = now
        delete(setup.harness, at: start)
        #expect(!setup.session.transcript.hasPendingEpisode, "the first press does nothing visible")
        delete(setup.harness, at: start + 0.2)
        #expect(setup.session.transcript.hasPendingEpisode)
        #expect(setup.session.transcript.currentEpisodeStartRow == rowsBefore)
        #expect(setup.session.draft.isEmpty)
    }

    @Test func onAFreshPageItAddsNothingMoreThanSlashNewWould() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        setup.session.perform(.new)
        let rows = setup.session.transcript.rows
        let start = now
        delete(setup.harness, at: start)
        delete(setup.harness, at: start + 0.2)
        #expect(setup.session.transcript.rows == rows)
    }

    @Test func onePressDoesNothing() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        delete(setup.harness, at: now)
        await setup.harness.settle()
        #expect(!setup.session.transcript.hasPendingEpisode)
    }

    @Test func holdingDeleteIntoAnEmptyFieldDoesNothing() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        setup.harness.type("a long draft")
        await setup.harness.settle()
        let start = now
        delete(setup.harness, at: start)
        for step in 1...30 {
            delete(setup.harness, at: start + 0.5 + Double(step) * 0.03, repeating: true)
        }
        #expect(setup.harness.editor.string.isEmpty)
        #expect(!setup.session.transcript.hasPendingEpisode)
        // Letting go and pressing once is one press on empty, not the second.
        delete(setup.harness, at: start + 1.5)
        #expect(!setup.session.transcript.hasPendingEpisode)
    }

    @Test func tooSlowDoesNothing() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        let start = now
        delete(setup.harness, at: start)
        delete(setup.harness, at: start + Self.interval + 0.1)
        #expect(!setup.session.transcript.hasPendingEpisode)
    }

    @Test func deletingTheLastCharacterThenOnePressDoesNothing() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        setup.harness.type("a")
        await setup.harness.settle()
        let start = now
        delete(setup.harness, at: start)
        #expect(setup.session.draft.isEmpty)
        delete(setup.harness, at: start + 0.1)
        #expect(!setup.session.transcript.hasPendingEpisode)
    }

    @Test func aKeyInBetweenStartsOver() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        let start = now
        delete(setup.harness, at: start)
        // Right Arrow does nothing in an empty field, but it is a key in between.
        setup.harness.press("\u{F703}", code: 124, [.function, .numericPad])
        delete(setup.harness, at: start + 0.2)
        #expect(!setup.session.transcript.hasPendingEpisode)
    }

    @Test func typingAndErasingInBetweenStartsOver() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        let start = now
        delete(setup.harness, at: start)
        setup.harness.type("x")
        setup.session.draft = ""
        await setup.harness.settle()
        delete(setup.harness, at: start + 0.2)
        #expect(!setup.session.transcript.hasPendingEpisode)
    }

    @Test func showingThePanelAgainStartsOver() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        let start = now
        delete(setup.harness, at: start)
        setup.session.panelDidAppear()
        await setup.harness.settle()
        delete(setup.harness, at: start + 0.2)
        #expect(!setup.session.transcript.hasPendingEpisode)
    }

    @Test func composingTextIsLeftAlone() async throws {
        let setup = try await mainPanel()
        defer { setup.preferences.forget() }
        setup.harness.editor.setMarkedText("kaz", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(setup.harness.editor.hasMarkedText())
        // A press while composing is the input method's, and it never counts as the first of two.
        let start = now
        delete(setup.harness, at: start)
        delete(setup.harness, at: start + 0.1)
        #expect(!setup.session.transcript.hasPendingEpisode)
    }

    @Test func withTheSwitchOffItDoesNothing() async throws {
        let setup = try await mainPanel(doubleDelete: false)
        defer { setup.preferences.forget() }
        let start = now
        delete(setup.harness, at: start)
        delete(setup.harness, at: start + 0.2)
        #expect(!setup.session.transcript.hasPendingEpisode)
        #expect(!setup.session.startNewEpisodeFromKeys())
    }

    /// `/new` is refused while a task runs, and so is this. With the queue experiment off,
    /// Return does nothing then, and with it on a line says the command can wait.
    @Test(arguments: [false, true])
    func whileATaskRunsItDoesWhatSlashNewDoes(queue: Bool) async throws {
        let setup = try await mainPanel(queue: queue)
        defer { setup.preferences.forget() }
        let provider = GateProvider()
        let session = AgentSession(
            loop: AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { 1800 }),
            authenticator: nil, episodeTimeout: { 1800 }, signedIn: true)
        session.preferences = setup.preferences.defaults
        let harness = try PanelHarness(session: session)
        harness.editor.doubleDeleteInterval = { Self.interval }
        session.draft = "go"
        session.submit()
        #expect(session.isRunning)
        await harness.settle()

        // What `/new` and Return does now.
        let rowsBefore = session.transcript.rows
        session.draft = "/new"
        session.submit()
        let typedRows = session.transcript.rows
        let typedPending = session.transcript.hasPendingEpisode
        session.draft = ""
        // With the queue on, a line says it can wait. With it off, nothing happens.
        #expect(typedRows.count == rowsBefore.count + (queue ? 1 : 0))
        await harness.settle()

        let start = now
        delete(harness, at: start)
        delete(harness, at: start + 0.2)
        #expect(session.transcript.hasPendingEpisode == typedPending)
        #expect(!session.transcript.hasPendingEpisode)
        if queue {
            #expect(session.transcript.rows.count == typedRows.count + 1)
            #expect(session.transcript.rows.last?.kind == .notice("/new can be used when the task ends."))
        } else {
            #expect(session.transcript.rows == typedRows)
        }
        #expect(session.isRunning)
        session.stop()
        await session.waitUntilIdle()
    }

    // MARK: - The incognito window

    private func incognito(provider: GateProvider) throws -> (PanelHarness, StandInPreferences) {
        let preferences = StandInPreferences()
        let session = AgentSession(
            incognito: { AgentLoop(provider: provider, thread: InMemoryThreadStore(), tools: [], episodeTimeout: { .infinity }) },
            signedIn: true)
        session.preferences = preferences.defaults
        let harness = try PanelHarness(session: session)
        harness.editor.doubleDeleteInterval = { Self.interval }
        return (harness, preferences)
    }

    @Test func inTheIncognitoWindowItClearsTheConversationAsSlashNewDoes() async throws {
        let (harness, preferences) = try incognito(provider: GateProvider(open: true))
        defer { preferences.forget() }
        let session = harness.session
        session.draft = "a secret"
        session.submit()
        await session.waitUntilIdle()
        await harness.settle()
        let conversation = session.conversation
        #expect(!session.transcript.rows.allSatisfy { $0.isEpisodeStart })
        let start = now
        delete(harness, at: start)
        delete(harness, at: start + 0.2)
        #expect(session.conversation == conversation + 1)
        #expect(session.transcript.rows.allSatisfy { $0.isEpisodeStart })
    }

    @Test func inTheIncognitoWindowItIsRefusedWhileATaskRuns() async throws {
        let provider = GateProvider()
        let (harness, preferences) = try incognito(provider: provider)
        defer { preferences.forget() }
        let session = harness.session
        session.draft = "a secret"
        session.submit()
        #expect(session.isRunning)
        await harness.settle()
        let conversation = session.conversation
        let rows = session.transcript.rows
        let start = now
        delete(harness, at: start)
        delete(harness, at: start + 0.2)
        #expect(session.conversation == conversation)
        #expect(session.transcript.rows == rows)
        #expect(session.pendingDiscard == nil, "no card asks, since /new does not ask either")
        session.stop()
        await session.waitUntilIdle()
    }
}
