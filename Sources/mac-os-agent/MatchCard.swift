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
// - The card always opens downward, past the panel's bottom edge. The pill in the panel is the
//   card's top, and the rest is `MatchCardWindow`, a child window under it, so the panel never
//   resizes for it and its frame never includes the card. The card covers the status line, so
//   it carries the keys on its own last row. With too little room below for every row, the list
//   is shortened to the whole rows that fit and part of the next, at least two and a part, and
//   scrolls. See `MatchListFit` and `MatchListScroll`.
// - With room below for less than two rows and a part, the panel makes room first: a centered
//   panel moves up, and a slide over panel's bottom edge rises. It goes back when the field is
//   cleared or sent, or the panel hides. See `MatchListRoom` and `SummonPanel`, The match card.
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
    /// The row of keys at the bottom of the card, as tall as the status line.
    static let keysHeight = InputFooter.height
    /// The gap from the card's side to a row's icon: the pill's own, so the icons sit in a
    /// column under the field's mark.
    static let rowIndent = PanelFrame.pillPadding

    /// The part of the card below the pill: the rows, and part of the next one
    /// when the list is shortened, a hairline, the keys.
    static func heightBelowPill(rows: Int, partRowHeight: CGFloat = 0) -> CGFloat {
        rows == 0 ? 0 : rowHeight * CGFloat(rows) + partRowHeight + 1 + keysHeight
    }

    /// How far the card reaches below the panel's bottom edge. It covers the
    /// status line under the pill first.
    static func reachBelowPanel(rows: Int, partRowHeight: CGFloat = 0) -> CGFloat {
        max(0, heightBelowPill(rows: rows, partRowHeight: partRowHeight) - InputFooter.height)
    }

    /// The part row a shortened list ends in: 0.4 of a row, in whole points.
    static let partRowHeight = MatchListFit.partRowHeight(rowHeight: rowHeight)

    /// How far the card reaches below the panel's bottom edge besides its
    /// rows: the hairline and the keys, less the status line they cover.
    static let reachBeyondRows: CGFloat = 1 + keysHeight - InputFooter.height

    /// How many rows of a card of `rows` rows show in the room below the panel.
    static func fit(rows: Int, roomBelow: CGFloat) -> MatchListFit? {
        MatchListFit.fit(rowCount: rows, rowHeight: rowHeight, reachBeyondRows: reachBeyondRows, roomBelow: roomBelow)
    }

    /// The room below the panel a card of `rows` rows needs to show its minimum: every row up to
    /// two, or two rows and a part. With less, the panel makes room.
    static func minimumReach(rows: Int) -> CGFloat {
        MatchListFit.minimumReach(rowCount: rows, rowHeight: rowHeight, reachBeyondRows: reachBeyondRows)
    }

    /// The room the panel makes when it moves for the card: two rows and a part, the minimum of
    /// the longest list, so a list that grows as the owner types never needs it to move again.
    static let roomMade = minimumReach(rows: visibleLimit)

    /// The room a panel leaves below it for the card: from its bottom edge to the bottom of its
    /// screen's visible area, less a margin, so the card never ends flush with the screen's
    /// edge. None for a slide over panel at the screen's full height.
    static func roomBelow(panel: CGRect, visible: CGRect) -> CGFloat {
        MatchListRoom.roomBelow(panel: panel, visible: visible, margin: SummonPanel.footerGrowthMargin)
    }

    /// Where the panel goes to make room for the card when it has less than `roomMade` below
    /// it. See `MatchListRoom`.
    static func frameMakingRoom(panel: CGRect, visible: CGRect, slideOver: Bool) -> CGRect {
        MatchListRoom.frame(
            panel: panel, visible: visible, layout: slideOver ? .pinnedToEdge : .floating, needed: roomMade,
            margin: SummonPanel.footerGrowthMargin, minimumHeight: SummonPanel.minimumSize.height)
    }

    /// The child window's frame for the card: the pill's width, from the
    /// pill's bottom edge down. `pill` is in the panel's content with a top-left origin, and
    /// `content` is that content's frame on screen.
    static func frameBelow(pill: CGRect, content: CGRect, rows: Int, partRowHeight: CGFloat = 0) -> CGRect {
        let height = heightBelowPill(rows: rows, partRowHeight: partRowHeight)
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

extension AgentSession {
    /// The rows of the match card, or none with the panel with bars off.
    var matchCardRows: [SuggestionRow] {
        panelWithBars ? suggestionRows : []
    }

    /// How many rows of the card show now, or nil when there is no card. It is never taller than
    /// `MatchCard.visibleLimit` rows, so a longer list, such as many slash commands, is
    /// shortened and scrolls even with room for all of it.
    var matchCardFit: MatchListFit? {
        let tallest = MatchCard.reachBelowPanel(rows: MatchCard.visibleLimit)
        return MatchCard.fit(rows: matchCardRows.count, roomBelow: min(suggestionList.roomBelow, tallest))
    }

    /// Whether the match card is open, below the pill.
    var showsMatchCard: Bool { matchCardFit != nil }

    /// How many whole rows the card shows at once. A shortened list shows part of one more,
    /// `matchCardPartRowHeight`, and scrolls.
    var matchCardVisibleRows: Int { matchCardFit?.rows ?? 0 }

    /// How much of the row after the last whole one the card shows: the part row of a shortened
    /// list, or 0.
    var matchCardPartRowHeight: CGFloat { matchCardFit?.partRowHeight ?? 0 }

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

/// The card's fill: opaque and plain, so it reads the same over the conversation, over the band,
/// past the panel's edge, and inside the glass in slide over. See `PanelPalette.matchCardFill`.
struct MatchCardFill: View {
    @Environment(\.panelPalette) private var palette

    var body: some View {
        Rectangle().fill(palette.matchCardFill).accessibilityHidden(true)
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

extension MatchCard {
    /// What VoiceOver calls the list.
    static func listLabel(_ rows: [SuggestionRow]) -> String {
        rows.first.map { if case .command = $0 { "Commands" } else { "Matches" } } ?? ""
    }
}

/// The card's rows, in a list that scrolls: with the trackpad, and with
/// the arrows, which scroll it only as far as keeps the highlighted row whole, by
/// `MatchListScroll`. A shortened list is `height` tall, whole rows and a part row, so a row cut
/// off at an edge shows there are more. With room for every row it never scrolls.
struct MatchCardScrollingRows: View {
    let rows: [SuggestionRow]
    let highlight: Int
    /// The list's height as shown.
    let height: CGFloat
    /// How much of the rows past the highlighted one the arrows keep in view: the part row.
    let margin: CGFloat
    let incognito: Bool
    var activate: (Int) -> Void = { _ in }

    @State private var position: ScrollPosition
    /// Where the list is scrolled to, as the trackpad or the arrows left it.
    @State private var offset: CGFloat

    init(
        rows: [SuggestionRow], highlight: Int, height: CGFloat, margin: CGFloat, incognito: Bool,
        activate: @escaping (Int) -> Void = { _ in }
    ) {
        self.rows = rows
        self.highlight = highlight
        self.height = height
        self.margin = margin
        self.incognito = incognito
        self.activate = activate
        let start = MatchListScroll.offset(
            showing: highlight, from: 0, rowCount: rows.count, rowHeight: MatchCard.rowHeight, viewport: height, margin: margin)
        _position = State(initialValue: ScrollPosition(y: start))
        _offset = State(initialValue: start)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    MatchCardRowView(
                        row: rows[index], highlighted: index == highlight,
                        key: MatchCard.key(for: rows[index], at: index, highlight: highlight),
                        incognito: incognito)
                        .contentShape(.rect)
                        .onTapGesture { activate(index) }
                }
            }
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }, action: { _, new in offset = new })
        .frame(height: height)
        .onChange(of: highlight) { reveal() }
        .onChange(of: rows) { reveal() }
        .onChange(of: height) { reveal() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(MatchCard.listLabel(rows))
    }

    /// Scrolls just far enough that the highlighted row is whole, with a part row past it.
    private func reveal() {
        let target = MatchListScroll.offset(
            showing: highlight, from: offset, rowCount: rows.count, rowHeight: MatchCard.rowHeight, viewport: height,
            margin: margin)
        guard target != offset else { return }
        offset = target
        position.scrollTo(y: target)
    }
}

/// One row, a full-bleed band when highlighted, which the card's corners clip: a 32 point icon, the name, a line saying what it is, and its key at the end. The
/// weight never changes. Highlighted, it is on the accent from one edge of the card to the
/// other, with its text in a color that reads on the accent.
struct MatchCardRowView: View {
    let row: SuggestionRow
    let highlighted: Bool
    let key: String?
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
        case .ask(let text): "Ask the agent: “\(text)”"
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
        case .ask(let text): "Ask the agent: \(text)"
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

/// The part of the card below the pill: the rows, then the keys on the card's
/// own last row, since the card covers the status line. Drawn by `MatchCardWindow`.
struct MatchCardBelow: View {
    let session: AgentSession
    @Environment(\.panelPalette) private var palette

    var body: some View {
        let shape = MatchCard.shape(top: false, bottom: true)
        VStack(spacing: 0) {
            MatchCardScrollingRows(
                rows: session.matchCardRows, highlight: session.highlightedRowIndex,
                height: MatchCard.rowHeight * CGFloat(session.matchCardVisibleRows) + session.matchCardPartRowHeight,
                margin: session.matchCardPartRowHeight, incognito: session.isIncognito,
                activate: session.activateSuggestionRow)
            MatchCardSeam()
            InputFooter(
                content: .make(
                    session.footerState, modelName: "", recallsMessages: false,
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

/// The part of the card below the pill, in a borderless child window of the panel, so it can
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
