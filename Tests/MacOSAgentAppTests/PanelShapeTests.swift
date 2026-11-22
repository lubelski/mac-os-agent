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
        #expect(layer.maskedCorners == [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner])
        let radii = PanelShape.surface.cornerRadii
        #expect([radii.topLeading, radii.bottomLeading, radii.topTrailing, radii.bottomTrailing]
            .allSatisfy { $0 == PanelShape.cornerRadius })
        #expect(PanelShape.surface.style == .continuous)
    }

    /// Against the left edge the left corners are square and the right ones rounded, on the
    /// surface and on the layer clip alike, and the mirror at the right edge.
    @Test(arguments: PanelEdge.allCases)
    func aSideAgainstTheEdgeHasSquareCorners(_ edge: PanelEdge) throws {
        let surface = PanelShape.surface(squareEdges: [edge])
        let radii = surface.cornerRadii
        let left = [radii.topLeading, radii.bottomLeading]
        let right = [radii.topTrailing, radii.bottomTrailing]
        #expect((edge == .left ? left : right) == [0, 0])
        #expect((edge == .left ? right : left) == [PanelShape.cornerRadius, PanelShape.cornerRadius])
        #expect(surface.style == .continuous)

        let layer = CALayer()
        PanelShape.clipToSurface(layer, squareEdges: [edge])
        #expect(layer.masksToBounds)
        #expect(layer.cornerRadius == PanelShape.cornerRadius)
        #expect(layer.cornerCurve == .continuous)
        let leftCorners: CACornerMask = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        let rightCorners: CACornerMask = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        #expect(layer.maskedCorners == (edge == .left ? rightCorners : leftCorners))
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
                Color.clear.frame(height: PanelTopBar.height).background(PanelBarFill())
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
            .background(PanelBarFill())
            }
            .frame(width: 640)
            .foregroundStyle(palette.primary)
            // The window clips its content to the surface's shape, as here.
            .clipShape(PanelShape.surface)
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

/// Renders a stand-in screen with the panel in slide over, flush against the left or the right
/// edge below the menu bar, in light and dark, and the same panel dragged off its edge with its
/// four rounded corners back, for a pull request when screen capture is not available. Run with
/// MAC_OS_AGENT_RENDER_DOCKED set to a folder. Liquid Glass is not drawn offscreen, so the
/// surface is the theme's solid fallback fill. The screen is drawn at half size, and the menu
/// bar and the desktop are plain stand-ins.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_DOCKED"] != nil))
struct DockedPanelRenders {
    /// A 1512 by 982 laptop screen at half size, with a 33 point menu bar.
    private let screen = CGSize(width: 756, height: 491)
    private let menuBar: CGFloat = 16.5

    private func write(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let data = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }

    private func content(_ session: AgentSession, palette: PanelPalette) -> some View {
        let rows = Array(session.transcript.rows.suffix(4))
        return VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: PanelTopBar.height).background(PanelBarFill())
            PanelDivider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(rows) { row in RowView(row: row, now: Date()) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Spacer(minLength: 0)
            PanelDivider()
            HStack(spacing: 10) {
                Text(verbatim: Mark.prompt).font(.system(size: 17, design: .monospaced)).foregroundStyle(.secondary)
                Text(verbatim: "Tell your Mac what to do").font(.system(size: 15)).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(PanelBarFill())
        }
        .foregroundStyle(palette.primary)
        .environment(\.panelPalette, palette)
    }

    /// The stand-in screen with the panel at `frame`, in the screen's points, y down from the top.
    private func screen(
        _ session: AgentSession, palette: PanelPalette, scheme: ColorScheme, frame: CGRect, squareEdges: Set<PanelEdge>
    ) -> some View {
        let scale: CGFloat = 0.5
        return ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.16, green: 0.2, blue: 0.32), Color(red: 0.34, green: 0.22, blue: 0.3)]
                    : [Color(red: 0.55, green: 0.7, blue: 0.86), Color(red: 0.86, green: 0.7, blue: 0.62)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle()
                .fill(scheme == .dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))
                .frame(height: menuBar)
            content(session, palette: palette)
                .frame(width: frame.width, height: frame.height)
                .clipShape(PanelShape.surface(squareEdges: squareEdges))
                .panelSurface(palette, incognito: false, squareEdges: squareEdges)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: frame.minX * scale, y: menuBar + frame.minY * scale)
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, scheme)
    }

    @Test func rendersTheDockedPanelAtEachEdge() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_DOCKED"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try #require(PanelPreview.session(named: "confirmation"))
        let theme = try #require(BuiltInThemes.all.first { $0.id == "glass" }?.theme)
        // The laptop's visible area, in points, with y down from below the menu bar.
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        for scheme in [ColorScheme.dark, .light] {
            let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
            let name = scheme == .dark ? "dark" : "light"
            for edge in PanelEdge.allCases {
                let frame = PanelGeometry.slideOverFrame(edge, width: 640, minimumWidth: 440, in: visible)
                let edges = PanelGeometry.flushEdges(of: frame, in: visible)
                try write(
                    screen(session, palette: palette, scheme: scheme, frame: frame, squareEdges: edges),
                    to: folder.appending(path: "docked-\(edge.rawValue)-\(name).png"))
            }
            // Before: floating 10 points in from the left edge with four rounded corners.
            let before = CGRect(x: 10, y: 10, width: 640, height: 929)
            try write(
                screen(session, palette: palette, scheme: scheme, frame: before, squareEdges: []),
                to: folder.appending(path: "before-left-\(name).png"))
            // Dragged 60 points off the left edge, and resized shorter: four rounded corners again.
            let dragged = CGRect(x: 60, y: 60, width: 640, height: 760)
            try write(
                screen(session, palette: palette, scheme: scheme, frame: dragged,
                       squareEdges: PanelGeometry.flushEdges(of: dragged, in: visible)),
                to: folder.appending(path: "dragged-off-\(name).png"))
        }
    }
}
