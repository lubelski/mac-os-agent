import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Renders the real conversation window and the real inspector offscreen, hosted in windows
/// that never go on screen, for a pull request when screen capture is not available: each
/// built-in theme in each of its appearances, with the suggestions experiment off and on, a
/// running task with its Stop button, the incognito window, the panel flush against the left
/// edge with its square corners, and the inspector. Run with MAC_OS_AGENT_RENDER_BARS set to a
/// folder.
///
/// Liquid Glass and blur are not drawn offscreen, so Use Glass is off and every theme draws on
/// its fallback fill. The themes come from a model of the render's own, with an empty themes
/// folder, never the owner's.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_BARS"] != nil))
struct PanelBarRenders {
    init() { _ = NSApplication.shared }

    static let size = CGSize(width: 560, height: 420)
    static let margin: CGFloat = 20

    let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_BARS"] ?? "/tmp", directoryHint: .isDirectory)

    private func model(_ themeID: String) throws -> ThemeModel {
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

    /// Hosts `view` in a borderless window of its own with the panel's layer clip, draws it over
    /// a plain backdrop that shows the corners, and writes it.
    private func render(
        _ view: some View, dark: Bool, squareEdges: Set<PanelEdge> = [], size: CGSize = Self.size, name: String
    ) throws {
        let outer = NSRect(x: 0, y: 0, width: size.width + Self.margin * 2, height: size.height + Self.margin * 2)
        let window = NSWindow(contentRect: outer, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let container = NSView(frame: outer)
        container.wantsLayer = true
        container.layer?.backgroundColor = dark ? NSColor(white: 0.3, alpha: 1).cgColor : NSColor(white: 0.86, alpha: 1).cgColor
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: Self.margin, y: Self.margin, width: size.width, height: size.height)
        container.addSubview(host)
        window.contentView = container
        SummonPanel.giveRoundedShape(to: host)
        if let layer = host.layer { PanelShape.clipToSurface(layer, squareEdges: squareEdges) }
        container.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        container.layoutSubtreeIfNeeded()
        container.display()
        let bitmap = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: folder.appending(path: "\(name).png"))
        window.close()
    }

    private func panel(_ session: AgentSession, model: ThemeModel, placement: PanelPlacement = PanelPlacement()) -> some View {
        SummonView(session: session)
            .environment(placement)
            .environment(ToolInspector())
            .environment(model)
    }

    private func session(_ name: String, experiment: Bool) throws -> AgentSession {
        let session = try #require(PanelPreview.session(named: name))
        session.suggestionList.forcedOn = experiment
        session.syncInstantActionMode()
        return session
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
            placement.visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: Self.size.height)
            placement.panelFrame = CGRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height)
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
}
