import AppKit
import MacOSAgentCore
import Observation
import SwiftUI

/// The kept thread as a stack of panes: the episodes, newest first, with a search over all of
/// it, then an episode, read-only, then a command's input and output. Incognito episodes are
/// never in the kept thread, so they never appear here. Nothing here edits or deletes. See
/// `HistoryPaneStackView`.
@MainActor
@Observable
final class HistorySettingsModel {
    private(set) var items: [EpisodeListItem] = []
    private(set) var isSearching = false
    var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    /// Where the pane stack is: `[episode]` or `[episode, command]`. Kept here so the stack and
    /// its scroll places last while the window is open.
    let stack = PaneStackState()
    @ObservationIgnored let history: ThreadStore?
    /// Where the thread's images are kept, for the thumbnails beside a message's line.
    @ObservationIgnored let images: any ImageStorage
    @ObservationIgnored private var contents = ThreadContents()
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// What a command's line says. MCP calls read by display names, resolved each time the lines
    /// are read, so a rename shows the next time History reads the thread.
    @ObservationIgnored let summaries: ToolCallSummaries

    init(history: ThreadStore?, images: any ImageStorage = ImageFolder(), summaries: ToolCallSummaries = ToolCallSummaries.builtIn.showingDisplayNames()) {
        self.history = history
        self.images = images
        self.summaries = summaries
    }

    /// The thread as last read and the list the base shows.
    var panes: HistoryPanes { HistoryPanes(contents: contents, items: items, summaries: summaries) }

    /// Opens an episode, by its number, or a command, by its call id, in the pane stack, as
    /// `--preview-item` asks. An item that is not here changes nothing. The thread is read
    /// after the window opens, so the item is opened again each time a read finishes.
    func showInStack(_ item: String) {
        stackPreviewItem = item
        openStackPreviewItem()
    }

    @ObservationIgnored private var stackPreviewItem: String?

    private func openStackPreviewItem() {
        if let item = stackPreviewItem, let path = panes.path(showing: item) { stack.path = path }
    }

    var countText: String {
        let count = EpisodeListItem.all(in: contents).count
        return count == 1 ? "1 episode" : "\(count) episodes"
    }

    /// Reads the thread again, since the agent adds to it while the window is closed.
    func reload() {
        guard let history else { return }
        Task {
            contents = await history.contents
            refresh()
            openStackPreviewItem()
        }
    }

    private func refresh() {
        searchTask?.cancel()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let history else {
            isSearching = false
            items = EpisodeListItem.all(in: contents)
            return
        }
        isSearching = true
        searchTask = Task {
            // Waits for a pause in typing before it searches.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let found = EpisodeListItem.matching(await history.search(query, limit: 200), summaries: summaries)
            guard !Task.isCancelled else { return }
            items = found
        }
    }

}

/// Settings, History: the episodes, an episode, and a command, as a pane stack. See
/// `HistoryPaneStackView`.
struct HistorySettingsView: View {
    @Bindable var model: HistorySettingsModel

    var body: some View {
        HistoryPaneStackView(model: model)
    }
}

/// One line of an episode. A command, a hosted one such as a web search, and each step of a
/// quick action is a row that opens the command's input and output.
struct LineView: View {
    let line: EpisodeLine

    var body: some View {
        switch line.kind {
        case .owner:
            VStack(alignment: .leading, spacing: 6) {
                labeled("You", Text(line.text))
                if !line.images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(line.images, id: \.self) { image in
                            ImageThumbnail(attachment: image, size: 40)
                                .accessibilityLabel(ImageThumbnail.spokenText(image))
                        }
                    }
                }
            }
        case .agent:
            labeled("Agent", Text(line.text))
        case .command(let outcome):
            command(line, outcome)
        case .event(let event):
            VStack(alignment: .leading, spacing: 4) {
                EventLineView(event: event)
                // A quick action's steps, as commands are.
                ForEach(line.steps) { step in
                    if case .command(let outcome) = step.kind {
                        command(step, outcome)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }

    @ViewBuilder
    private func command(_ line: EpisodeLine, _ outcome: TranscriptRow.ToolOutcome) -> some View {
        if let callID = line.callID {
            PaneStackLink(id: callID) {
                HStack(spacing: 8) {
                    CommandLineView(line: line, outcome: outcome)
                    Spacer(minLength: 8)
                    PaneChevron()
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
            .textSelection(.disabled)
            .padding(.horizontal, -6)
            .accessibilityHint(Text("Shows the command's input and output"))
        } else {
            CommandLineView(line: line, outcome: outcome)
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

/// A command, with the marks of the panel's tool rows: `›`, or `✗` for one that failed.
private struct CommandLineView: View {
    let line: EpisodeLine
    let outcome: TranscriptRow.ToolOutcome

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: outcome == .failed ? Mark.failed : Mark.call)
                .font(Mark.rowFont)
                .foregroundStyle(outcome == .failed ? HierarchicalShapeStyle.primary : .tertiary)
                .frame(width: Mark.rowColumn, alignment: .leading)
                .accessibilityHidden(true)
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(line.date.formatted(date: .abbreviated, time: .shortened))
    }
}

/// Something the owner did without a message, in the panel's words and icon: "Opened" and the
/// app's own icon and name, or "Ran", the quick action's icon, and its name, or its name and
/// why it failed, in red. Its time is beside it, as a message's is.
private struct EventLineView: View {
    let event: TranscriptLine

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            if let leading = event.leadingText {
                Text(verbatim: leading)
            }
            icon
            Text(verbatim: event.trailingText)
                .foregroundStyle(event.isFailure ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(TranscriptTimeLabel.fullText(for: event.date))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(event.spokenText)
    }

    @ViewBuilder private var icon: some View {
        switch event.icon {
        case .quickAction:
            Image(systemName: "bolt.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14, height: 14)
        case .application(let path):
            Image(nsImage: SuggestionIcon.icon(for: URL(filePath: path)))
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
        }
    }
}
