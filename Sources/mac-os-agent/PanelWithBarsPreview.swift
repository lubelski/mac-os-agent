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
/// - `bars-layout`: owner messages, a long reply and a short one, a time label after a pause,
///   and the three lines, to compare the message layouts with `--preview-message-layout`.
/// - `bars-layout-copy`: the same, with every copy control showing, as under the pointer.
/// - `bars-scrolled`: the same after an earlier exchange, too long for the panel, so the
///   conversation is scrolled to its end with a reply cut off under the top bar, to show the
///   hairlines that set the bars apart from it.
/// - `bars-links`: three task links above the pill. `bars-rest` is the same panel with none.
/// - `bars-links-more`: five, so two go into the overflow menu at the row's end.
/// - `bars-card-down`: "chr", with the match card open downward past the panel's bottom edge,
///   in its own window, with room for every row. A render draws both windows.
/// - `bars-card-short-top`: "c", with seven rows and room below for two and a part, the fewest,
///   so the card is shortened and scrolls, at its top: two whole rows and part of the third.
/// - `bars-card-short`: the same with the highlight moved to the fifth row, so the list is
///   scrolled partway, the fifth row the last whole one and part of the sixth below it.
/// - `bars-card-short-end`: the same scrolled to its end, on the Ask row, with the part row at
///   the top.
/// - `bars-card-up`: the same card opening upward over the end of the conversation, as it does
///   with room below for less than two rows and a part, as in slide over, with three task links that it
///   covers.
/// - `bars-card-slash`: the slash commands in the card, opening downward.
@MainActor
enum PanelWithBarsPreview {
    static let names = [
        "bars-rest", "bars-typing", "bars-long", "bars-match", "bars-slash", "bars-running", "bars-working-hover",
        "bars-queued", "bars-lines", "bars-lines-off", "bars-layout", "bars-layout-copy", "bars-scrolled", "bars-links",
        "bars-links-more", "bars-card-down", "bars-card-short-top", "bars-card-short", "bars-card-short-end", "bars-card-up",
        "bars-card-slash",
    ]

    /// The room below the panel for `bars-card-short`: two rows, the part row, and the card's
    /// hairline.
    static let shortCardRoom = MatchCard.reachBelowPanel(rows: 2, partRowHeight: MatchCard.partRowHeight)

    /// The states whose card opens below the panel, in a window of its own, so a capture of the
    /// panel's window alone would leave it out.
    static func opensBelow(_ name: String) -> Bool {
        ["bars-card-down", "bars-card-short-top", "bars-card-short", "bars-card-short-end", "bars-card-slash"].contains(name)
    }

    static func session(named name: String) -> AgentSession? {
        guard names.contains(name) else { return nil }
        if name == "bars-lines-off" {
            let session = AgentSession(previewEntries: thread() + linesThread())
            session.forcedPanelWithBars = false
            return session
        }
        let entries = switch name {
        case "bars-lines": thread() + linesThread()
        case "bars-layout", "bars-layout-copy": layoutThread() + linesThread()
        case "bars-scrolled":
            // The earlier exchange goes inside the layout thread's episode, after its marker, so
            // the episode is longer than the panel and the conversation opens at its end.
            Array(layoutThread().prefix(1)) + earlierThread() + layoutThread().dropFirst() + linesThread()
        default: thread()
        }
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
        case "bars-layout-copy":
            session.previewRevealsControls = true
        case "bars-links":
            session.taskLinks = Array(links.prefix(3))
        case "bars-links-more":
            session.taskLinks = links
        case "bars-slash":
            session.skillCommands = SkillCommandsModel(menu: FooterPreview.skills)
            session.draft = "/re"
        case "bars-card-slash":
            session.skillCommands = SkillCommandsModel(menu: FooterPreview.skills)
            session.suggestionList.previewRoomBelow = 1000
            session.draft = "/re"
        case "bars-card-down":
            session.suggestionList.previewRoomBelow = 1000
            session.draft = "chr"
        case "bars-card-short-top", "bars-card-short", "bars-card-short-end":
            session.suggestionList.previewRoomBelow = shortCardRoom
            session.draft = "c"
            let steps = switch name {
            case "bars-card-short": 4
            case "bars-card-short-end": session.matchCardRows.count - 1
            default: 0
            }
            for _ in 0..<steps { _ = session.chooseInFooter(by: 1) }
        case "bars-card-up":
            session.taskLinks = Array(links.prefix(3))
            session.suggestionList.previewRoomBelow = 0
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

    /// Made-up task links on example.com. A preview never opens them.
    static let links = [
        TaskLink(label: "PR #12", url: "https://example.com/pull/12"),
        TaskLink(label: "Mock: input pill", url: "https://example.com/mock/input-pill"),
        TaskLink(label: "TASK-123", url: "https://example.com/task/123"),
        TaskLink(label: "Spec", url: "https://example.com/spec"),
        TaskLink(label: "Storybook", url: "https://example.com/storybook"),
    ]

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
            ThreadEntry(date: now.addingTimeInterval(-115), item: reply("For the whole Mac or just this panel?")),
            ThreadEntry(date: now.addingTimeInterval(-60), item: .userMessage(text: "dark mode")),
            ThreadEntry(date: now.addingTimeInterval(-55), item: reply("Done. The panel is dark now.")),
        ]
    }

    /// A long reply and a short one, with a pause of over half an hour between them, so the
    /// second stretch has a time label. It starts with an episode marker, so the pause does not
    /// start a new episode, as with a longer episode timeout. The people and plans are made up.
    static func layoutThread() -> [ThreadEntry] {
        let now = Date()
        func reply(_ text: String) -> ThreadItem {
            .assistantMessage(.init(text: text, provider: "openai", model: "gpt-6-luna"))
        }
        return [
            ThreadEntry(date: now.addingTimeInterval(-7210), item: .episodeStart(.init(reason: .requested))),
            ThreadEntry(date: now.addingTimeInterval(-7200), item: .userMessage(text: "what's on my calendar tomorrow")),
            ThreadEntry(date: now.addingTimeInterval(-7195), item: reply(
                "Tomorrow has three things:\n\n- 9:00 Standup with the design team\n- 12:30 Lunch with Alex Example\n- 16:00 Dentist, about 40 minutes away\n\nThe dentist is the only one with travel. I can remind you to leave at 15:15.")),
            ThreadEntry(date: now.addingTimeInterval(-600), item: .userMessage(text: "yes please, and turn on dark mode")),
            ThreadEntry(date: now.addingTimeInterval(-595), item: reply("Done. Both are set.")),
        ]
    }

    /// An exchange at the start of `layoutThread`'s episode, long enough that with it the
    /// conversation no longer fits the panel. The plans are made up.
    static func earlierThread() -> [ThreadEntry] {
        let now = Date()
        func reply(_ text: String) -> ThreadItem {
            .assistantMessage(.init(text: text, provider: "openai", model: "gpt-6-luna"))
        }
        return [
            ThreadEntry(date: now.addingTimeInterval(-7208), item: .userMessage(text: "what did I miss in the team channel")),
            ThreadEntry(date: now.addingTimeInterval(-7205), item: reply(
                "Three threads since yesterday:\n\n- The launch moved to Thursday\n- Sam Example asked for review on the onboarding copy\n- The offsite poll closes at noon\n\nThe review request mentions you by name, so it is likely the one to answer first.")),
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
