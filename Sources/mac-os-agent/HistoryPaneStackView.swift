import AppKit
import MacOSAgentCore
import SwiftUI

/// Settings, History, as a pane stack: the episodes, one episode, and one command's input and
/// output, each sliding over the one before. Behind the pane stack experiment. See
/// `PaneStackView` and `HistoryPanes`.
///
/// The search field is part of the episodes pane, pinned above the list where a pane's title
/// would be. While another pane covers the list, the strip shows the start of the field and of
/// each episode, and a click on it goes back to the list, so a search is never typed into a
/// covered pane.
struct HistoryPaneStackView: View {
    /// How much of the episodes shows beside an episode: the date and the start of the first line.
    static let episodesStripWidth: CGFloat = 200
    /// How much of an episode shows beside a command: the start of its lines.
    static let episodeStripWidth: CGFloat = 170

    @Bindable var model: HistorySettingsModel

    var body: some View {
        let panes = model.panes
        PaneStackView(state: model.stack) { strip in
            switch strip.depth {
            // Beside a command, the episodes are only a sliver to click back to: an episode's
            // row has no icon to narrow to, as a group of tools does.
            case 0: strip.isNearest ? Self.episodesStripWidth : PaneStackLayout.collapsedWidth
            default: Self.episodeStripWidth
            }
        } title: { level in
            panes.pane(at: level.depth, of: level.path)?.title ?? ""
        } rows: { path in
            panes.rows(of: path)
        } pane: { level in
            switch panes.pane(at: level.depth, of: level.path) {
            case .episodes:
                EpisodesPane(model: model)
            case .episode(let episode):
                EpisodePane(episode: episode, lines: panes.lines(of: episode), matchedLineID: panes.matchedLineID(in: episode))
            case .command(let line, let call, let episode):
                CommandPane(line: line, call: call, episode: episode)
            case nil:
                Color.clear
            }
        }
        .environment(\.imageData) { [images = model.images] in images.data(for: $0) }
        .onAppear { model.reload() }
        .onChange(of: model.stack.path, initial: true) { _, path in fallBack(path) }
        .onChange(of: model.panes) { _, _ in fallBack(model.stack.path) }
    }

    /// A path that names an episode or command that is not here, such as one a preview asked for
    /// before the thread was read, falls back to the part that is. An empty thread has nothing
    /// to fall back from yet, so a path waits for the first read.
    private func fallBack(_ path: PaneStackPath) {
        guard !model.panes.contents.entries.isEmpty else { return }
        let valid = model.panes.validPrefix(of: path)
        if valid != path { model.stack.path = valid }
    }
}

/// The base pane: the search field, the episodes newest first or a search's results, and the
/// count, as History lists them without the stack.
private struct EpisodesPane: View {
    @Bindable var model: HistorySettingsModel

    var body: some View {
        VStack(spacing: 0) {
            FilterField(prompt: "Search All History", text: $model.query)
                .padding(10)
            Divider().opacity(0.6)
            Group {
                if model.history == nil {
                    ContentUnavailableView(
                        "History Is Not Available", systemImage: "clock.arrow.circlepath",
                        description: Text("The thread file could not be opened."))
                } else if model.items.isEmpty && model.isSearching {
                    ContentUnavailableView.search(text: model.query)
                } else if model.items.isEmpty {
                    ContentUnavailableView(
                        "No Episodes Yet", systemImage: "clock.arrow.circlepath",
                        description: Text("Conversations with the agent show up here, one episode at a time."))
                } else {
                    PaneScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.items) { item in
                                PaneStackLink(id: HistoryPanes.id(of: item.episode)) {
                                    EpisodeStackRow(item: item)
                                }
                                .accessibilityHint(Text("Shows everything that happened in the episode"))
                                if item.id != model.items.last?.id {
                                    PaneRowDivider(leading: EpisodeStackRow.inset)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Text(model.countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

/// An episode in the list: its date, its first line or the line a search matched, and what it
/// holds, with a chevron, as a group of tools is listed.
private struct EpisodeStackRow: View {
    static let inset: CGFloat = 16

    let item: EpisodeListItem

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.episode.startDate.formatted(date: .abbreviated, time: .shortened))
                    .lineLimit(1)
                Text(item.match ?? item.episode.preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(item.episode.summary)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PaneChevron()
        }
        .padding(.leading, Self.inset)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(item.episode.startDate.formatted(date: .abbreviated, time: .shortened)), \(item.match ?? item.episode.preview), \(item.episode.summary)"))
    }
}

/// The second pane: everything that happened in one episode, in order, as History shows it
/// without the stack. A command is a row that opens its input and output. A search's matching
/// line is marked, and the pane opens scrolled to it.
private struct EpisodePane: View {
    let episode: Episode
    let lines: [EpisodeLine]
    let matchedLineID: String?
    @Environment(\.paneStack) private var stack

    var body: some View {
        StackPane(
            title: Text("Episode \(episode.number)").font(.headline),
            subtitle: "\(episode.startDate.formatted(date: .abbreviated, time: .shortened)) to \(episode.lastActivity.formatted(date: .omitted, time: .shortened)). \(episode.summary)"
        ) {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let caption = episode.startCaption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(lines) { line in
                        LineView(line: line, opensCommands: true)
                            .padding(.vertical, line.id == matchedLineID ? 4 : 0)
                            .background {
                                if line.id == matchedLineID {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.yellow.opacity(0.18))
                                        .padding(.horizontal, -8)
                                }
                            }
                            .id(line.id)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .onAppear {
                    // A search result opens at the line that matched, unless the pane was
                    // scrolled before and keeps that place.
                    let kept = stack.scrollKey.flatMap { stack.state?.scrollOffsets[$0] } ?? 0
                    if let matchedLineID, kept <= 0 { proxy.scrollTo(matchedLineID, anchor: .center) }
                }
            }
        }
    }
}

/// The third pane: one command, with what the panel's inspector shows for it: its facts, its
/// input laid out for reading, and its output in the shape it was found to have. Input and
/// facts scroll in the top part and the output fills the rest, as in the inspector.
private struct CommandPane: View {
    let line: EpisodeLine
    let call: InspectedToolCall?
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneTitle(
                title: Text(line.text).font(.headline.monospaced()),
                subtitle: "Episode \(episode.number), \(line.date.formatted(date: .abbreviated, time: .shortened))")
            Divider().opacity(0.6)
            if let call {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                InspectorMetadata(call: call, sourceLookup: { _ in nil })
                                InspectorInput(call: call)
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: geometry.size.height * 0.45)
                        .fixedSize(horizontal: false, vertical: true)
                        Divider().opacity(0.6)
                        // The inspector's output sits 16 points in. The pane's title sits 20 in.
                        InspectorOutput(call: call)
                            .padding(.horizontal, 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                // A new command starts at the top with its own state.
                .id(call.callID)
            } else {
                Text("The thread does not hold this command's call.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
