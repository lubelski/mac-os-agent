import Foundation

/// What History makes of one thread entry. History has whatever happened: every kind of entry
/// is decided here, once, and Settings, History, its search, the episode counts, and the
/// agent's `search_history` and `read_episode` all read the thread through it, so they never
/// disagree about what an episode holds.
///
/// An entry either reads as something that happened, or folds into one that does, for a
/// stated reason.
enum HistoryReading: Equatable {
    /// What the owner typed and sent, with the images they attached to it.
    case owner(String, images: [ImageAttachment])
    /// The agent's reply.
    case agent(String)
    /// A tool the model called, which ran here.
    case command(ThreadItem.ToolCall)
    /// A tool the model ran on the provider's side, such as OpenAI's hosted web search.
    case hostedCommand(HostedToolCall)
    /// A quick action the owner ran from the instant row, with what they typed for it.
    case quickAction(typed: String, run: ThreadItem.QuickActionRun)
    /// An app the owner opened from the instant row.
    case appOpened(ThreadItem.AppOpening)
    /// The marker that starts an episode. It is not a line: the episode says why it started.
    case episodeStart(ThreadItem.EpisodeStart.Reason)
    /// An entry with no line of its own.
    case folded(Folded)

    enum Folded: Equatable {
        /// A tool's result. Its command's line says how it ended. Its output is not shown or
        /// searched, since it is long and mostly noise. `read_episode` gives the start of it.
        case toolResult
        /// Reasoning or another item only the provider can read. It holds nothing to show.
        case providerOnly
        /// A reply with no text, such as one that only called tools. Its calls are lines.
        case emptyReply
    }

    static func of(_ item: ThreadItem) -> HistoryReading {
        switch item {
        case .userMessage(let text, _, let action, let images):
            if let action { return .quickAction(typed: text, run: action) }
            return .owner(text, images: images)
        case .assistantMessage(let message):
            return message.text.isEmpty ? .folded(.emptyReply) : .agent(message.text)
        case .providerItem(let item):
            return item.hostedToolCall.map(HistoryReading.hostedCommand) ?? .folded(.providerOnly)
        case .toolCall(let call):
            return .command(call)
        case .toolResult:
            return .folded(.toolResult)
        case .episodeStart(let start):
            return .episodeStart(start.reason)
        case .appOpened(let opening):
            return .appOpened(opening)
        }
    }
}

extension TranscriptLine {
    /// "Opened" and the app, as the panel's line and History both say it.
    public static func opened(_ opening: ThreadItem.AppOpening, date: Date) -> TranscriptLine {
        TranscriptLine(verb: opened, name: opening.name, icon: .application(path: opening.path), date: date)
    }

    /// "Ran" and the quick action, or its name and why it failed, as the panel's line and
    /// History both say it.
    public static func ran(_ run: ThreadItem.QuickActionRun, typed: String, date: Date) -> TranscriptLine {
        TranscriptLine(verb: ran, name: run.name, icon: .quickAction, failure: run.failureReason, typed: typed, date: date)
    }
}
