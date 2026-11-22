import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

@MainActor
struct PanelShapeTests {
    /// The layer clip and the surface must be the same shape, or a faint square outline of the
    /// window shows at the corners.
    @Test func theClipAndTheSurfaceAreTheSameShape() throws {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        SummonPanel.giveRoundedShape(to: view)
        let layer = try #require(view.layer)
        #expect(layer.masksToBounds)
        #expect(layer.cornerRadius == PanelShape.cornerRadius)
        #expect(layer.cornerCurve == .continuous)
        #expect(PanelShape.surface.cornerSize == CGSize(width: PanelShape.cornerRadius, height: PanelShape.cornerRadius))
        #expect(PanelShape.surface.style == .continuous)
    }

    /// The inspector's window takes the same clip as the panel.
    @Test func theInspectorHasThePanelsCorners() throws {
        let session = try #require(PanelPreview.session(named: "empty"))
        let window = ToolInspectorWindow(inspector: ToolInspector(), session: session, defaults: nil)
        let host = try #require(window.contentView?.subviews.first)
        #expect(host.layer?.cornerRadius == PanelShape.cornerRadius)
        #expect(host.layer?.cornerCurve == .continuous)
    }

    /// An inner shape is never rounder than the one that holds it.
    @Test func theRadiiStepDownFromTheOutsideIn() {
        #expect(PanelShape.cornerRadius > PanelShape.cardCornerRadius)
        #expect(PanelShape.cardCornerRadius > PanelShape.messageCornerRadius)
        #expect(PanelShape.messageCornerRadius > PanelShape.controlCornerRadius)
        #expect(ThemeSample.cornerRadius > ThemeSample.panelCornerRadius)
        #expect(ThemeSample.panelCornerRadius > ThemeSample.messageCornerRadius)
    }
}

/// Renders the panel's surface with a conversation and a go-ahead card on it, and a theme's
/// sample from Settings, offscreen, for a pull request when screen capture is not available.
/// Run with MAC_OS_AGENT_RENDER_SHAPE set to a folder. Liquid Glass is not drawn offscreen, so
/// the surface is the theme's solid fallback fill, over a plain backdrop that shows the corners.
/// The top bar is left empty.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SHAPE"] != nil))
struct PanelShapeRenders {
    private func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    @Test func rendersThePanelsCornersAndTheShapesInside() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_SHAPE"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try #require(PanelPreview.session(named: "confirmation"))
        let request = try #require(session.pendingConfirmation)
        let rows = Array(session.transcript.rows.suffix(5))
        let theme = try #require(BuiltInThemes.all.first { $0.id == "glass" }?.theme)
        for scheme in [ColorScheme.dark, .light] {
            let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
            let panel = VStack(alignment: .leading, spacing: 0) {
                // The top bar's drag area is an AppKit view, which is not drawn offscreen.
                Color.clear.frame(height: PanelTopBar.height)
                PanelDivider()
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows) { row in RowView(row: row, now: Date()) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                ConfirmationCard(request: request, session: session)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                PanelDivider()
                HStack(spacing: 10) {
                    Text(verbatim: Mark.prompt).font(.system(size: 17, design: .monospaced)).foregroundStyle(.secondary)
                    Text(verbatim: "Tell your Mac what to do").font(.system(size: 15)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .frame(width: 640)
            .foregroundStyle(palette.primary)
            .panelSurface(palette, incognito: false)
            .environment(\.panelPalette, palette)
            .environment(\.pendingGoAhead, request)
            .padding(24)
            .background(scheme == .dark ? Color(white: 0.45) : Color(white: 0.6))
            .environment(\.colorScheme, scheme)
            try write(panel, to: folder.appending(path: "panel-\(scheme == .dark ? "dark" : "light").png"))
        }
        let sample = ThemeSample(theme: theme, dark: true, allowsGlass: false)
            .frame(width: 200)
            .padding(12)
            .background(Color(white: 0.15))
        try write(sample, to: folder.appending(path: "theme-sample-dark.png"))
    }
}
