import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Renders the go-ahead card and the waiting row above it offscreen, for a pull request when
/// screen capture is not available. Run with MAC_OS_AGENT_RENDER_GO_AHEAD set to a folder. The
/// Liquid Glass behind them is not drawn offscreen, so they sit on the theme's fallback fill.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_GO_AHEAD"] != nil))
struct GoAheadCardRenders {
    @Test func rendersTheCardForEachToolThatAsks() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_GO_AHEAD"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["confirmation"] + PanelPreview.goAheadStates {
            let session = try #require(PanelPreview.session(named: name))
            let request = try #require(session.pendingConfirmation)
            let rows = Array(session.transcript.rows.suffix(2))
            for scheme in [ColorScheme.dark, .light] {
                let theme = try #require(BuiltInThemes.all.first { $0.id == "glass" }?.theme)
                let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
                let view = VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in RowView(row: row, now: Date()) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    ConfirmationCard(request: request, session: session)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                .frame(width: 640)
                .foregroundStyle(palette.primary)
                .background(palette.fallbackFill)
                .environment(\.panelPalette, palette)
                .environment(\.pendingGoAhead, request)
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.nsImage)
                let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
                try data.write(to: folder.appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}

/// Renders tool rows rebuilt from a saved thread offscreen, one per kind of tool, for a pull
/// request when screen capture is not available. Run with MAC_OS_AGENT_RENDER_ROWS set to a folder.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_ROWS"] != nil))
struct RebuiltRowRenders {
    static let calls: [(String, JSONValue, String)] = [
        (ShellCommandTool.name, ["command": "du -sh ~/Movies", "destructive": false], "38G\t/Users/owner/Movies\n[exit status 0]"),
        (OpenApplicationTool.name, ["bundle_identifier_or_path": "/Applications/Safari.app"], "Opened Safari. It is now in front."),
        (SearchHistoryTool.name, ["query": "dark mode", "limit": nil], "2 matches"),
        (ChangeRemindersTool.name, ["changes": [["id": "3f9a2c1b", "delete": true], ["id": "7c21d0e4", "delete": true]]], "The owner declined. Nothing was changed."),
        (ChangeEventsTool.name, ["changes": [["id": nil, "title": "Lunch with Sam", "start": "2026-11-21T12:00"]]], "Created a4be19f0 | Lunch with Sam"),
        (FindFilesTool.name, ["name": "receipt", "kind": "pdf", "folder": "~/Downloads", "content": nil], "3 files"),
        (QuitOrHideApplicationTool.name, ["application": "Safari", "action": "quit"], "Quit Safari (com.apple.Safari)."),
        (ChangeThemeTool.name, ["action": "save_and_apply", "theme_id": nil, "file": #"{"format": 1, "name": "Night Swim"}"#], "Saved and applied Night Swim."),
        (LoadSkillTool.name, ["name": "wallpaper"], "# Wallpaper"),
    ]

    @Test func rendersRowsRebuiltFromTheThread() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_ROWS"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var entries = [ThreadEntry(date: Date(), item: .userMessage(text: "a bit of everything"))]
        for (index, call) in Self.calls.enumerated() {
            entries.append(ThreadEntry(date: Date(), item: .toolCall(.init(
                callID: "call_\(index)", name: call.0, arguments: call.1.encodedString(), provider: "openai", model: "gpt-6-luna"))))
            entries.append(ThreadEntry(date: Date(), item: .toolResult(.init(callID: "call_\(index)", output: call.2))))
        }
        let rows = Transcript(entries: entries).rows.filter(\.isTool)
        let theme = try #require(BuiltInThemes.all.first { $0.id == "glass" }?.theme)
        let palette = PanelPalette(theme: theme, dark: true, allowsGlass: false)
        let view = VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in RowView(row: row, now: Date()) }
        }
        .padding(16)
        .frame(width: 640, alignment: .leading)
        .foregroundStyle(palette.primary)
        .background(palette.fallbackFill)
        .environment(\.panelPalette, palette)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try data.write(to: folder.appending(path: "rebuilt-rows-dark.png"))
    }
}

/// Renders the top bar offscreen with Keep on Top off and on, in the main panel and the
/// incognito window, for a pull request when screen capture is not available. Run with
/// MAC_OS_AGENT_RENDER_TOP_BAR set to a folder. The glass is drawn as its fallback fill.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_TOP_BAR"] != nil))
struct TopBarRenders {
    @Test func rendersTheBarWithAndWithoutKeepOnTop() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_TOP_BAR"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let theme = try #require(BuiltInThemes.all.first { $0.id == "glass" }?.theme)
        PanelTopBar.hostsAppKitViews = false
        defer { PanelTopBar.hostsAppKitViews = true }
        for scheme in [ColorScheme.dark, .light] {
            let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
            func bar(keepsOnTop: Bool, incognito: Bool) -> some View {
                let placement = PanelPlacement()
                placement.keepsOnTop = keepsOnTop
                placement.offersLayouts = !incognito
                if !incognito { placement.setKeepsOnTop = { _ in } }
                return PanelTopBar(incognito: incognito ? .init(canClear: true, clear: {}) : nil)
                    .environment(placement)
                    .frame(width: 480)
                    .background(incognito ? palette.incognitoTint : .clear)
            }
            let view = VStack(spacing: 8) {
                bar(keepsOnTop: false, incognito: false)
                bar(keepsOnTop: true, incognito: false)
                bar(keepsOnTop: true, incognito: true)
            }
            .padding(8)
            .foregroundStyle(palette.primary)
            .background(palette.fallbackFill)
            .environment(\.panelPalette, palette)
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
            try data.write(to: folder.appending(path: "top-bar-\(scheme == .dark ? "dark" : "light").png"))
        }
    }
}
