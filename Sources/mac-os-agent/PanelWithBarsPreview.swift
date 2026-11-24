import Foundation
import MacOSAgentCore

/// Stand-in states for the panel with bars and an input pill (`Experiment.panelWithBarsAndInputPill`),
/// for screenshots and tests. The experiment is on for these sessions only, without touching the
/// preferences, and they use the suggestions previews' made-up apps and actions, so nothing
/// reads the real ones.
///
/// - `bars-rest`: at rest, an empty field under a short conversation.
/// - `bars-typing`: one line typed, which the status line answers with "↵ send".
/// - `bars-long`: a message of several lines, so the pill is a taller box.
/// - `bars-match`: "chr", with the gray completion and the list open under the pill.
/// - `bars-slash`: the slash command list.
/// - `bars-running`: a task running, with the status line saying how to stop it.
@MainActor
enum PanelWithBarsPreview {
    static let names = ["bars-rest", "bars-typing", "bars-long", "bars-match", "bars-slash", "bars-running"]

    static func session(named name: String) -> AgentSession? {
        guard names.contains(name) else { return nil }
        let session = AgentSession(previewEntries: thread(), isRunning: name == "bars-running")
        configure(session)
        switch name {
        case "bars-typing":
            session.draft = "what's on my calendar tomorrow"
        case "bars-long":
            session.draft = "Draft a reply to Dana.\nThursday works for me.\nI will bring the deck."
        case "bars-match":
            session.draft = "chr"
            _ = session.chooseInFooter(by: 1)
        case "bars-slash":
            session.skillCommands = SkillCommandsModel(menu: FooterPreview.skills)
            session.draft = "/re"
        default:
            break
        }
        return session
    }

    /// Turns the experiment on for a session, with the suggestions previews' stand-in apps and
    /// actions. The suggestions experiment's own switch is left alone: the frame turns its
    /// machinery on by itself.
    static func configure(_ session: AgentSession) {
        session.forcedPanelWithBars = true
        session.instantActions = InstantActions(
            applications: FooterPreview.applications, learns: !session.isIncognito, history: FooterPreview.history)
        if !session.isIncognito { session.instantActions.setActions(FooterPreview.actions) }
    }

    /// The short exchange from the mockup.
    static func thread() -> [ThreadEntry] {
        let now = Date()
        func reply(_ text: String) -> ThreadItem {
            .assistantMessage(.init(text: text, provider: "openai", model: "gpt-6-luna"))
        }
        return [
            ThreadEntry(date: now.addingTimeInterval(-300), item: .userMessage(text: "try paper")),
            ThreadEntry(date: now.addingTimeInterval(-295), item: reply("Done. Paper is on.")),
            ThreadEntry(date: now.addingTimeInterval(-120), item: .userMessage(text: "light mode")),
            ThreadEntry(date: now.addingTimeInterval(-115), item: reply("For the whole Mac or just the Iris panel?")),
            ThreadEntry(date: now.addingTimeInterval(-60), item: .userMessage(text: "dark mode")),
            ThreadEntry(date: now.addingTimeInterval(-55), item: reply("Done. The panel is dark now.")),
        ]
    }
}
