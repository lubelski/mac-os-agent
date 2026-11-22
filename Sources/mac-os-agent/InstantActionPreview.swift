import Foundation
import MacOSAgentCore

/// Stand-in states for the instant action row, for screenshots: one match, and several to
/// choose between. They use a made-up list of apps, so nothing reads the real ones.
@MainActor
enum InstantActionPreview {
    static let names = ["instant-one", "instant-several", "instant-action", "instant-action-beside-apps"]

    static func session(named name: String) -> AgentSession? {
        let draft: String
        switch name {
        case "instant-one": draft = "open safari"
        case "instant-several": draft = "cal"
        case "instant-action": draft = "screensaver"
        case "instant-action-beside-apps": draft = "spot"
        default: return nil
        }
        var thread = PanelPreview.StandInThread(now: Date())
        thread.earlierExchanges()
        let session = AgentSession(previewEntries: thread.entries)
        session.instantActions = InstantActions(applications: applications)
        if name.hasPrefix("instant-action") { session.instantActions.setActions(actions) }
        session.draft = draft
        return session
    }

    /// Stand-in quick actions, never read from the quick actions folder.
    static let actions: [QuickAction] = [
        QuickAction(
            id: "start-screensaver", name: "Start Screensaver", description: "Starts the screen saver.",
            phrases: ["screensaver", "screen saver"],
            steps: [.init(tool: "open_application", arguments: ["bundle_identifier_or_path": "/System/Library/CoreServices/ScreenSaverEngine.app"])]),
        QuickAction(
            id: "spotify-focus", name: "Spotify Focus", description: "Opens Spotify and hides the other apps.",
            steps: [
                .init(tool: "open_application", arguments: ["bundle_identifier_or_path": "com.spotify.client"]),
                .init(tool: "run_shell_command", arguments: ["command": "osascript -e 'tell application \"System Events\" to set visible of every process whose frontmost is false to false'", "destructive": false]),
            ]),
    ]

    static let applications: [InstalledApplication] = [
        ("Safari", "com.apple.Safari"), ("Safari Technology Preview", "com.apple.SafariTechnologyPreview"),
        ("Calendar", "com.apple.iCal"), ("Calculator", "com.apple.calculator"), ("Notion Calendar", "com.cron.electron"),
        ("Slack", "com.tinyspeck.slackmacgap"), ("Spotify", "com.spotify.client"), ("Xcode", "com.apple.dt.Xcode"),
    ].map { name, identifier in
        InstalledApplication(name: name, bundleIdentifier: identifier,
                             url: URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory))
    }
}
