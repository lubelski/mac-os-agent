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
/// - `bars-running`: a task running: the working row's marks and "Working…", and the status
///   line saying how to stop it.
/// - `bars-working-hover`: the same, drawn as if the pointer were over the working row, so Stop shows.
/// - `bars-queued`: a task running with the queue experiment on and two messages queued, drawn
///   at the end of the conversation as pending messages, the first as if under the pointer.
/// - `bars-lines`: the three lines in the conversation, one after another: an app opened, a
///   quick action that ran, and one that failed.
/// - `bars-lines-off`: the same thread with the experiment off, as the panel draws it today: the
///   typed text and a row per step for each run, and nothing for the opening.
/// - `bars-card-down`: "chr", with the match card open downward past the panel's bottom edge,
///   in its own window. Captured with the backdrop, which covers both windows.
/// - `bars-card-up`: the same card opening upward over the end of the conversation, as it does
///   with no room below.
/// - `bars-card-slash`: the slash commands in the card, opening downward.
@MainActor
enum PanelWithBarsPreview {
    static let names = [
        "bars-rest", "bars-typing", "bars-long", "bars-match", "bars-slash", "bars-running", "bars-working-hover",
        "bars-queued", "bars-lines", "bars-lines-off", "bars-card-down", "bars-card-up", "bars-card-slash",
    ]

    /// The states whose card opens below the panel, in a window of its own, so a capture of the
    /// panel's window alone would leave it out.
    static func opensBelow(_ name: String) -> Bool {
        name == "bars-card-down" || name == "bars-card-slash"
    }

    static func session(named name: String) -> AgentSession? {
        guard names.contains(name) else { return nil }
        if name == "bars-lines-off" {
            let session = AgentSession(previewEntries: thread() + linesThread())
            session.forcedPanelWithBars = false
            return session
        }
        let entries = name == "bars-lines" ? thread() + linesThread() : thread()
        let session = AgentSession(previewEntries: entries, isRunning: runs(name))
        configure(session)
        switch name {
        case "bars-typing":
            session.draft = "what's on my calendar tomorrow"
        case "bars-long":
            session.draft = "Draft a reply to Dana.\nThursday works for me.\nI will bring the deck."
        case "bars-match":
            session.draft = "chr"
            _ = session.chooseInFooter(by: 1)
        case "bars-working-hover":
            session.previewHoversWorkingRow = true
        case "bars-queued":
            session.forcedQueuesWhileRunning = true
            session.previewHoversQueuedMessage = true
            for text in ["and the menu bar too", "then set an alarm for 7"] {
                session.draft = text
                session.submitToAgent()
            }
        case "bars-slash", "bars-card-slash":
            session.skillCommands = SkillCommandsModel(menu: FooterPreview.skills)
            session.draft = "/re"
        case "bars-card-down":
            session.draft = "chr"
        case "bars-card-up":
            session.suggestionList.previewOpensUpward = true
            session.draft = "chr"
        default:
            break
        }
        return session
    }

    private static func runs(_ name: String) -> Bool {
        ["bars-running", "bars-working-hover", "bars-queued"].contains(name)
    }

    /// Turns the experiment on for a session, with the suggestions previews' stand-in apps and
    /// actions. The suggestions experiment's own switch is left alone: the frame turns its
    /// machinery on by itself.
    static func configure(_ session: AgentSession) {
        session.forcedPanelWithBars = true
        session.followPanelWithBarsSwitch()
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

    /// What the owner did after the exchange without a message: opened Calendar, ran a quick
    /// action, and ran it again when it failed.
    static func linesThread() -> [ThreadEntry] {
        let now = Date()
        let calendar = InstalledApplication(
            name: "Calendar", bundleIdentifier: "com.apple.iCal",
            url: URL(filePath: "/System/Applications/Calendar.app", directoryHint: .isDirectory))
        let lights = QuickAction(
            id: "balcony-lights-on", name: "Balcony Lights On", description: "Turns the balcony lights on.",
            steps: [.init(tool: "run_shell_command", arguments: ["command": "shortcuts run \"Balcony Lights On\"", "destructive": false])])
        func run(_ output: String, failed: Bool, id: UUID) -> ThreadItem {
            let step = ThreadItem.QuickActionRun.Step(
                callID: QuickActionRunStart.callID(entryID: id, index: 0), tool: "run_shell_command",
                arguments: lights.steps[0].arguments.encodedString(), output: output)
            let record = ThreadItem.QuickActionRun(
                id: lights.id, name: lights.name, stepCount: 1, steps: [step], failedStep: failed ? 0 : nil,
                message: ThreadItem.QuickActionRun.message(typed: "bal", action: lights, steps: [step], failedStep: failed ? 0 : nil))
            return .userMessage(text: "bal", action: record)
        }
        let ran = UUID()
        let failed = UUID()
        return [
            ThreadEntry(date: now.addingTimeInterval(-40), item: .appOpened(ThreadItem.AppOpening(calendar))),
            ThreadEntry(id: ran, date: now.addingTimeInterval(-30), item: run("[exit status 0]", failed: false, id: ran)),
            ThreadEntry(id: failed, date: now.addingTimeInterval(-20), item: run(
                "Error: no shortcut by that name.\n[exit status 1]", failed: true, id: failed)),
        ]
    }
}
