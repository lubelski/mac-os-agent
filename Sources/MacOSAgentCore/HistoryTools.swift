import Foundation

/// Searches every past episode of the kept thread: the owner's messages, the agent's replies,
/// and the commands that ran. Each match comes with its date, its episode, and the entries
/// around it. An incognito window does not have it.
public struct SearchHistoryTool: AgentTool {
    public static let name = "search_history"
    public static let defaultLimit = 8
    public static let maximumLimit = 20
    static let unavailable = "Error: the conversation history could not be opened, so it cannot be searched."

    /// Nil when the thread could not be opened. The tool stays in the list, so the list never
    /// changes, and says that history is not available.
    public let history: ThreadStore?
    public let timeZone: TimeZone

    public init(history: ThreadStore?, timeZone: TimeZone = .current) {
        self.history = history
        self.timeZone = timeZone
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Search the earlier episodes of your conversation with the person, which are not in view. \
                Finds their messages, your replies, and the commands that ran, by words they contain. \
                Returns the best matches with their dates, the episode each is in, and the messages \
                around them. Use \(ReadEpisodeTool.name) to read more of an episode.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "Words to look for, such as wallpaper sunset. Every word must match, or the start of one."],
                    "limit": ["type": ["integer", "null"], "description": .string("The most matches to return, from 1 to \(Self.maximumLimit). Null for \(Self.defaultLimit).")],
                ],
                "required": ["query", "limit"],
                "additionalProperties": false,
            ])
    }

    public func summary(arguments: JSONValue) -> String {
        guard let query = arguments["query"]?.trimmedString, !query.isEmpty else { return "Search history" }
        return "Search history for \"\(query)\""
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !HistorySearchText.words(query).isEmpty
        else {
            return "Error: the call did not include any words to search for."
        }
        guard let history else { return Self.unavailable }
        let requested = arguments["limit"]?.numberValue.map { Int($0) } ?? Self.defaultLimit
        let limit = min(max(requested, 1), Self.maximumLimit)
        let matches = await history.search(query, limit: limit, excludingEpisode: context.episodeID)
        guard !matches.isEmpty else {
            return "Nothing in earlier episodes matches \"\(query)\"."
        }
        let contents = await history.contents
        let text = HistoryText(timeZone: timeZone)

        var sections: [String] = []
        var shown = Set<Int>()
        let matched = Set(matches.map(\.position))
        for match in matches where !shown.contains(match.position) {
            let around = HistoryText.searchable(in: contents, episode: match.episode)
            guard let place = around.firstIndex(of: match.position) else { continue }
            let window = around[max(0, place - 2)...min(around.count - 1, place + 2)]
            var lines = [text.heading(match.episode)]
            for position in window {
                shown.insert(position)
                let marker = matched.contains(position) ? "> " : "  "
                lines.append(marker + text.line(contents.entries[position], limit: 280))
            }
            sections.append(lines.joined(separator: "\n"))
        }
        let count = matches.count == 1 ? "1 match" : "\(matches.count) matches"
        return "\(count) for \"\(query)\", best first. Lines starting with > matched.\n\n" + sections.joined(separator: "\n\n")
    }
}

/// Reads one past episode of the kept thread in order, a page at a time.
public struct ReadEpisodeTool: AgentTool {
    public static let name = "read_episode"
    public static let pageLines = 60
    public static let pageCharacters = 12_000

    /// Nil when the thread could not be opened. The tool stays in the list, so the list never
    /// changes, and says that history is not available.
    public let history: ThreadStore?
    public let timeZone: TimeZone

    public init(history: ThreadStore?, timeZone: TimeZone = .current) {
        self.history = history
        self.timeZone = timeZone
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: Self.name,
            description: """
                Read an earlier episode of your conversation in order: the person's messages, your replies, \
                and the commands that ran with the start of their output. Takes the episode number that \
                \(SearchHistoryTool.name) reports. Long episodes come in pages.
                """,
            parameters: [
                "type": "object",
                "properties": [
                    "episode": ["type": "integer", "description": "The episode's number."],
                    "from_line": ["type": ["integer", "null"], "description": "The line to start at, counting from 1. Null for the start."],
                ],
                "required": ["episode", "from_line"],
                "additionalProperties": false,
            ])
    }

    public func summary(arguments: JSONValue) -> String {
        guard let episode = arguments["episode"]?.numberValue.map({ Int($0) }) else { return "Read an episode" }
        if let line = arguments["from_line"]?.numberValue.map({ Int($0) }), line > 1 {
            return "Read episode \(episode) from line \(line)"
        }
        return "Read episode \(episode)"
    }

    public func run(arguments: JSONValue, context: ToolRunContext) async -> String {
        guard let number = arguments["episode"]?.numberValue.map({ Int($0) }) else {
            return "Error: the call did not include an episode number."
        }
        guard let history else { return SearchHistoryTool.unavailable }
        let contents = await history.contents
        guard let episode = contents.episode(numbered: number), episode.hasActivity else {
            let last = contents.episodes.last { $0.hasActivity }?.number
            return last.map { "Error: there is no episode \(number). Episodes are numbered 1 to \($0)." }
                ?? "Error: there are no earlier episodes."
        }
        let text = HistoryText(timeZone: timeZone)
        let lines = HistoryText.searchableOrResult(in: contents, episode: episode).map {
            text.line(contents.entries[$0], limit: 600)
        }
        let start = max(1, arguments["from_line"]?.numberValue.map { Int($0) } ?? 1)
        guard !lines.isEmpty else {
            return text.heading(episode) + " It holds nothing to read."
        }
        guard start <= lines.count else {
            return "Error: episode \(number) has \(lines.count) lines."
        }
        var page: [String] = []
        var characters = 0
        var index = start - 1
        while index < lines.count, page.count < Self.pageLines, characters + lines[index].count <= Self.pageCharacters || page.isEmpty {
            page.append(lines[index])
            characters += lines[index].count
            index += 1
        }
        var result = text.heading(episode)
        if let caption = episode.startCaption { result += " \(caption)." }
        if episode.id == context.episodeID { result += " This is the current episode." }
        result += "\n" + page.joined(separator: "\n")
        if index < lines.count {
            result += "\n\nLines \(start) to \(index) of \(lines.count). Call \(Self.name) with from_line \(index + 1) for more."
        }
        return result
    }
}

/// How history reads to the model.
struct HistoryText {
    let formatter: DateFormatter

    init(timeZone: TimeZone) {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
    }

    func heading(_ episode: Episode) -> String {
        let messages = episode.messageCount == 1 ? "1 message" : "\(episode.messageCount) messages"
        let commands = episode.commandCount == 1 ? "1 command" : "\(episode.commandCount) commands"
        var heading = "Episode \(episode.number), \(formatter.string(from: episode.startDate)) to \(formatter.string(from: episode.lastActivity)), \(messages) and \(commands)."
        var also: [String] = []
        if episode.quickActionCount > 0 {
            also.append(episode.quickActionCount == 1 ? "1 quick action the person ran" : "\(episode.quickActionCount) quick actions the person ran")
        }
        if episode.appOpenedCount > 0 {
            also.append(episode.appOpenedCount == 1 ? "1 app the person opened" : "\(episode.appOpenedCount) apps the person opened")
        }
        if !also.isEmpty { heading += " Also \(also.joined(separator: " and "))." }
        return heading
    }

    func line(_ entry: ThreadEntry, limit: Int) -> String {
        let time = formatter.string(from: entry.date)
        switch entry.item {
        case .toolResult(let result):
            return "[\(time)] output: \(Self.clipped(result.output, limit: 300))"
        default:
            guard let (kind, body) = HistorySearchText.of(entry.item) else { return "[\(time)]" }
            let label = switch kind {
            case .owner: "person"
            case .agent: "you"
            case .command: "command"
            }
            return "[\(time)] \(label): \(Self.clipped(body, limit: limit))"
        }
    }

    /// The positions of an episode's messages, replies, and commands.
    static func searchable(in contents: ThreadContents, episode: Episode) -> [Int] {
        episode.range.filter { HistorySearchText.of(contents.entries[$0].item) != nil }
    }

    /// The same, with each command's output after it.
    static func searchableOrResult(in contents: ThreadContents, episode: Episode) -> [Int] {
        episode.range.filter {
            let item = contents.entries[$0].item
            if case .toolResult = item { return true }
            return HistorySearchText.of(item) != nil
        }
    }

    static func clipped(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " / ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}

/// One line of a past episode as the History section in Settings shows it. Every entry in the
/// thread has a line here or folds into one, for the reason `HistoryReading` gives: the owner's
/// messages, the agent's replies, the commands that ran here or on the provider's side, the
/// quick actions the owner ran with their steps, and the apps they opened, in order.
public struct EpisodeLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case owner
        case agent
        /// A command, and how it ended once its result is in.
        case command(TranscriptRow.ToolOutcome)
        /// Something the owner did without a message, worded and drawn as the panel's line
        /// for it: a quick action they ran, or an app they opened.
        case event(TranscriptLine)
    }

    public var id: String
    public var date: Date
    public var kind: Kind
    public var text: String
    /// A quick action's steps that ran, each as a command's line.
    public var steps: [EpisodeLine] = []
    /// The images on an owner's message, which History shows as thumbnails beside its text.
    public var images: [ImageAttachment] = []

    /// The lines of an episode. Each command takes its outcome from its result, which may be
    /// in the next episode when the app quit while it ran. A tool call reads as its row in
    /// the panel does.
    public static func lines(of episode: Episode, in contents: ThreadContents, summaries: ToolCallSummaries = .builtIn) -> [EpisodeLine] {
        let end = contents.episode(numbered: episode.number + 1)?.range.upperBound ?? episode.range.upperBound
        var outcomes: [String: TranscriptRow.ToolOutcome] = [:]
        for entry in contents.entries[episode.range.lowerBound..<end] {
            if case .toolResult(let result) = entry.item {
                outcomes[result.callID] = TranscriptRow.outcome(ofOutput: result.output)
            }
        }
        return contents.entries[episode.range].compactMap { line(for: $0, outcomes: outcomes, summaries: summaries) }
    }

    /// One entry's line, or nil for an entry that folds into another or into the episode.
    static func line(
        for entry: ThreadEntry, outcomes: [String: TranscriptRow.ToolOutcome] = [:], summaries: ToolCallSummaries = .builtIn
    ) -> EpisodeLine? {
        let id = entry.id.uuidString
        switch HistoryReading.of(entry.item) {
        case .owner(let text, let images):
            return EpisodeLine(
                id: id, date: entry.date, kind: .owner, text: ImageAttachment.historyText(text, images: images), images: images)
        case .agent(let text):
            return EpisodeLine(id: id, date: entry.date, kind: .agent, text: text)
        case .command(let call):
            return EpisodeLine(id: id, date: entry.date, kind: .command(outcomes[call.callID] ?? .unknown),
                               text: summaries.summary(of: call))
        case .hostedCommand(let call):
            let output: String? = call.status == .running ? nil : call.output
            return EpisodeLine(id: id, date: entry.date, kind: .command(TranscriptRow.outcome(ofOutput: output)), text: call.summary)
        case .quickAction(let typed, let run):
            let line = TranscriptLine.ran(run, typed: typed, date: entry.date)
            let steps = run.steps.map { step in
                EpisodeLine(
                    id: step.callID, date: step.details?.started ?? entry.date,
                    kind: .command(TranscriptRow.outcome(ofOutput: step.output)), text: summaries.summary(of: step.call))
            }
            return EpisodeLine(id: id, date: entry.date, kind: .event(line), text: line.spokenText, steps: steps)
        case .appOpened(let opening):
            let line = TranscriptLine.opened(opening, date: entry.date)
            return EpisodeLine(id: id, date: entry.date, kind: .event(line), text: line.spokenText)
        case .episodeStart, .folded:
            return nil
        }
    }
}

/// An episode as a list of past episodes shows it, with the line that matched a search.
public struct EpisodeListItem: Sendable, Equatable, Identifiable {
    public var episode: Episode
    /// The text of the best match in the episode, when the list is a search.
    public var match: String?
    public var id: UUID { episode.id }

    /// Every episode with something to show, newest first. One that holds only its marker, or
    /// only answers to the episode before's calls, is left out.
    public static func all(in contents: ThreadContents) -> [EpisodeListItem] {
        contents.episodes.reversed().filter { $0.hasActivity && $0.hasSomethingToShow }.map { EpisodeListItem(episode: $0) }
    }

    /// The episodes that match a search, best first, each once, with its best match, which
    /// reads as its line in the episode does.
    public static func matching(_ matches: [HistoryMatch], summaries: ToolCallSummaries = .builtIn) -> [EpisodeListItem] {
        var seen = Set<UUID>()
        return matches.compactMap { match in
            guard seen.insert(match.episode.id).inserted else { return nil }
            let text = EpisodeLine.line(for: match.entry, summaries: summaries)?.text
                ?? HistorySearchText.of(match.entry.item)?.text ?? ""
            return EpisodeListItem(episode: match.episode, match: HistoryText.clipped(text, limit: 200))
        }
    }
}
