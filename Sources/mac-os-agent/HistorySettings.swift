import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// The kept thread as a list of episodes, newest first, with a search over all of it and a
/// read-only view of the selected episode. Incognito episodes are never in the kept thread,
/// so they never appear here. Nothing here edits or deletes.
@MainActor
@Observable
final class HistorySettingsModel {
    private(set) var items: [EpisodeListItem] = []
    private(set) var lines: [EpisodeLine] = []
    private(set) var isSearching = false
    var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    var selection: EpisodeListItem.ID? {
        didSet { if selection != oldValue { readSelected() } }
    }
    @ObservationIgnored let history: ThreadStore?
    @ObservationIgnored private var contents = ThreadContents()
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(history: ThreadStore?) {
        self.history = history
    }

    var selectedItem: EpisodeListItem? { items.first { $0.id == selection } }

    var countText: String {
        let count = contents.episodes.filter(\.hasActivity).count
        return count == 1 ? "1 episode" : "\(count) episodes"
    }

    /// Reads the thread again, since the agent adds to it while the window is closed.
    func reload() {
        guard let history else { return }
        Task {
            contents = await history.contents
            refresh()
        }
    }

    private func refresh() {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let history else {
            isSearching = false
            show(EpisodeListItem.all(in: contents))
            return
        }
        isSearching = true
        searchTask = Task {
            // Waits for a pause in typing before it searches.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = EpisodeListItem.matching(await history.search(query, limit: 200))
            guard !Task.isCancelled else { return }
            show(found)
        }
    }

    private func show(_ items: [EpisodeListItem]) {
        self.items = items
        if selection == nil || !items.contains(where: { $0.id == selection }) {
            selection = items.first?.id
        } else {
            readSelected()
        }
    }

    private func readSelected() {
        lines = selectedItem.map { EpisodeLine.lines(of: $0.episode, in: contents) } ?? []
    }
}

struct HistorySettingsView: View {
    @Bindable var model: HistorySettingsModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FilterField(prompt: "Search All History", text: $model.query)
                    .padding(10)
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
                        List(model.items, selection: $model.selection) { item in
                            EpisodeRow(item: item).tag(item.id)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
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
            .frame(width: 280)
            Divider()
            Group {
                if let item = model.selectedItem {
                    EpisodeDetailView(episode: item.episode, lines: model.lines)
                } else {
                    ContentUnavailableView(
                        "No Episode Selected", systemImage: "clock.arrow.circlepath",
                        description: Text("Incognito episodes are never kept, so they are never listed."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { model.reload() }
    }
}

/// The date, length, and first line of an episode, or the line that matched a search.
private struct EpisodeRow: View {
    let item: EpisodeListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.episode.startDate.formatted(date: .abbreviated, time: .shortened))
                Spacer(minLength: 4)
                Text(EpisodeDetailView.length(item.episode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.match ?? item.episode.preview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

/// One episode, read-only: the owner's messages, the commands that ran, and the replies, with
/// selectable text.
private struct EpisodeDetailView: View {
    let episode: Episode
    let lines: [EpisodeLine]

    static func length(_ episode: Episode) -> String {
        let messages = episode.messageCount == 1 ? "1 message" : "\(episode.messageCount) messages"
        guard episode.commandCount > 0 else { return messages }
        return messages + (episode.commandCount == 1 ? ", 1 command" : ", \(episode.commandCount) commands")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Episode \(episode.number)")
                        .font(.title3)
                    Text("\(episode.startDate.formatted(date: .complete, time: .shortened)) to \(episode.lastActivity.formatted(date: .omitted, time: .shortened)), \(Self.length(episode))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 6)
                ForEach(lines) { line in
                    LineView(line: line)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .id(episode.id)
    }
}

private struct LineView: View {
    let line: EpisodeLine

    var body: some View {
        switch line.kind {
        case .owner:
            labeled("You", Text(line.text))
        case .agent:
            labeled("Agent", Text(line.text))
        case .command(let outcome):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Group {
                    switch outcome {
                    case .succeeded: Image(systemName: "checkmark").foregroundStyle(.green)
                    case .failed: Image(systemName: "xmark").foregroundStyle(.red)
                    case .unknown: Image(systemName: "minus").foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 9, weight: .bold))
                .frame(width: 12)
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .help(line.date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func labeled(_ label: String, _ text: Text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                Text(line.date.formatted(date: .omitted, time: .shortened))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            text
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
