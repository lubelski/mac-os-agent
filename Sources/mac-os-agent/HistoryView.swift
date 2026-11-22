import MacOSAgentCore
import SwiftUI

/// The whole thread, oldest at the top, read as episodes.
///
/// A fresh episode, after a timeout or `/new`, is an empty page as tall as the view, so it
/// opens with the earlier episodes above it, out of view until the owner scrolls up. The page
/// holds the fresh-start slot. Once the episode has its first message the page is only as tall
/// as its rows, and the rows sit at the bottom by the text field with nothing left over below
/// them. The episode before shows above, past a wide gap and its separator.
///
/// It opens at the latest row and follows new rows while the owner is at the bottom. Once they
/// scroll up it stays where they put it, and a button takes them back down. Rows are built
/// lazily as they scroll into view, so a long thread scrolls smoothly.
struct HistoryView: View {
    let session: AgentSession
    let now: Date
    @State private var position: ScrollPosition
    /// Whether new content keeps the view at the bottom.
    @State private var followsLatest: Bool
    /// The height of the visible area, which a fresh page fills.
    @State private var containerHeight: CGFloat = 0
    private let startsAtTop: Bool

    init(session: AgentSession, now: Date) {
        self.session = session
        self.now = now
        startsAtTop = session.previewStartsAtTop
        _position = State(initialValue: ScrollPosition(edge: startsAtTop ? .top : .bottom))
        _followsLatest = State(initialValue: !startsAtTop)
    }

    static let topPadding: CGFloat = 4
    static let bottomPadding: CGFloat = 16
    /// The room above a fresh page's separator, at the top of the view.
    static let freshPageTopInset: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Within this distance of the end counts as at the bottom.
    private static let bottomTolerance: CGFloat = 24

    private struct Metrics: Equatable {
        var visibleBottom: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
    }

    var body: some View {
        let transcript = session.transcript
        let rows = transcript.rows
        let pageStart = min(transcript.currentEpisodeStartRow ?? 0, rows.count)
        // Nothing in the current episode yet but its separator.
        let isFreshPage = rows.count - pageStart <= 1 && session.streamingText.isEmpty
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Earlier episodes.
                ForEach(0..<pageStart, id: \.self) { index in
                    row(index, in: rows)
                }
                if isFreshPage {
                    // A fresh page fills the view from just above its separator down, so the
                    // separator's own gap above holds the episode before it out of view.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(pageStart..<rows.count, id: \.self) { index in
                            row(index, in: rows)
                        }
                        FreshStartSlot(hint: FreshStartHint.text(
                            hasEarlierEpisodes: pageStart > 0,
                            isEmptyThread: rows.allSatisfy(\.isEpisodeStart),
                            isIncognito: session.isIncognito))
                        {
                            FreshStartContent(session: session)
                        }
                    }
                    .frame(height: max(0, containerHeight - Self.bottomPadding - Self.freshPageTopInset
                                       + Self.spacing(pageStart > 0 ? .episode : .none)), alignment: .top)
                } else {
                    // The current episode, only as tall as its rows.
                    ForEach(pageStart..<rows.count, id: \.self) { index in
                        row(index, in: rows)
                    }
                    StreamingReply(session: session, after: rows.last)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, Self.topPadding)
            .padding(.bottom, Self.bottomPadding)
        }
        .environment(\.revealsAllControls, session.previewRevealsControls)
        .environment(\.pendingGoAhead, session.pendingConfirmation)
        .scrollPosition($position)
        .defaultScrollAnchor(startsAtTop ? .top : .bottom, for: .initialOffset)
        // A short thread sits at the bottom, by the text field, not at the top of the view.
        .defaultScrollAnchor(.bottom, for: .alignment)
        .onScrollGeometryChange(for: Metrics.self) { geometry in
            Metrics(
                visibleBottom: geometry.visibleRect.maxY,
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height)
        } action: { old, new in
            containerHeight = new.containerHeight
            if old.contentHeight != new.contentHeight || old.containerHeight != new.containerHeight {
                // The content grew, a row opened, or the panel was resized.
                if followsLatest { position.scrollTo(edge: .bottom) }
            } else if old.visibleBottom != new.visibleBottom {
                // Only the owner moves the view without the content changing size.
                followsLatest = new.contentHeight - new.visibleBottom <= Self.bottomTolerance
            }
        }
        .onChange(of: session.focusRequest) { jumpToLatest(animated: false) }
        .onChange(of: rows.count) {
            if rows.last?.isUser == true { jumpToLatest(animated: false) }
        }
        // A fresh page, from a timeout, `/new`, or Clear in the incognito window, opens at its top.
        .onChange(of: transcript.currentEpisodeStartRow) { jumpToLatest(animated: false) }
        .onChange(of: session.conversation) { jumpToLatest(animated: false) }
        .overlay(alignment: .bottomTrailing) {
            if !followsLatest {
                Button {
                    jumpToLatest(animated: true)
                } label: {
                    Text(verbatim: Mark.down)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Jump to the latest")
                .accessibilityLabel("Jump to the latest")
                .padding(12)
            }
        }
    }

    private func row(_ index: Int, in rows: [TranscriptRow]) -> some View {
        let row = rows[index]
        return RowView(row: row, now: now)
            .padding(.top, Self.spacing(TranscriptRow.gap(after: index > 0 ? rows[index - 1] : nil, before: row)))
    }

    private func jumpToLatest(animated: Bool) {
        followsLatest = true
        if animated && !reduceMotion {
            withAnimation(.smooth(duration: 0.3)) { position.scrollTo(edge: .bottom) }
        } else {
            position.scrollTo(edge: .bottom)
        }
    }

    /// The room above a row. Rows of one exchange sit close, exchanges sit apart, and an
    /// episode's separator has the most room on both sides, so it reads as a break between
    /// episodes rather than a mark inside one.
    static func spacing(_ gap: TranscriptRow.Gap) -> CGFloat {
        switch gap {
        case .none: 0
        case .tight: 2
        case .regular: 10
        case .exchange: 24
        case .episode: 64
        case .belowEpisode: 28
        }
    }
}

enum FreshStartHint {
    /// The line for an empty page: where the earlier episodes are on a fresh start, and where
    /// everything goes in a new thread. An incognito page says what the window can do instead.
    static func text(hasEarlierEpisodes: Bool, isEmptyThread: Bool, isIncognito: Bool = false) -> String? {
        if isIncognito { return incognito }
        if hasEarlierEpisodes { return "\(Mark.up) Earlier episodes are above" }
        if isEmptyThread { return "Everything you ask stays in this one thread." }
        return nil
    }

    static let incognito = "This window opens apps and answers questions. Anything else needs the main panel."
}

/// The empty space of a fresh episode. It holds an optional block of content, such as
/// suggestions, by the text field at the bottom, and a quiet line under the separator that says
/// where the earlier episodes are. With no content it is the line alone.
struct FreshStartSlot<Content: View>: View {
    let hint: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let hint {
                Text(verbatim: hint)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }
            Spacer(minLength: 24)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What fills the fresh-start slot. Nothing yet: what suggestions to offer is not decided.
/// Content added here shows at the bottom of a fresh page, above the text field, and goes away
/// with the page when the owner sends the episode's first message.
struct FreshStartContent: View {
    let session: AgentSession

    var body: some View {
        if let content = session.previewFreshStartContent {
            FreshStartStandIn(lines: content)
        }
    }
}

/// Blocks in place of suggestion content, for a preview that shows how the slot lays out.
private struct FreshStartStandIn: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { line in
                Text(verbatim: line)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, MessageStyle.horizontalPadding)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        }
    }
}

/// The line between episodes: the date and time the episode started, between two hairlines
/// that run the width of the history.
struct EpisodeSeparator: View {
    let date: Date
    let now: Date
    @Environment(\.panelPalette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            hairline
            Text(TranscriptTimeLabel.episodeText(for: date, now: now))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            hairline
        }
        .help(TranscriptTimeLabel.fullText(for: date))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Episode started \(TranscriptTimeLabel.fullText(for: date))")
        .accessibilityAddTraits(.isHeader)
    }

    private var hairline: some View {
        Rectangle()
            .fill(palette.divider)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// The reply as it streams in. It is its own view so each new piece of text redraws only it,
/// not the whole history. It looks exactly like the finished reply that replaces it.
private struct StreamingReply: View {
    let session: AgentSession
    let after: TranscriptRow?

    var body: some View {
        if !session.streamingText.isEmpty {
            AgentMessage(text: session.streamingText, streaming: true)
                .padding(.top, HistoryView.spacing(TranscriptRow.gap(after: after, before: TranscriptRow(id: "streaming", kind: .assistant("")))))
        }
    }
}
