import AppKit
import MacOSAgentCore

/// The one incognito window, and the conversation in it.
///
/// `/incognito` in the main panel and the Incognito item in the menu bar menu call `open()`.
/// It makes a new session and window when none is open, beside the main panel, and otherwise
/// brings the open one forward with its text field focused. The main panel is never changed.
///
/// The window lasts until the owner closes it. Closing it, with the close button or
/// Command-W, ends its session: the controller lets go of the window and the session, and with
/// them the loop, its in-memory store, and every row. Nothing about it was written anywhere,
/// so nothing is left. Quitting the app does the same.
@MainActor
final class IncognitoWindowController {
    private(set) var session: AgentSession?
    private(set) var panel: SummonPanel?
    /// Makes the session for a new window.
    private let makeSession: () -> AgentSession
    /// Makes the window for a session. Tests stand in a panel that never goes on screen.
    private let makePanel: (AgentSession) -> SummonPanel
    /// The main panel's frame, to open beside it.
    var mainPanelFrame: () -> CGRect? = { nil }
    /// Called when the window opens or closes, and when its task starts or stops.
    var onChange: () -> Void = {}

    init(
        makeSession: @escaping () -> AgentSession,
        makePanel: @escaping (AgentSession) -> SummonPanel = { SummonPanel(session: $0, role: .incognito) }
    ) {
        self.makeSession = makeSession
        self.makePanel = makePanel
    }

    var isOpen: Bool { panel != nil }

    /// Opens the window, or brings the open one forward and focuses it.
    func open() {
        if let panel {
            panel.focus()
            return
        }
        let session = makeSession()
        session.closeWindow = { [weak self] in self?.close() }
        session.onStatusChange = { [weak self] in self?.onChange() }
        let panel = makePanel(session)
        let mainPanelFrame = mainPanelFrame
        panel.mainPanelFrame = mainPanelFrame
        self.session = session
        self.panel = panel
        panel.summon()
        onChange()
    }

    /// Takes the window off screen and lets go of everything in it. The session calls this
    /// once it has discarded its conversation.
    private func close() {
        guard let panel else { return }
        panel.inspector.close()
        panel.dismiss()
        self.panel = nil
        session = nil
        onChange()
    }

    /// The loop for one incognito conversation. It runs over a store that lives only in memory,
    /// with only the application tools, and with instructions read once here, so they stay the
    /// same for the whole conversation and its prompt cache holds. The usage log still gets its
    /// token counts, which hold no content. It never ends on the episode timeout.
    nonisolated static func makeLoop(
        provider: any ModelProvider, prompt: AgentPrompt, usageLog: UsageLog?,
        applicationWorkspace: any ApplicationWorkspace = SystemApplicationWorkspace()
    ) -> AgentLoop {
        let instructions = prompt.currentIncognito()
        return AgentLoop(
            provider: provider, thread: InMemoryThreadStore(),
            tools: BuiltInTools.makeIncognito(applicationWorkspace: applicationWorkspace),
            instructions: { instructions },
            usageLog: usageLog,
            episodeTimeout: { .infinity })
    }

    /// Asks the open window to close, as its close button does: at once with no task running,
    /// and after the owner confirms with one.
    func requestClose() {
        session?.requestDiscard(.close)
    }
}
