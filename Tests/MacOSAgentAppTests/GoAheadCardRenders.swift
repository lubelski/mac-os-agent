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
