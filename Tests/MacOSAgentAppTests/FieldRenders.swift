import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Renders the text field's states offscreen, for a pull request when screen capture is not
/// available: the idle field with its sparkle, with the suggestions experiment off and on, a
/// running task with the working row and Stop at the end of the thread, in the main panel and
/// the incognito window, and the experiment showing an app's icon in the field's slot. Run with
/// MAC_OS_AGENT_RENDER_FIELD set to a folder. See `PanelBarDrawing` for what is not drawn.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_FIELD"] != nil))
struct FieldRenders {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_FIELD"] ?? "/tmp", directoryHint: .isDirectory)

    private func runningIncognito() -> AgentSession {
        var thread = PanelPreview.StandInThread(now: Date())
        thread.user("how much space is left on the disk", minutesAgo: 1)
        let running = thread.tool("df -h /", output: nil)
        return AgentSession(previewEntries: thread.entries, isRunning: true, runningCallIDs: [running], incognito: true)
    }

    @Test func rendersTheFieldsStates() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let states: [(String, () throws -> AgentSession)] = [
            ("idle-experiment-off", { try PanelBarDrawing.session("finished", experiment: false) }),
            ("idle-experiment-on", { try PanelBarDrawing.session("footer-idle", experiment: true) }),
            ("running-experiment-off", { try PanelBarDrawing.session("running", experiment: false) }),
            ("running-experiment-on", { try PanelBarDrawing.session("running", experiment: true) }),
            ("running-incognito", { runningIncognito() }),
            ("app-icon-experiment-on", { try PanelBarDrawing.session("footer-typing", experiment: true) }),
        ]
        for (name, make) in states {
            for (theme, dark) in [("glass", false), ("glass", true)] {
                let model = try PanelBarDrawing.model(theme)
                let bitmap = try PanelBarDrawing.draw(PanelBarDrawing.panel(try make(), model: model), dark: dark)
                try #require(bitmap.representation(using: .png, properties: [:]))
                    .write(to: folder.appending(path: "field-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}
