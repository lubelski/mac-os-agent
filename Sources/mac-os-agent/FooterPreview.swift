import Foundation
import MacOSAgentCore

/// Stand-in states for the suggestions-in-the-field experiment, for screenshots and tests: the
/// footer with an empty field, "chr" with a match, "c" alone with its match, the list open,
/// and the slash list. The
/// experiment is on for these sessions only, without touching the preferences, and they use
/// made-up apps and actions, so nothing reads the real ones.
@MainActor
enum FooterPreview {
    static let names = ["footer-idle", "footer-typing", "footer-one-character", "footer-list", "footer-slash", "footer-incognito"]

    static func session(named name: String) -> AgentSession? {
        guard names.contains(name) else { return nil }
        let session = AgentSession(previewEntries: thread(), incognito: name == "footer-incognito")
        configure(session)
        switch name {
        case "footer-typing", "footer-incognito":
            session.draft = "chr"
        case "footer-one-character":
            session.draft = "c"
        case "footer-list":
            session.draft = "chr"
            _ = session.chooseInFooter(by: 1)
            _ = session.chooseInFooter(by: 1)
        case "footer-slash":
            session.skillCommands = SkillCommandsModel(menu: skills)
            session.draft = "/re"
        default:
            break
        }
        return session
    }

    /// Turns the experiment on for a session, with the stand-in apps and, in the main panel,
    /// the stand-in actions.
    static func configure(_ session: AgentSession) {
        session.suggestionList.forcedOn = true
        // The incognito window learns nothing, as its real instant actions do not.
        session.instantActions = InstantActions(applications: applications, learns: !session.isIncognito, history: history)
        if !session.isIncognito { session.instantActions.setActions(actions) }
    }

    /// What a stand-in owner has learned: they open Google Chrome with "chr", so it leads
    /// the quick action whose name starts with "Chr", as on the wireframe.
    static var history: InstantActionHistory {
        var history = InstantActionHistory()
        let chrome = ApplicationInstantActions.id(for: applications[0])
        for days in [1.0, 2, 3] { history.record(chrome, subject: "chr", at: Date().addingTimeInterval(-86_400 * days)) }
        return history
    }

    /// The short exchange from the wireframe.
    static func thread() -> [ThreadEntry] {
        let now = Date()
        return [
            ThreadEntry(date: now.addingTimeInterval(-60), item: .userMessage(text: "light mode")),
            ThreadEntry(date: now.addingTimeInterval(-55), item: .assistantMessage(.init(
                text: "For the whole Mac or just the Iris panel?", provider: "openai", model: "gpt-6-luna"))),
        ]
    }

    static let skills = SlashCommandMenu(skills: [
        SkillCommand(name: "rename-photos", description: "Renames photos in a folder by the date they were taken.", folderName: "rename-photos"),
        SkillCommand(name: "resize-images", description: "Resizes images to a width, keeping the originals.", folderName: "resize-images"),
        SkillCommand(name: "tidy-downloads", description: "Moves old files in Downloads to the Trash, after asking.", folderName: "tidy-downloads"),
    ])

    static let actions: [QuickAction] = [
        QuickAction(
            id: "chrome-incognito", name: "Chrome Incognito Window", description: "Opens a private Chrome window.",
            steps: [.init(tool: "run_shell_command", arguments: ["command": "open -na 'Google Chrome' --args --incognito", "destructive": false])]),
    ]

    static let applications: [InstalledApplication] = [
        ("Google Chrome", "com.google.Chrome"), ("Google Chrome Canary", "com.google.Chrome.canary"),
        ("ChatGPT", "com.openai.chat"), ("Chess", "com.apple.Chess"), ("Safari", "com.apple.Safari"),
        ("Calendar", "com.apple.iCal"), ("Calculator", "com.apple.calculator"), ("Notion Calendar", "com.cron.electron"),
        ("Xcode", "com.apple.dt.Xcode"),
    ].map { name, identifier in
        InstalledApplication(name: name, bundleIdentifier: identifier,
                             url: URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory))
    }
}
