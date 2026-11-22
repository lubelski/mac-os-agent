import AppKit
import MacOSAgentCore
import SwiftUI

/// Stand-in panel states for screenshots. `--preview-panel <name>` shows one of them in the
/// real panel instead of starting the agent. Screen capture of the window then shows it with
/// its Liquid Glass, which an offscreen render does not draw.
@MainActor
enum PanelPreview {
    static let names = ["empty", "running", "confirmation", "finished"]

    static func session(named name: String) -> AgentSession? {
        let states: [(String, AgentSession)] = [
            ("empty", AgentSession(previewRows: [])),
            ("running", AgentSession(
                previewRows: [
                    ExchangeRow(id: "1", kind: .user("change the wallpaper to a sunset")),
                    ExchangeRow(id: "2", kind: .tool(
                        command: "mdfind -onlyin /System/Library/Desktop\\ Pictures 'kMDItemDisplayName == \"*Sunset*\"c'",
                        status: .finished,
                        output: "/System/Library/Desktop Pictures/Sunset.heic\n[exit status 0]")),
                    ExchangeRow(id: "3", kind: .tool(
                        command: "osascript -e 'tell application \"System Events\" to tell every desktop to set picture to \"/System/Library/Desktop Pictures/Sunset.heic\"'",
                        status: .running,
                        output: nil)),
                ],
                isRunning: true)),
            ("confirmation", AgentSession(
                previewRows: [
                    ExchangeRow(id: "1", kind: .user("delete zoom")),
                    ExchangeRow(id: "2", kind: .tool(
                        command: "mdfind \"kMDItemCFBundleIdentifier == 'us.zoom.xos'\"",
                        status: .finished,
                        output: "/Applications/zoom.us.app\n[exit status 0]")),
                    ExchangeRow(id: "3", kind: .tool(
                        command: "osascript -e 'tell application \"Finder\" to delete POSIX file \"/Applications/zoom.us.app\"'",
                        status: .waitingForConfirmation,
                        output: nil)),
                ],
                pendingConfirmation: ConfirmationRequest(
                    callID: "3",
                    command: "osascript -e 'tell application \"Finder\" to delete POSIX file \"/Applications/zoom.us.app\"'",
                    reason: "scripts an app to delete or quit"),
                isRunning: true)),
            ("finished", AgentSession(previewRows: [
                ExchangeRow(id: "1", kind: .user("change the wallpaper to a sunset")),
                ExchangeRow(id: "2", kind: .tool(
                    command: "osascript -e 'tell application \"System Events\" to tell every desktop to set picture to \"/System/Library/Desktop Pictures/Sunset.heic\"'",
                    status: .finished,
                    output: "[exit status 0]")),
                ExchangeRow(id: "3", kind: .assistant("Done. Every desktop now shows the Sunset picture from the system wallpapers.")),
            ])),
        ]
        return Dictionary(uniqueKeysWithValues: states)[name]
    }
}
