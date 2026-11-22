import Foundation
import MacOSAgentCore

/// Stand-in states for the instant action row, for screenshots: one match, and several to
/// choose between. They use a made-up list of apps, so nothing reads the real ones.
@MainActor
enum InstantActionPreview {
    static let names = ["instant-one", "instant-several"]

    static func session(named name: String) -> AgentSession? {
        let draft: String
        switch name {
        case "instant-one": draft = "open safari"
        case "instant-several": draft = "cal"
        default: return nil
        }
        var thread = PanelPreview.StandInThread(now: Date())
        thread.earlierExchanges()
        let session = AgentSession(previewEntries: thread.entries)
        session.instantActions = InstantActions(applications: applications)
        session.draft = draft
        return session
    }

    static let applications: [InstalledApplication] = [
        ("Safari", "com.apple.Safari"), ("Safari Technology Preview", "com.apple.SafariTechnologyPreview"),
        ("Calendar", "com.apple.iCal"), ("Calculator", "com.apple.calculator"), ("Notion Calendar", "com.cron.electron"),
        ("Slack", "com.tinyspeck.slackmacgap"), ("Spotify", "com.spotify.client"), ("Xcode", "com.apple.dt.Xcode"),
    ].map { name, identifier in
        InstalledApplication(name: name, bundleIdentifier: identifier,
                             url: URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory))
    }
}
