import Foundation

/// One stretch of the thread, from a fresh start to the next one. The thread stays a single
/// append-only chain. Episodes only say where it divides.
///
/// Only the current episode goes to the model. The panel opens on it, with earlier episodes
/// above, out of view.
public struct Episode: Sendable, Equatable, Identifiable {
    /// The id of the episode's first entry: its marker, or for a derived episode its first message.
    public var id: UUID
    /// Counts from 1 at the start of the thread. It never changes, because the thread is only
    /// appended to and the episodes before the first marker are derived with a fixed pause.
    public var number: Int
    /// Where the episode's entries sit in the thread.
    public var range: Range<Int>
    public var startDate: Date
    /// When the last message, reply, command, or result in the episode was written.
    public var lastActivity: Date
    /// The owner's messages and the agent's replies with text. A quick action's run is not
    /// one: it counts in `quickActionCount`.
    public var messageCount: Int
    /// Tools the model ran: here, or on the provider's side, such as a hosted web search.
    public var commandCount: Int
    /// Quick actions the owner ran from the instant row.
    public var quickActionCount: Int = 0
    /// Apps the owner opened from the instant row.
    public var appOpenedCount: Int = 0
    /// Why the episode started, from its marker. Nil for the first episode and for one derived
    /// from a pause, which have none.
    public var startReason: ThreadItem.EpisodeStart.Reason?
    /// The first line of the owner's first message, for lists of episodes. With no message,
    /// the first thing that happened, such as "Opened Slack".
    public var preview: String { messagePreview.isEmpty ? eventPreview : messagePreview }
    var messagePreview = ""
    var eventPreview = ""

    /// False for an episode that holds only its marker so far.
    public var hasActivity: Bool { activityCount > 0 }
    var activityCount: Int

    /// Whether History has anything to show for it. An episode can have activity and still
    /// hold nothing to show: a marker followed only by answers to calls the episode before
    /// left open, when what came next failed to be written.
    public var hasSomethingToShow: Bool {
        messageCount + commandCount + quickActionCount + appOpenedCount > 0
    }

    /// What the episode holds, for lists of episodes: "4 messages, 2 commands", with "1 quick
    /// action" and "2 apps opened" after them when it has those. With no messages it says what
    /// there is instead: "Opened 2 apps", or "Ran 1 quick action, opened 1 app".
    public var summary: String {
        func count(_ number: Int, _ one: String, _ many: String) -> String {
            number == 1 ? "1 \(one)" : "\(number) \(many)"
        }
        var parts: [String] = []
        if messageCount > 0 {
            parts.append(count(messageCount, "message", "messages"))
            if commandCount > 0 { parts.append(count(commandCount, "command", "commands")) }
            if quickActionCount > 0 { parts.append(count(quickActionCount, "quick action", "quick actions")) }
            if appOpenedCount > 0 { parts.append(count(appOpenedCount, "app opened", "apps opened")) }
            return parts.joined(separator: ", ")
        }
        if quickActionCount > 0 { parts.append("ran " + count(quickActionCount, "quick action", "quick actions")) }
        if appOpenedCount > 0 { parts.append("opened " + count(appOpenedCount, "app", "apps")) }
        if commandCount > 0 { parts.append(count(commandCount, "command", "commands")) }
        guard !parts.isEmpty else { return "Nothing to show" }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Why the episode started, as a quiet caption: after the episode before it went idle, or
    /// fresh because the owner asked. Nil for the first episode.
    public var startCaption: String? {
        switch startReason {
        case .timeout: "Started after the episode before it went idle"
        case .requested: "Started fresh, as asked"
        case nil: number == 1 ? nil : "Started after a pause of 30 minutes or more"
        }
    }

    /// True when the owner writing at `now` starts a new episode: something happened in this
    /// one, and it has been idle at least `timeout`.
    public func hasTimedOut(now: Date, timeout: TimeInterval) -> Bool {
        hasActivity && now.timeIntervalSince(lastActivity) >= timeout
    }
}

/// Decides where episodes begin, one entry at a time, so the thread store, the panel's
/// history, and the search all divide the thread the same way.
///
/// - An episode marker always starts an episode.
/// - The first entry of the thread starts the first one.
/// - Before the first marker, in the part of the thread written before episodes existed, an
///   owner's message starts one when the episode before it has been idle for `legacyPause` or
///   more. The pause is fixed, not the owner's timeout setting, so episode numbers never change.
public struct EpisodeTracker: Sendable, Equatable {
    public static let legacyPause: TimeInterval = 30 * 60

    private var seenMarker = false
    private var currentHasActivity = false
    public private(set) var lastActivity: Date?
    /// How many episodes have started so far.
    public private(set) var count = 0

    public init() {}

    /// Notes an entry. Returns true when it is the first entry of a new episode.
    public mutating func observe(_ entry: ThreadEntry) -> Bool {
        var starts = false
        if case .episodeStart = entry.item {
            seenMarker = true
            starts = true
            currentHasActivity = false
        } else {
            if count == 0 {
                starts = true
            } else if !seenMarker, currentHasActivity, case .userMessage = entry.item,
                      let lastActivity, entry.date.timeIntervalSince(lastActivity) >= Self.legacyPause
            {
                starts = true
            }
            currentHasActivity = true
        }
        lastActivity = entry.date
        if starts { count += 1 }
        return starts
    }
}

/// The thread's entries and their episodes, kept up to date as entries are added.
public struct ThreadContents: Sendable, Equatable {
    public private(set) var entries: [ThreadEntry] = []
    public private(set) var episodes: [Episode] = []
    private var tracker = EpisodeTracker()

    public init() {}

    public init(entries: some Sequence<ThreadEntry>) {
        for entry in entries { add(entry) }
    }

    public mutating func add(_ entry: ThreadEntry) {
        let position = entries.count
        entries.append(entry)
        if tracker.observe(entry) || episodes.isEmpty {
            episodes.append(Episode(
                id: entry.id, number: episodes.count + 1, range: position..<position, startDate: entry.date,
                lastActivity: entry.date, messageCount: 0, commandCount: 0, activityCount: 0))
        }
        var episode = episodes[episodes.count - 1]
        episode.range = episode.range.lowerBound..<(position + 1)
        episode.lastActivity = entry.date
        // Every entry but the marker is activity, which the timeout counts from. What it
        // counts as is History's reading of it.
        if case .episodeStart = entry.item {} else { episode.activityCount += 1 }
        switch HistoryReading.of(entry.item) {
        case .episodeStart(let reason):
            episode.startReason = reason
        case .owner(let text, let images):
            episode.messageCount += 1
            if episode.messagePreview.isEmpty {
                episode.messagePreview = Self.firstLine(ImageAttachment.historyText(Self.firstLine(text), images: images))
            }
        case .agent:
            episode.messageCount += 1
        case .command, .hostedCommand:
            episode.commandCount += 1
        case .quickAction(let typed, let run):
            episode.quickActionCount += 1
            if episode.eventPreview.isEmpty {
                episode.eventPreview = TranscriptLine.ran(run, typed: typed, date: entry.date).spokenText
            }
        case .appOpened(let opening):
            episode.appOpenedCount += 1
            if episode.eventPreview.isEmpty {
                episode.eventPreview = TranscriptLine.opened(opening, date: entry.date).spokenText
            }
        case .folded:
            break
        }
        episodes[episodes.count - 1] = episode
    }

    public var currentEpisode: Episode? { episodes.last }

    /// The entries of an episode, without its marker. This is what the model sees.
    public func entries(of episode: Episode) -> [ThreadEntry] {
        entries[episode.range].filter {
            if case .episodeStart = $0.item { false } else { true }
        }
    }

    /// The current episode's entries, without its marker.
    public var currentEpisodeEntries: [ThreadEntry] {
        currentEpisode.map(entries(of:)) ?? []
    }

    public func episode(numbered number: Int) -> Episode? {
        guard number >= 1, number <= episodes.count else { return nil }
        return episodes[number - 1]
    }

    /// The episode that holds the entry at `position`.
    public func episode(containing position: Int) -> Episode? {
        var low = 0
        var high = episodes.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = episodes[middle].range
            if position < range.lowerBound { high = middle - 1 }
            else if position >= range.upperBound { low = middle + 1 }
            else { return episodes[middle] }
        }
        return nil
    }

    static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }
}

/// How long the thread can sit idle before the owner's next message starts a new episode.
/// Kept in the app's preferences, in minutes.
public enum EpisodeTimeoutSetting {
    public static let key = "episodeTimeoutMinutes"
    public static let defaultMinutes = 30
    /// The choices Settings offers.
    public static let choices = [5, 10, 15, 30, 60, 120, 240, 480]

    public static func minutes(_ defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : defaultMinutes
    }

    public static func current(_ defaults: UserDefaults = .standard) -> TimeInterval {
        TimeInterval(minutes(defaults) * 60)
    }

    public static func set(minutes: Int, _ defaults: UserDefaults = .standard) {
        defaults.set(max(1, minutes), forKey: key)
    }

    /// A timeout in words, such as "30 minutes", "1 hour", or "8 hours".
    public static func describe(_ timeout: TimeInterval) -> String {
        let minutes = Int((timeout / 60).rounded())
        if minutes % 60 == 0, minutes >= 60 {
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
