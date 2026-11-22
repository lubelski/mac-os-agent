import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Draws the real conversation window or inspector offscreen, hosted in a borderless window
/// that never goes on screen, with a theme model of its own whose themes folder is empty and
/// temporary, never the owner's. Liquid Glass and blur are not drawn offscreen, so Use Glass is
/// off and every theme draws on its fallback fill.
@MainActor
enum PanelBarDrawing {
    static let size = CGSize(width: 560, height: 420)
    static let margin: CGFloat = 20

    static func model(_ themeID: String) throws -> ThemeModel {
        let themes = FileManager.default.temporaryDirectory
            .appending(path: "mac-os-agent-bar-renders-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        let model = ThemeModel(
            library: ThemeLibrary(folder: themes),
            preferences: ThemePreferences(suiteName: "mac-os-agent-bar-renders-\(UUID().uuidString)"))
        model.previewOverride = try #require(BuiltInThemes.all.first { $0.id == themeID }?.theme)
        model.previewUsesGlass = false
        return model
    }

    /// Hosts `view` in a borderless window of its own with the panel's layer clip and draws it
    /// over a plain backdrop that shows the corners, `margin` points around it.
    static func draw(
        _ view: some View, dark: Bool, squareEdges: Set<PanelEdge> = [], size: CGSize = size
    ) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let outer = NSRect(x: 0, y: 0, width: size.width + margin * 2, height: size.height + margin * 2)
        let window = NSWindow(contentRect: outer, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let container = NSView(frame: outer)
        container.wantsLayer = true
        container.layer?.backgroundColor = backdrop(dark: dark).cgColor
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
        container.addSubview(host)
        window.contentView = container
        // The panel's layer clip, as the window has it. Drawing for a cache ignores which
        // corners a layer masks and rounds all four, so a panel with square corners is drawn
        // with an unrounded clip, and its shape is the surface's own clip in SwiftUI.
        SummonPanel.giveRoundedShape(to: host)
        if !squareEdges.isEmpty { host.layer?.cornerRadius = 0 }
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        container.layoutSubtreeIfNeeded()
        container.display()
        let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: bitmap)
        return bitmap
    }

    static func backdrop(dark: Bool) -> NSColor {
        NSColor(srgbRed: dark ? 0.3 : 0.86, green: dark ? 0.3 : 0.86, blue: dark ? 0.3 : 0.86, alpha: 1)
    }

    static func panel(_ session: AgentSession, model: ThemeModel, placement: PanelPlacement = PanelPlacement()) -> some View {
        SummonView(session: session)
            .environment(placement)
            .environment(ToolInspector())
            .environment(model)
    }

    static func session(_ name: String, experiment: Bool) throws -> AgentSession {
        let session = try #require(PanelPreview.session(named: name))
        session.suggestionList.forcedOn = experiment
        session.syncInstantActionMode()
        return session
    }
}

/// Renders the real conversation window and the real inspector offscreen, for a pull request
/// when screen capture is not available: each built-in theme in each of its appearances, with
/// the suggestions experiment off and on, a running task with its Stop button, the incognito
/// window, the panel flush against the left edge with its square corners, the inspector, and
/// the theme samples in Settings. Run with MAC_OS_AGENT_RENDER_BARS set to a folder. See
/// `PanelBarDrawing` for what is not drawn.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_BARS"] != nil))
struct PanelBarRenders {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_BARS"] ?? "/tmp", directoryHint: .isDirectory)

    private func model(_ themeID: String) throws -> ThemeModel { try PanelBarDrawing.model(themeID) }
    private func panel(_ session: AgentSession, model: ThemeModel, placement: PanelPlacement = PanelPlacement()) -> some View {
        PanelBarDrawing.panel(session, model: model, placement: placement)
    }
    private func session(_ name: String, experiment: Bool) throws -> AgentSession {
        try PanelBarDrawing.session(name, experiment: experiment)
    }

    private func render(
        _ view: some View, dark: Bool, squareEdges: Set<PanelEdge> = [], size: CGSize = PanelBarDrawing.size, name: String
    ) throws {
        let bitmap = try PanelBarDrawing.draw(view, dark: dark, squareEdges: squareEdges, size: size)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appending(path: "\(name).png"))
    }

    @Test func rendersEachThemeWithTheExperimentOffAndOn() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for entry in BuiltInThemes.all {
            let theme = try #require(entry.theme)
            let model = try model(entry.id)
            for (kind, _) in theme.appearances {
                for experiment in [false, true] {
                    try render(
                        panel(try session("footer-typing", experiment: experiment), model: model), dark: kind.isDark,
                        name: "panel-\(entry.id)-\(kind.rawValue)-experiment-\(experiment ? "on" : "off")")
                }
            }
        }
    }

    @Test func rendersARunningTaskTheIncognitoWindowAndTheList() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for id in ["glass", "paper", "tidewater"] {
            let model = try model(id)
            let dark = id == "tidewater"
            try render(panel(try session("running", experiment: false), model: model), dark: dark, name: "running-\(id)")
            try render(panel(try session("footer-incognito", experiment: true), model: model), dark: dark, name: "incognito-\(id)")
            let hovered = PanelPlacement()
            hovered.barIsHovered = true
            hovered.keepsOnTop = true
            try render(panel(try session("footer-list", experiment: true), model: model, placement: hovered), dark: dark, name: "hovered-bar-list-\(id)")
        }
    }

    @Test func rendersThePanelFlushAgainstTheLeftEdge() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (id, dark) in [("glass", true), ("glass", false), ("paper", false)] {
            let placement = PanelPlacement()
            placement.preset = .slideOverLeft
            placement.visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: PanelBarDrawing.size.height)
            placement.panelFrame = CGRect(x: 0, y: 0, width: PanelBarDrawing.size.width, height: PanelBarDrawing.size.height)
            try render(
                panel(try session("footer-typing", experiment: true), model: try model(id), placement: placement), dark: dark,
                squareEdges: placement.squareEdges, name: "docked-left-\(id)-\(dark ? "dark" : "light")")
        }
    }

    @Test func rendersTheInspector() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let session = try #require(PanelPreview.session(named: "inspector-fields"))
        let inspector = ToolInspector()
        inspector.callIDs = { session.transcript.toolCallIDs }
        inspector.open(try #require(session.transcript.toolCallIDs.last))
        for (id, dark) in [("glass", true), ("glass", false), ("paper", false), ("tidewater", true)] {
            let view = ToolInspectorView(session: session).environment(inspector).environment(try model(id))
            try render(view, dark: dark, size: CGSize(width: 420, height: 360), name: "inspector-\(id)-\(dark ? "dark" : "light")")
        }
    }

    /// The small panels Settings, Appearance draws for each theme, with Use Glass off.
    @Test func rendersTheThemeSamples() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let samples = VStack(alignment: .leading, spacing: 12) {
            ForEach(BuiltInThemes.all, id: \.id) { entry in
                HStack(spacing: 12) {
                    ForEach(entry.theme!.appearances, id: \.kind) { kind, _ in
                        ThemeSample(theme: entry.theme!, dark: kind.isDark, allowsGlass: false).frame(width: 200)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(white: 0.5))
        let renderer = ImageRenderer(content: samples)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            .write(to: folder.appending(path: "theme-samples.png"))
    }
}

/// The top bar, the band with the text field, the footer, and the inspector's bar all draw the
/// one bars' fill, the conversation keeps the surface, and nothing is drawn past a rounded
/// corner. Checked on pixels of the real window drawn offscreen, for a light and a dark theme.
@MainActor
@Suite(.serialized) struct PanelBarFillTests {
    /// The color at a point of the drawing, in points from its top left.
    private func color(_ bitmap: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> [Double] {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let color = bitmap.colorAt(x: Int((x * scale).rounded()), y: Int((y * scale).rounded()))!
        let rgb = color.usingColorSpace(.sRGB)!
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { ($0 * 255).rounded() }
    }

    private func same(_ a: [Double], _ b: [Double]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= 1 } }

    @Test(arguments: [("paper", false), ("graphite", true)])
    func theBarsShareOneFillAndTheConversationKeepsTheSurface(theme: String, dark: Bool) throws {
        let model = try PanelBarDrawing.model(theme)
        let margin = PanelBarDrawing.margin
        let size = PanelBarDrawing.size
        for experiment in [false, true] {
            let session = try PanelBarDrawing.session(experiment ? "footer-typing" : "running", experiment: experiment)
            let bitmap = try PanelBarDrawing.draw(PanelBarDrawing.panel(session, model: model), dark: dark)
            let topBar = color(bitmap, margin + 120, margin + 3)
            let conversation = color(bitmap, margin + 120, margin + 60)
            // Below the field's text, in the band's bottom padding, or in the footer's middle.
            let band = color(bitmap, margin + 300, margin + size.height - (experiment ? 26 + 4 : 4))
            let corner = color(bitmap, margin + 1, margin + 1)
            #expect(same(topBar, band), "\(theme) experiment \(experiment): top bar \(topBar), band \(band)")
            #expect(!same(topBar, conversation), "\(theme) experiment \(experiment): the bar is offset from the surface \(conversation)")
            #expect(same(corner, color(bitmap, 2, 2)), "\(theme): nothing past the rounded corner")
            if experiment {
                let footer = color(bitmap, margin + size.width / 2, margin + size.height - 4)
                #expect(same(footer, band), "\(theme): the footer continues the band")
            }
        }

        let inspectorSession = try #require(PanelPreview.session(named: "inspector-fields"))
        let inspector = ToolInspector()
        inspector.callIDs = { inspectorSession.transcript.toolCallIDs }
        inspector.open(try #require(inspectorSession.transcript.toolCallIDs.last))
        let drawn = try PanelBarDrawing.draw(
            ToolInspectorView(session: inspectorSession).environment(inspector).environment(model), dark: dark,
            size: CGSize(width: 420, height: 360))
        let panel = try PanelBarDrawing.draw(
            PanelBarDrawing.panel(try PanelBarDrawing.session("footer-typing", experiment: false), model: model), dark: dark)
        #expect(same(color(drawn, margin + 200, margin + 3), color(panel, margin + 120, margin + 3)), "\(theme): the inspector's bar matches the panel's")
        #expect(same(color(drawn, margin + 300, margin + 36), color(panel, margin + 120, margin + 60)), "\(theme): the inspector's body keeps the surface")
    }

    /// The palette's bars' fill is the theme's own when it sets one.
    @Test func aThemesOwnBarIsUsed() throws {
        var theme = try #require(BuiltInThemes.all.first { $0.id == "paper" }?.theme)
        theme.light?.bar = .hex(red: 0x2F, green: 0x5D, blue: 0x8A, alpha: 0x40)
        let palette = PanelPalette(theme: theme, dark: false)
        let derived = PanelPalette(theme: BuiltInThemes.all.first { $0.id == "paper" }!.theme!, dark: false)
        func drawn(_ palette: PanelPalette) throws -> [Double] {
            let renderer = ImageRenderer(content: PanelBarFill().environment(\.panelPalette, palette).frame(width: 4, height: 4).background(Color.white))
            let image = try #require(renderer.cgImage)
            let rep = NSBitmapImageRep(cgImage: image)
            return color(rep, 2, 2)
        }
        // #2F5D8A at a quarter over white is a clear blue. Paper's primary text at 3 percent
        // over white is a gray a few levels below white.
        let own = try drawn(palette)
        let fallback = try drawn(derived)
        #expect(own[2] - own[0] > 15, "\(own)")
        #expect(fallback.allSatisfy { (244...253).contains($0) }, "\(fallback)")
    }
}
