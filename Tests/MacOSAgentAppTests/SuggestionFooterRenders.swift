import AppKit
import MacOSAgentCore
import SwiftUI
import Testing
@testable import mac_os_agent

/// Renders the suggestions-in-the-field experiment offscreen, for a pull request when screen
/// capture is not available: the empty field with its footer, "chr" with a match, "c" alone
/// with its match and, with the switch off, with nothing, the list
/// open below the field, the same list drawn over the conversation where the window has no room
/// to grow, the slash list, and the incognito window, in light and dark. Run with
/// MAC_OS_AGENT_RENDER_FOOTER set to a folder.
///
/// Liquid Glass is not drawn offscreen, so the surface is the theme's solid fill. The text field
/// is the real text view, drawn by AppKit into an image with its gray text, and the rest is the
/// panel's own views laid out as `SummonView` lays them out. The top bar is a stand-in.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_FOOTER"] != nil))
struct SuggestionFooterRenders {
    init() { _ = NSApplication.shared }

    static let width: CGFloat = 640
    static let historyHeight: CGFloat = 190

    struct State {
        var name: String
        var preview: String
        var overlay = false
        /// With the switch off, as before: the row above the field.
        var off = false
    }

    static let states = [
        State(name: "off-typing-chr", preview: "footer-typing", off: true),
        State(name: "idle", preview: "footer-idle"),
        State(name: "typing-chr", preview: "footer-typing"),
        State(name: "typing-one-character", preview: "footer-one-character"),
        State(name: "off-typing-one-character", preview: "footer-one-character", off: true),
        State(name: "list-below", preview: "footer-list"),
        State(name: "list-overlay", preview: "footer-list", overlay: true),
        State(name: "slash-list", preview: "footer-slash"),
        State(name: "incognito-typing", preview: "footer-incognito"),
    ]

    @Test func rendersEachState() throws {
        let folder = URL(filePath: ProcessInfo.processInfo.environment["MAC_OS_AGENT_RENDER_FOOTER"]!, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let theme = try #require(BuiltInThemes.all.first { $0.id == "glass" }?.theme)
        for state in Self.states {
            for scheme in [ColorScheme.light, .dark] {
                let session = try #require(PanelPreview.session(named: state.preview))
                if state.off {
                    session.suggestionList.forcedOn = false
                    session.syncInstantActionMode()
                }
                let palette = PanelPalette(theme: theme, dark: scheme == .dark, allowsGlass: false)
                let field = try Self.fieldImage(session: session, palette: palette, dark: scheme == .dark)
                let view = panel(session: session, field: field, overlay: state.overlay)
                    .frame(width: Self.width)
                    .foregroundStyle(palette.primary)
                    // The window clips its content to the surface's shape, as here.
                    .clipShape(PanelShape.surface)
                    .panelSurface(palette, incognito: session.isIncognito)
                    .environment(\.panelPalette, palette)
                    .padding(20)
                    .background(scheme == .dark ? Color(white: 0.3) : Color(white: 0.92))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: folder.appending(path: "footer-\(state.name)-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }

    /// The panel as `SummonView` lays it out with the experiment on. With `overlay`, the list
    /// covers the bottom of the conversation, as when the window has no room to grow.
    private func panel(session: AgentSession, field: NSImage, overlay: Bool) -> some View {
        let rows = session.suggestionRows
        let list = SuggestionListView(
            rows: rows, highlight: session.highlightedRowIndex, agentName: "Iris", incognito: session.isIncognito)
        let growth = overlay ? 0 : SuggestionListView.height(rowCount: SuggestionListView.visibleRows(rows.count))
        let off = !session.suggestionsInFooter
        return VStack(spacing: 0) {
            // The top bar's controls are AppKit views, which are not drawn offscreen.
            HStack {
                Spacer()
                Text(verbatim: session.isIncognito ? "Iris  Incognito" : "Iris").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: PanelTopBar.height)
            .background(PanelBarFill())
            PanelDivider()
            VStack(alignment: .leading, spacing: 10) {
                ForEach(session.transcript.rows.filter { !$0.isEpisodeStart }) { row in RowView(row: row, now: Date()) }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.bottom, HistoryView.bottomPadding)
            .frame(height: Self.historyHeight)
            .clipped()
            if off { InstantActionRow(actions: session.instantActions) }
            VStack(spacing: 0) {
                PanelDivider()
                HStack(alignment: .top, spacing: 10) {
                    InputMark(target: session.returnTarget)
                    Image(nsImage: field)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .overlay(alignment: .topLeading) {
                            // The placeholder, as the panel draws it over the empty field.
                            if session.draft.isEmpty {
                                Text(verbatim: "Tell your Mac what to do")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, InputField.verticalInset)
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(PanelBarFill())
            }
            .overlay(alignment: .top) {
                if overlay, !rows.isEmpty {
                    list.background(PanelBarFill(opaque: true)).offset(y: -session.suggestionListHeight)
                }
            }
            if growth > 0 {
                list.frame(height: growth, alignment: .top).background(PanelBarFill())
            }
            if !off {
                InputFooter(content: .make(
                    session.footerState, agentName: "Iris", modelName: "GPT-6 Luna",
                    recallsMessages: true, queuesWhileRunning: false))
            }
        }
    }

    /// The real text view with the session's draft and gray text, drawn by AppKit, as wide as
    /// the field is in a panel this wide.
    static func fieldImage(session: AgentSession, palette: PanelPalette, dark: Bool) throws -> NSImage {
        let width = width - 16 * 2 - 18 - 10
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: InputField.rowHeight),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let textView = InputTextView(frame: NSRect(x: 0, y: 0, width: width, height: InputField.rowHeight))
        textView.drawsBackground = false
        textView.isRichText = false
        textView.font = InputField.font
        textView.textColor = palette.primaryNSColor
        textView.textContainerInset = NSSize(width: 0, height: InputField.verticalInset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = session.draft
        window.contentView = textView
        textView.inlineCompletionColor = palette.tertiaryNSColor
        textView.inlineCompletion = session.inlineCompletion
        textView.setSelectedRange(NSRange(location: (session.draft as NSString).length, length: 0))
        textView.layoutSubtreeIfNeeded()
        textView.display()
        let rep = try #require(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        // Through a CGImage in sRGB, so the render keeps its own color space.
        let png = try #require(rep.representation(using: .png, properties: [:]))
        return try #require(NSImage(data: png))
    }
}
