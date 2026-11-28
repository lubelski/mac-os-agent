import Foundation

/// Settings, History, as a stack of panes: what each depth of a `PaneStackPath` shows.
///
/// The base is the list of episodes, the whole history or a search's results. The path's first
/// entry is an episode's number, which opens everything that happened in it, and its second a
/// command's call id, which opens that command's input and output. Nothing goes deeper.
public enum HistoryPane: Equatable, Sendable {
    case episodes
    case episode(Episode)
    /// A command's line, everything known about its call, and the episode it ran in. The call
    /// is nil when the thread holds the line but not the call, which a test can make.
    case command(EpisodeLine, call: InspectedToolCall?, in: Episode)

    /// The pane's title, as a strip's "Back to" button says it.
    public var title: String {
        switch self {
        case .episodes: "all episodes"
        case .episode(let episode): "Episode \(episode.number)"
        case .command(let line, _, _): line.text
        }
    }
}

/// History's episodes and lines as a pane stack reads them. Made from the thread as Settings
/// last read it and the list the base pane shows, which is a search's results while there is a
/// search.
public struct HistoryPanes: Sendable, Equatable {
    public var contents: ThreadContents
    /// The episodes the base lists, top to bottom.
    public var items: [EpisodeListItem]
    /// What a command's line says, from the tools. With display names on, an MCP call reads by
    /// the names people know it by, resolved as the line is built.
    public var summaries: ToolCallSummaries

    public init(contents: ThreadContents, items: [EpisodeListItem], summaries: ToolCallSummaries = .builtIn) {
        self.contents = contents
        self.items = items
        self.summaries = summaries
    }

    /// The same thread and list. The summaries are not compared: they read the tools, which
    /// do not change while the app runs.
    public static func == (lhs: HistoryPanes, rhs: HistoryPanes) -> Bool {
        lhs.contents == rhs.contents && lhs.items == rhs.items && lhs.summaries.showsDisplayNames == rhs.summaries.showsDisplayNames
    }

    /// An episode's id in a path: its number, which never changes.
    public static func id(of episode: Episode) -> String { String(episode.number) }

    /// The episode a path entry names, read from the thread rather than from the list, so an
    /// open episode stays open when a search no longer lists it. Nil for an episode History
    /// does not list at all.
    public func episode(_ id: String?) -> Episode? {
        guard let id, let number = Int(id), let episode = contents.episode(numbered: number),
              episode.hasActivity, episode.hasSomethingToShow else { return nil }
        return episode
    }

    /// The lines of an episode, in order.
    public func lines(of episode: Episode) -> [EpisodeLine] {
        EpisodeLine.lines(of: episode, in: contents, summaries: summaries)
    }

    /// Every command an episode's pane opens, in the order it shows them: the model's commands,
    /// and the steps of each quick action under its line.
    public func commands(of episode: Episode) -> [EpisodeLine] {
        lines(of: episode).flatMap { [$0] + $0.steps }.filter { $0.callID != nil }
    }

    /// The line a search matched in an episode, while the base lists a search's results.
    public func matchedLineID(in episode: Episode) -> String? {
        items.first { $0.episode.number == episode.number }?.matchedLineID
    }

    /// Everything known about one command of an episode, as the panel's inspector shows it.
    /// Its result can be in the next episode, when the app quit while it ran.
    public func call(_ callID: String, in episode: Episode) -> InspectedToolCall? {
        let count = contents.entries.count
        let start = min(episode.range.lowerBound, count)
        let end = min(contents.episode(numbered: episode.number + 1)?.range.upperBound ?? episode.range.upperBound, count)
        return Transcript(entries: contents.entries[start..<max(start, end)], summaries: summaries).toolCall(callID)
    }

    /// What the pane at a depth of the path shows, or nil when the path does not reach that
    /// depth or names something that is not there.
    public func pane(at depth: Int, of path: PaneStackPath) -> HistoryPane? {
        guard depth <= path.depth else { return nil }
        switch depth {
        case 0:
            return .episodes
        case 1:
            return episode(path.entry(at: 1)).map(HistoryPane.episode)
        case 2:
            guard let episode = episode(path.entry(at: 1)), let callID = path.entry(at: 2),
                  let line = commands(of: episode).first(where: { $0.callID == callID }) else { return nil }
            return .command(line, call: call(callID, in: episode), in: episode)
        default:
            return nil
        }
    }

    /// The longest start of the path that names episodes and commands that are here.
    public func validPrefix(of path: PaneStackPath) -> PaneStackPath {
        var depth = 0
        while depth < Swift.min(path.depth, 2), pane(at: depth + 1, of: path) != nil { depth += 1 }
        return path.prefix(depth)
    }

    /// The path that shows an item: an episode's number opens it, and a command's call id opens
    /// its episode and the command. Nil when there is no such episode or command.
    public func path(showing item: String) -> PaneStackPath? {
        if episode(item) != nil { return PaneStackPath([item]) }
        for episode in contents.episodes.reversed() where episode.hasActivity && episode.hasSomethingToShow {
            if commands(of: episode).contains(where: { $0.callID == item }) {
                return PaneStackPath([Self.id(of: episode), item])
            }
        }
        return nil
    }

    /// The ids the top pane of a path lists, top to bottom, which a swap's direction follows:
    /// the episodes as the base lists them, or an episode's commands. A command lists nothing.
    public func rows(of path: PaneStackPath) -> [String] {
        switch pane(at: path.depth, of: path) {
        case .episodes: items.map { Self.id(of: $0.episode) }
        case .episode(let episode): commands(of: episode).compactMap(\.callID)
        case .command, nil: []
        }
    }
}
