import AppKit
import MacOSAgentCore
import SwiftUI

// The match card of the panel with bars and an input pill (`Experiment.panelWithBarsAndInputPill`).
// See `planning/panel-with-input-pill.md`, Matches.
//
// A match opens the pill into a card: one rounded shape that holds the field at one end and
// the list of matches. The list is there as soon as there is a match. The rows are Alfred's: a
// 32 point icon, a name, a line saying what it is, and Command numbers that run a row without
// moving to it. The last row is the Ask row, which sends the text as a message.
//
// - With room below the panel, the card opens downward, past the panel's bottom edge. The pill
//   in the panel is the card's top, and the rest is `MatchCardWindow`, a child window under it,
//   so the panel never moves or resizes and its frame never includes the card. The card covers
//   the status line, so it carries the keys on its own last row.
// - With no room below, the same card opens upward over the end of the conversation, inside
//   the panel, with the field as its last line. Nothing in the conversation moves.
//
// The state is the suggestions experiment's list (`SuggestionListState`), opened by itself.
// The engine's ranking and its rule for what counts as a match are unchanged.

/// The card's measures and the choice of which way it opens.
@MainActor
enum MatchCard {
    static let rowHeight: CGFloat = 44
    static let iconSize: CGFloat = 32
    /// The most rows shown at once: every match the rule keeps, and the Ask row.
    static let visibleLimit = SuggestionListView.visibleLimit
    /// The row of keys at the bottom of a card that opens downward, as tall as the status line.
    static let keysHeight = InputFooter.height
    /// The gap from the card's side to a row's icon: the pill's own, so the icons sit in a
    /// column under the field's mark.
    static let rowIndent = PanelFrame.pillPadding

    /// The part of a card that opens downward below the pill: the rows, a hairline, the keys.
    static func heightBelowPill(rows: Int) -> CGFloat {
        rows == 0 ? 0 : rowHeight * CGFloat(rows) + 1 + keysHeight
    }

    /// The part of a card that opens upward above the pill: the rows, and the hairline that
    /// joins them to the field.
    static func heightAbovePill(rows: Int) -> CGFloat {
        rows == 0 ? 0 : rowHeight * CGFloat(rows) + 1
    }

    /// How far a card that opens downward reaches below the panel's bottom edge. It covers the
    /// status line under the pill first.
    static func reachBelowPanel(rows: Int) -> CGFloat {
        max(0, heightBelowPill(rows: rows) - InputFooter.height)
    }

    /// Whether the card opens downward: when all its rows fit in the room below the panel.
    static func opensDownward(rows: Int, roomBelow: CGFloat) -> Bool {
        rows > 0 && reachBelowPanel(rows: rows) <= roomBelow
    }

    /// How many rows a card that opens upward shows in the room above the pill: as many as
    /// fit, at least one. The rest come into view as the highlight reaches them.
    static func rowsAbove(_ count: Int, roomAbove: CGFloat) -> Int {
        guard count > 0 else { return 0 }
        let fits = ((roomAbove - 1) / rowHeight).rounded(.down)
        return fits >= CGFloat(count) ? count : max(1, Int(max(0, fits)))
    }

    /// The room a panel leaves below it for the card: from its bottom edge to the bottom of its
    /// screen's visible area, less a margin, so the card never ends flush with the screen's
    /// edge. None in slide over, which is full height.
    static func roomBelow(panel: CGRect, visible: CGRect, slideOver: Bool) -> CGFloat {
        guard !slideOver else { return 0 }
        return max(0, panel.minY - visible.minY - SummonPanel.footerGrowthMargin)
    }

    /// The child window's frame for a card that opens downward: the pill's width, from the
    /// pill's bottom edge down. `pill` is in the panel's content with a top-left origin, and
    /// `content` is that content's frame on screen.
    static func frameBelow(pill: CGRect, content: CGRect, rows: Int) -> CGRect {
        let height = heightBelowPill(rows: rows)
        return CGRect(x: content.minX + pill.minX, y: content.maxY - pill.maxY - height, width: pill.width, height: height)
    }

    /// The key shown at the end of a row: Return on the highlighted one, Command-Return on the
    /// Ask row, and Command and the row's number on a match, which runs it without moving to it.
    /// None on a slash command.
    static func key(for row: SuggestionRow, at index: Int, highlight: Int) -> String? {
        if index == highlight { return Mark.returnKey }
        switch row {
        case .ask: return Mark.commandReturn
        case .candidate: return index < 9 ? "⌘\(index + 1)" : nil
        case .command: return nil
        }
    }

    /// The second line of a row: where an app is, what a quick action will run, and what the
    /// Ask row does.
    static func detail(for row: SuggestionRow, incognito: Bool) -> String {
        switch row {
        case .candidate(let candidate):
            switch candidate.target {
            case .application(let application):
                return (application.url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
            case .quickAction:
                return ["Quick action", candidate.detail].compactMap { $0 }.joined(separator: " · ")
            }
        case .ask: return "Send the text as a message"
        case .command(let item): return item.summary(incognito: incognito)
        }
    }

    /// The card's shape, with its corners rounded at the top, the bottom, or both.
    static func shape(top: Bool, bottom: Bool) -> UnevenRoundedRectangle {
        let radius = PanelFrame.pillCornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: top ? radius : 0, bottomLeadingRadius: bottom ? radius : 0,
            bottomTrailingRadius: bottom ? radius : 0, topTrailingRadius: top ? radius : 0, style: .continuous)
    }
}

/// Which way the card opens from the pill.
enum MatchCardSide: Equatable {
    /// Downward: the pill is the card's top, and the rows are in the child window below it.
    case below
    /// Upward: the rows are over the end of the conversation, and the pill is the card's bottom.
    case above
}

extension AgentSession {
    /// The rows of the match card, or none with the panel with bars off.
    var matchCardRows: [SuggestionRow] {
        panelWithBars ? suggestionRows : []
    }

    /// Which way the card opens now, or nil when there is no card.
    var matchCardSide: MatchCardSide? {
        let count = min(matchCardRows.count, MatchCard.visibleLimit)
        guard count > 0 else { return nil }
        return MatchCard.opensDownward(rows: count, roomBelow: suggestionList.roomBelow) ? .below : .above
    }

    /// How many rows the card shows at once.
    var matchCardVisibleRows: Int {
        let count = min(matchCardRows.count, MatchCard.visibleLimit)
        switch matchCardSide {
        case .below: return count
        case .above: return MatchCard.rowsAbove(count, roomAbove: suggestionList.roomAbove)
        case nil: return 0
        }
    }

    /// Command and a number, 1 to 9: runs that row of the card without moving the highlight
    /// to it, as Return on it would. Returns false when there is no such row, or it is a slash
    /// command, so the key goes on as before.
    func runMatchCardRow(number: Int) -> Bool {
        guard panelWithBars, suggestionList.isOpen, !isRunning else { return false }
        let rows = suggestionRows
        let index = number - 1
        guard index >= 0, index < rows.count else { return false }
        switch rows[index] {
        case .candidate(let candidate):
            guard let taken = instantActions.take(candidate, for: draft) else { return false }
            closeSuggestionList()
            perform(taken)
            return true
        case .ask:
            closeSuggestionList()
            submitToAgent()
            return true
        case .command:
            return false
        }
    }
}

// MARK: - Drawing

/// The card's fill: opaque, so it reads the same over the conversation, over the band, and past
/// the panel's edge. It is the theme's solid fill with the bars' fill and the field's fill on
/// it, which is how the pill looks at rest on a solid theme.
struct MatchCardFill: View {
    @Environment(\.panelPalette) private var palette

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor))
            Rectangle().fill(palette.fallbackFill)
            Rectangle().fill(palette.bar)
            Rectangle().fill(palette.fieldFill)
        }
        .accessibilityHidden(true)
    }
}

/// The card's edge for one of its two parts. The part nearer the field draws the hairline
/// between them, and the other leaves that side open, so the two read as one shape.
struct MatchCardEdge: View {
    let shape: UnevenRoundedRectangle
    /// The side left open, where the other part's edge is.
    var openTop = false
    var openBottom = false
    @Environment(\.panelPalette) private var palette

    var body: some View {
        shape.strokeBorder(palette.fieldEdge, lineWidth: 1)
            .mask {
                Rectangle()
                    .padding(.top, openTop ? 1 : 0)
                    .padding(.bottom, openBottom ? 1 : 0)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The rows of the card: the visible window of them, moved along so the highlighted one is in
/// view. Each is a full-bleed band when highlighted, which the card's corners clip.
struct MatchCardRows: View {
    let rows: [SuggestionRow]
    let highlight: Int
    let visible: Int
    let agentName: String
    let incognito: Bool
    var activate: (Int) -> Void = { _ in }

    var body: some View {
        let window = CommandHint.window(count: rows.count, selection: highlight, limit: max(1, visible))
        VStack(spacing: 0) {
            ForEach(window, id: \.self) { index in
                MatchCardRowView(
                    row: rows[index], highlighted: index == highlight,
                    key: MatchCard.key(for: rows[index], at: index, highlight: highlight),
                    agentName: agentName, incognito: incognito)
                    .contentShape(.rect)
                    .onTapGesture { activate(index) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rows.first.map { if case .command = $0 { "Commands" } else { "Matches" } } ?? "")
    }
}

/// One row: a 32 point icon, the name, a line saying what it is, and its key at the end. The
/// weight never changes. Highlighted, it is on the accent from one edge of the card to the
/// other, with its text in a color that reads on the accent.
struct MatchCardRowView: View {
    let row: SuggestionRow
    let highlighted: Bool
    let key: String?
    let agentName: String
    let incognito: Bool
    @Environment(\.panelPalette) private var palette

    var body: some View {
        HStack(spacing: 10) {
            MatchCardIcon(row: row)
                .frame(width: MatchCard.iconSize, height: MatchCard.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(.system(size: 13))
                    .foregroundStyle(highlighted ? AnyShapeStyle(onAccent) : palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: MatchCard.detail(for: row, incognito: incognito))
                    .font(.system(size: 11))
                    .foregroundStyle(highlighted ? AnyShapeStyle(onAccent.opacity(0.8)) : palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let key {
                Text(verbatim: key)
                    .font(.system(size: 11))
                    .foregroundStyle(highlighted ? AnyShapeStyle(onAccent.opacity(0.8)) : palette.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.leading, MatchCard.rowIndent)
        .padding(.trailing, 14)
        .frame(height: MatchCard.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if highlighted { Rectangle().fill(accent) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
    }

    private var name: String {
        switch row {
        case .candidate(let candidate): candidate.title
        case .ask(let text): "Ask \(agentName): “\(text)”"
        case .command(let item): item.name
        }
    }

    /// What VoiceOver reads, as the suggestions list reads it.
    private var spoken: String {
        switch row {
        case .candidate(let candidate):
            switch candidate.target {
            case .application: "\(candidate.title), app"
            case .quickAction: "\(candidate.title), quick action"
            }
        case .ask(let text): "Ask \(agentName): \(text)"
        case .command(let item): "\(item.name), \(item.summary(incognito: incognito))"
        }
    }

    private var accent: Color {
        palette.accentOverride ?? Color(nsColor: .controlAccentColor)
    }

    /// White on a dark accent, black on a light one such as High Contrast's yellow.
    private var onAccent: Color {
        MatchCard.isLight(palette.accentNSColor) ? .black : .white
    }
}

extension MatchCard {
    /// Whether text on this color should be dark: by its relative luminance.
    static func isLight(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        return luminance > 0.4
    }
}

/// A row's icon: an app's own, or a tile with a symbol for a quick action, the Ask row, and a
/// slash command or skill.
struct MatchCardIcon: View {
    let row: SuggestionRow

    var body: some View {
        switch row {
        case .candidate(let candidate):
            switch candidate.target {
            case .application:
                SuggestionIcon(target: candidate.target, size: MatchCard.iconSize)
            case .quickAction:
                tile(.orange) { Image(systemName: "bolt.fill") }
            }
        case .ask:
            tile(.indigo) { Image(systemName: "paperplane.fill") }
        case .command(let item):
            if case .skill = item {
                tile(.teal) { Image(systemName: "sparkles") }
            } else {
                tile(.gray) { Text(verbatim: "/").fontWeight(.semibold) }
            }
        }
    }

    private func tile(_ color: Color, @ViewBuilder symbol: () -> some View) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color.gradient)
            .frame(width: 28, height: 28)
            .overlay { symbol().font(.system(size: 14)).foregroundStyle(.white) }
            .accessibilityHidden(true)
    }
}

/// The part of a card that opens upward: its rows over the end of the conversation, with the
/// card's top corners and the hairline that joins them to the field. Drawn by the panel.
struct MatchCardAbove: View {
    let session: AgentSession
    let agentName: String

    var body: some View {
        let shape = MatchCard.shape(top: true, bottom: false)
        VStack(spacing: 0) {
            MatchCardRows(
                rows: session.matchCardRows, highlight: session.highlightedRowIndex, visible: session.matchCardVisibleRows,
                agentName: agentName, incognito: session.isIncognito, activate: session.activateSuggestionRow)
            Color.clear.frame(height: 1)
        }
        .background(MatchCardFill())
        .clipShape(shape)
        .overlay(MatchCardEdge(shape: shape))
    }
}

/// The part of a card that opens downward, below the pill: the rows, then the keys on the card's
/// own last row, since the card covers the status line. Drawn by `MatchCardWindow`.
struct MatchCardBelow: View {
    let session: AgentSession
    @AgentName private var agentName
    @Environment(\.panelPalette) private var palette

    var body: some View {
        let shape = MatchCard.shape(top: false, bottom: true)
        VStack(spacing: 0) {
            MatchCardRows(
                rows: session.matchCardRows, highlight: session.highlightedRowIndex, visible: session.matchCardVisibleRows,
                agentName: agentName, incognito: session.isIncognito, activate: session.activateSuggestionRow)
            MatchCardSeam()
            InputFooter(
                content: .make(
                    session.footerState, agentName: agentName, modelName: "", recallsMessages: false,
                    queuesWhileRunning: session.queuesWhileRunning, statusLine: true),
                drawsFill: false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MatchCardFill())
        .clipShape(shape)
        .overlay(MatchCardEdge(shape: shape, openTop: true))
        .modifier(MatchCardGlass(shape: shape))
    }
}

/// On a glass theme, the panel's content is drawn inside its glass, which changes how its
/// fills read. The part of the card below the panel is drawn inside glass of its own, so it
/// reads the same as the pill it continues.
private struct MatchCardGlass: ViewModifier {
    let shape: UnevenRoundedRectangle
    @Environment(\.panelPalette) private var palette

    func body(content: Content) -> some View {
        if palette.surfaceKind == .glass {
            let tint = palette.surfaceTint(incognito: false)
            content.glassEffect(tint.map { .regular.tint($0) } ?? .regular, in: shape)
        } else {
            content
        }
    }
}

/// The hairline between the rows and the keys.
private struct MatchCardSeam: View {
    @Environment(\.panelPalette) private var palette

    var body: some View {
        Rectangle().fill(palette.fieldEdge).frame(height: 1).accessibilityHidden(true)
    }
}

// MARK: - The window below the panel

/// The part of a card that opens downward, in a borderless child window of the panel, so it can
/// reach past the panel's bottom edge without the panel moving or resizing. It never takes
/// keyboard focus: the field in the panel keeps it, and a click on a row acts on it.
@MainActor
final class MatchCardWindow: NSPanel {
    init(session: AgentSession, preferences: UserDefaults) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        let host = FirstClickHostingView(rootView: AnyView(
            MatchCardBelow(session: session).themedWithoutSurface().defaultAppStorage(preferences)))
        host.sizingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Takes a click in a window that is not key, so one click on a row acts on it.
private final class FirstClickHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
