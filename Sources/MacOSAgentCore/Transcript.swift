import Foundation

/// One row of the history the panel shows.
public struct TranscriptRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The start of an episode, shown as a quiet separator with its date and time.
        case episodeStart(date: Date)
        /// Something the owner typed. `showsTime` is true when the message starts a new day or
        /// follows a long pause inside an episode, so the panel labels it with its time. The
        /// first message of an episode has the episode's separator instead.
        case user(text: String, date: Date, showsTime: Bool)
        case assistant(String)
        case tool(command: String, status: ToolStatus, output: String?)
        case notice(String)
        case error(String)
    }

    public enum ToolStatus: Equatable, Sendable {
        case preparing
        case waitingForConfirmation
        case running
        case finished
    }

    /// How a finished command ended, read from the exit status line the shell tool appends and
    /// from the outputs it gives when a command does not run.
    public enum ToolOutcome: Equatable, Sendable {
        case succeeded
        case failed
        /// The owner declined the go-ahead, so it never ran.
        case declined
        /// The task was stopped before or while it ran.
        case stopped
        case unknown
    }

    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public var isTool: Bool {
        if case .tool = kind { true } else { false }
    }

    public var isUser: Bool {
        if case .user = kind { true } else { false }
    }

    public var isEpisodeStart: Bool {
        if case .episodeStart = kind { true } else { false }
    }

    /// How much room goes above a row, which is what groups the history into exchanges.
    public enum Gap: Equatable, Sendable {
        /// The first row.
        case none
        /// Between two commands in a run, so the run reads as one block.
        case tight
        /// Between rows of one exchange.
        case regular
        /// Above the owner's message that starts the next exchange.
        case exchange
        /// Above an episode's separator, the widest gap, so an episode reads as set apart from
        /// the one before it and not as a mark inside it.
        case episode
        /// Below an episode's separator, above the episode's first row.
        case belowEpisode
    }

    public static func gap(after previous: TranscriptRow?, before row: TranscriptRow) -> Gap {
        guard let previous else { return .none }
        if row.isEpisodeStart { return .episode }
        if previous.isEpisodeStart { return .belowEpisode }
        if row.isUser { return .exchange }
        if previous.isTool && row.isTool { return .tight }
        return .regular
    }

    public static func outcome(ofOutput output: String?) -> ToolOutcome {
        guard let output else { return .unknown }
        if output == ShellCommandTool.declinedOutput { return .declined }
        if output == ShellCommandTool.stoppedBeforeRunningOutput || output.contains(ShellCommandTool.stoppedWhileRunningNote) {
            return .stopped
        }
        if output.hasSuffix("[exit status 0]") { return .succeeded }
        if output.contains("[exit status") || output.hasPrefix("Error:") { return .failed }
        return .unknown
    }
}

/// The whole thread turned into display rows. Rows are only appended or updated in place,
/// never removed, so a row's index stays valid and lookups by call id stay cheap on a long
/// thread.
///
/// Each episode starts with an `episodeStart` row. The panel shows the rows from the current
/// episode's separator on as a fresh page, with the earlier ones above it.
public struct Transcript: Equatable, Sendable {
    /// A gap this long between two of the owner's messages starts a new stretch with a time label.
    public static let quietGap: TimeInterval = 30 * 60

    public private(set) var rows: [TranscriptRow] = []
    /// The row of the current episode's separator. Nil before anything was added.
    public private(set) var currentEpisodeStartRow: Int?
    private var indexByID: [String: Int] = [:]
    /// What the inspector shows about each tool call beyond its row, by call id.
    private var toolFacts: [String: ToolCallFacts] = [:]
    private var lastUserDate: Date?
    private var tracker = EpisodeTracker()
    /// Activity in the current episode, for deciding whether it has timed out.
    private var currentEpisodeHasActivity = false
    /// A separator added by `beginEpisode(at:)` that no entry has claimed yet.
    private var pendingSeparator: Int?
    private let calendar: Calendar

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Builds the rows for a thread loaded from disk. A command that never got a result, because
    /// the app quit or the task stopped while it ran, is shown as finished rather than running.
    public init(entries: some Sequence<ThreadEntry>, calendar: Calendar = .current) {
        self.init(calendar: calendar)
        for entry in entries { apply(entry) }
        for index in rows.indices {
            if case .tool(let command, let status, let output) = rows[index].kind, status != .finished {
                rows[index].kind = .tool(command: command, status: .finished, output: output)
            }
        }
    }

    public static func == (lhs: Transcript, rhs: Transcript) -> Bool {
        lhs.rows == rhs.rows
    }

    /// When the current episode last had activity.
    public var lastActivity: Date? { tracker.lastActivity }

    /// Whether the owner writing at `now` would start a new episode. Matches the rule the
    /// agent loop uses, so the panel opens fresh exactly when the next message will start one.
    public func currentEpisodeHasTimedOut(now: Date, timeout: TimeInterval) -> Bool {
        guard pendingSeparator == nil, currentEpisodeHasActivity, let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= timeout
    }

    /// Whether a fresh episode has been started in the panel that no message has filled yet.
    public var hasPendingEpisode: Bool { pendingSeparator != nil }

    /// Starts a fresh page in the panel before any entry exists for it, such as after `/new`.
    /// The next entry that starts an episode takes this separator over instead of adding its own.
    public mutating func beginEpisode(at date: Date) {
        guard pendingSeparator == nil else { return }
        let id = "episode-pending-\(UUID().uuidString)"
        append(TranscriptRow(id: id, kind: .episodeStart(date: date)))
        pendingSeparator = rows.count - 1
        currentEpisodeStartRow = rows.count - 1
        lastUserDate = nil
    }

    /// Adds one thread entry.
    public mutating func apply(_ entry: ThreadEntry) {
        if tracker.observe(entry) {
            if let pending = pendingSeparator {
                rows[pending].kind = .episodeStart(date: entry.date)
            } else {
                append(TranscriptRow(id: "episode-\(entry.id.uuidString)", kind: .episodeStart(date: entry.date)))
                currentEpisodeStartRow = rows.count - 1
            }
            lastUserDate = nil
            currentEpisodeHasActivity = false
        }
        pendingSeparator = nil
        if case .episodeStart = entry.item {} else { currentEpisodeHasActivity = true }

        switch entry.item {
        case .episodeStart:
            break
        case .userMessage(let text):
            let showsTime = lastUserDate != nil
                && Self.startsNewStretch(previous: lastUserDate, current: entry.date, calendar: calendar)
            lastUserDate = entry.date
            append(TranscriptRow(id: entry.id.uuidString, kind: .user(text: text, date: entry.date, showsTime: showsTime)))
        case .assistantMessage(let message):
            if !message.text.isEmpty {
                append(TranscriptRow(id: entry.id.uuidString, kind: .assistant(message.text)))
            }
        case .toolCall(let call):
            let command = JSONValue.parse(call.arguments)?["command"]?.stringValue ?? call.name
            toolFacts[call.callID, default: ToolCallFacts()].call = call
            toolFacts[call.callID]?.calledAt = entry.date
            if indexByID[call.callID] != nil {
                updateTool(call.callID) { existing, _, _ in existing = command }
            } else {
                append(TranscriptRow(id: call.callID, kind: .tool(command: command, status: .preparing, output: nil)))
            }
        case .toolResult(let result):
            if indexByID[result.callID] != nil {
                toolFacts[result.callID, default: ToolCallFacts()].finishedAt = entry.date
                toolFacts[result.callID]?.details = result.details
            }
            updateTool(result.callID) { _, status, output in
                status = .finished
                output = result.output
            }
        case .providerItem:
            break
        }
    }

    /// The model began a call whose arguments have not arrived yet.
    public mutating func toolStarted(_ callID: String) {
        guard indexByID[callID] == nil else { return }
        append(TranscriptRow(id: callID, kind: .tool(command: "", status: .preparing, output: nil)))
    }

    /// A tool began running with this summary of what it does.
    public mutating func toolRunning(_ callID: String, command: String, at date: Date = Date()) {
        if indexByID[callID] != nil, toolFacts[callID]?.runningSince == nil {
            toolFacts[callID, default: ToolCallFacts()].runningSince = date
        }
        updateTool(callID) { existing, status, _ in
            existing = command
            if status == .preparing { status = .running }
        }
    }

    public mutating func setToolStatus(_ callID: String, _ newStatus: TranscriptRow.ToolStatus, at date: Date = Date()) {
        if newStatus == .waitingForConfirmation, indexByID[callID] != nil {
            toolFacts[callID, default: ToolCallFacts()].waitingSince = date
        }
        updateTool(callID) { _, status, _ in status = newStatus }
    }

    /// Everything known about a tool call, for the inspector. Nil when there is no such call.
    public func toolCall(_ callID: String) -> InspectedToolCall? {
        guard let index = indexByID[callID], case .tool(let command, let status, let output) = rows[index].kind else { return nil }
        return InspectedToolCall(
            callID: callID, summary: command, status: status, output: output,
            facts: toolFacts[callID] ?? ToolCallFacts())
    }

    /// The ids of every tool call, oldest first, for moving between them in the inspector.
    public var toolCallIDs: [String] {
        rows.compactMap { $0.isTool ? $0.id : nil }
    }

    public mutating func appendNotice(_ text: String, id: String = UUID().uuidString) {
        append(TranscriptRow(id: id, kind: .notice(text)))
    }

    public mutating func appendError(_ text: String, id: String = UUID().uuidString) {
        append(TranscriptRow(id: id, kind: .error(text)))
    }

    /// Whether a message sent at `current` gets a time label, given when the owner's previous
    /// message was sent. The first message, a new day, and a long pause each start a stretch.
    public static func startsNewStretch(previous: Date?, current: Date, calendar: Calendar = .current) -> Bool {
        guard let previous else { return true }
        if !calendar.isDate(previous, inSameDayAs: current) { return true }
        return current.timeIntervalSince(previous) >= quietGap
    }

    private mutating func append(_ row: TranscriptRow) {
        indexByID[row.id] = rows.count
        rows.append(row)
    }

    private mutating func updateTool(_ callID: String, _ change: (inout String, inout TranscriptRow.ToolStatus, inout String?) -> Void) {
        guard let index = indexByID[callID],
              case .tool(var command, var status, var output) = rows[index].kind
        else { return }
        change(&command, &status, &output)
        rows[index].kind = .tool(command: command, status: status, output: output)
    }
}

/// The short time labels the history shows above the start of each stretch.
public enum TranscriptTimeLabel {
    /// "9:41 AM" today, "Yesterday 9:41 AM", "Monday 9:41 AM" within the last week,
    /// "Nov 3, 9:41 AM" earlier this year, and "Nov 3, 2025" before that.
    public static func text(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDay = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: startOfDay, to: startOfToday).day ?? 0

        if days <= 0 { return time }
        if days == 1 { return "Yesterday \(time)" }
        if days < 7 {
            let weekday = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).weekday(.wide))
            return "\(weekday) \(time)"
        }
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day()
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(date.formatted(base)), \(time)"
        }
        return date.formatted(base.year())
    }

    /// The label on an episode's separator, which always has the time: "Today 9:41 AM",
    /// "Yesterday 9:41 AM", "Monday 9:41 AM", "Nov 3, 9:41 AM", and "Nov 3, 2025, 9:41 AM".
    public static func episodeText(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var calendar = calendar
        calendar.locale = locale
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today \(time)" }
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) {
            let day = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day().year())
            return "\(day), \(time)"
        }
        return text(for: date, now: now, calendar: calendar, locale: locale)
    }

    /// The full date and time, for the tooltip on every message.
    public static func fullText(for date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        date.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
    }
}
