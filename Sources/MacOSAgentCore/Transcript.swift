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
        /// Something the owner did without a message, with the panel with bars experiment on:
        /// a quick action that ran or failed, or an app they opened. One small centered line.
        case line(TranscriptLine)
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
    /// The images on the owner's message, which the row shows as thumbnails. None on any other row.
    public var images: [ImageAttachment]

    public init(id: String, kind: Kind, images: [ImageAttachment] = []) {
        self.id = id
        self.kind = kind
        self.images = images
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

    public var isLine: Bool {
        if case .line = kind { true } else { false }
    }

    /// How much room goes above a row, which is what groups the history into exchanges.
    public enum Gap: Equatable, Sendable {
        /// The first row.
        case none
        /// Between two commands in a run, so the run reads as one block.
        case tight
        /// Between two lines for things the owner did without a message. Each is its own line.
        case betweenLines
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
        if previous.isLine && row.isLine { return .betweenLines }
        return .regular
    }

    public static func outcome(ofOutput output: String?) -> ToolOutcome {
        guard let output else { return .unknown }
        // The native tools that ask, such as Reminders and quitting an app, start this way.
        if output == ShellCommandTool.declinedOutput || output.hasPrefix("The owner declined.") { return .declined }
        // The shell tool's outputs, the loop's for a call that never ran or never finished, and
        // the native tools', which all start the same way.
        if output == ShellCommandTool.stoppedBeforeRunningOutput || output.contains(ShellCommandTool.stoppedWhileRunningNote)
            || output == AgentLoop.unfinishedOutput || output.hasPrefix("The task was stopped before ")
        {
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
    /// What a tool call's row says, from the tools themselves.
    private let summaries: ToolCallSummaries
    /// With the panel with bars experiment on: a quick action's run is one line, in place of
    /// the typed text and a row per step, and an app the owner opened is a line too. Off, both
    /// read as they always have, and an opening shows nothing.
    public let showsLines: Bool
    /// The entry id of a quick action that is running while `showsLines` is on. Its steps get
    /// no rows of their own.
    private var runningActionID: UUID?

    /// - Parameter summaries: The tools whose summaries the rows show. A call to a tool that is
    ///   not among them shows the tool's name.
    ///   - showsLines: Draws what the owner did without a message as one line each, for the
    ///     panel with bars experiment.
    public init(calendar: Calendar = .current, summaries: ToolCallSummaries = .builtIn, showsLines: Bool = false) {
        self.calendar = calendar
        self.summaries = summaries
        self.showsLines = showsLines
    }

    /// Builds the rows for a thread loaded from disk. A command that never got a result, because
    /// the app quit or the task stopped while it ran, is shown as finished rather than running.
    /// Each tool call shows the summary its tool gives, as it did while it ran.
    public init(
        entries: some Sequence<ThreadEntry>, calendar: Calendar = .current, summaries: ToolCallSummaries = .builtIn,
        showsLines: Bool = false
    ) {
        self.init(calendar: calendar, summaries: summaries, showsLines: showsLines)
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
        case .userMessage(let text, _, let action, let images):
            if let action {
                if showsLines {
                    applyActionLine(action, text: text, entry: entry)
                } else {
                    applyActionRun(action, text: text, entry: entry)
                }
                break
            }
            let showsTime = lastUserDate != nil
                && Self.startsNewStretch(previous: lastUserDate, current: entry.date, calendar: calendar)
            lastUserDate = entry.date
            append(TranscriptRow(
                id: entry.id.uuidString, kind: .user(text: text, date: entry.date, showsTime: showsTime), images: images))
        case .assistantMessage(let message):
            if !message.text.isEmpty {
                append(TranscriptRow(id: entry.id.uuidString, kind: .assistant(message.text)))
            }
        case .toolCall(let call):
            let command = summaries.summary(of: call)
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
        case .providerItem(let item):
            // Reasoning shows nothing. A hosted tool call, such as OpenAI's web search, is a
            // tool row like any other, filled in from the finished item, so a row rebuilt from
            // the saved thread reads the same as the live one.
            if let call = item.hostedToolCall { applyHostedCall(call, item: item, entry: entry) }
        case .appOpened(let opening):
            // With the experiment off an opening shows nothing, as before it was logged.
            guard showsLines else { break }
            append(TranscriptRow(id: entry.id.uuidString, kind: .line(.opened(opening, date: entry.date))))
        }
    }

    /// A quick action's run as one line: "Ran" and its name, or its name and why it failed.
    /// The line the run showed while it ran is filled in where it is.
    private mutating func applyActionLine(_ action: ThreadItem.QuickActionRun, text: String, entry: ThreadEntry) {
        let id = entry.id.uuidString
        if runningActionID == entry.id { runningActionID = nil }
        lastUserDate = entry.date
        let line = TranscriptLine.ran(action, typed: text, date: entry.date)
        if let index = indexByID[id] {
            rows[index].kind = .line(line)
        } else {
            append(TranscriptRow(id: id, kind: .line(line)))
        }
    }

    /// The row of a call the model ran on the provider's side. While it runs, the loop's
    /// started and running events made the row. The finished item fills it in, or adds it
    /// when the thread is loaded from disk.
    private mutating func applyHostedCall(_ call: HostedToolCall, item: ThreadItem.ProviderItem, entry: ThreadEntry) {
        var facts = toolFacts[call.callID] ?? ToolCallFacts()
        facts.call = ThreadItem.ToolCall(
            callID: call.callID, name: call.name, arguments: call.arguments.encodedString(),
            provider: item.provider, model: item.model, providerID: call.callID)
        if facts.calledAt == nil { facts.calledAt = entry.date }
        // Only a call seen running has a duration. One loaded from disk has no start time.
        if facts.runningSince != nil { facts.finishedAt = entry.date }
        facts.details = ToolRunDetails(source: call.host)
        toolFacts[call.callID] = facts
        let output: String? = call.status == .running ? nil : call.output
        let status: TranscriptRow.ToolStatus = call.status == .running ? .running : .finished
        if indexByID[call.callID] == nil {
            append(TranscriptRow(id: call.callID, kind: .tool(command: call.summary, status: status, output: output)))
        } else {
            updateTool(call.callID) { command, rowStatus, rowOutput in
                command = call.summary
                rowStatus = status
                rowOutput = output
            }
        }
    }

    /// A quick action began running: the owner's typed text shows as their message at once, and
    /// each step adds its row as it starts, under the call ids the run gives it. The run's entry
    /// fills them in when it ends, through `apply`.
    public mutating func beginActionRun(_ start: QuickActionRunStart) {
        let id = start.entryID.uuidString
        guard indexByID[id] == nil else { return }
        // The very first entry of a thread starts an episode. Its separator has to come first.
        if tracker.lastActivity == nil, pendingSeparator == nil, rows.isEmpty { beginEpisode(at: start.date) }
        if showsLines {
            runningActionID = start.entryID
            append(TranscriptRow(id: id, kind: .line(TranscriptLine(
                verb: TranscriptLine.running, name: start.name, icon: .quickAction, typed: start.text, date: start.date))))
            return
        }
        let showsTime = lastUserDate != nil
            && Self.startsNewStretch(previous: lastUserDate, current: start.date, calendar: calendar)
        append(TranscriptRow(id: id, kind: .user(text: start.text, date: start.date, showsTime: showsTime)))
    }

    /// The rows of an action's run: the typed text, a row per step that ran with its output, and
    /// a line saying where it stopped when a step failed. Rows the run already showed while it
    /// ran are filled in where they are.
    private mutating func applyActionRun(_ action: ThreadItem.QuickActionRun, text: String, entry: ThreadEntry) {
        let id = entry.id.uuidString
        if indexByID[id] == nil {
            let showsTime = lastUserDate != nil
                && Self.startsNewStretch(previous: lastUserDate, current: entry.date, calendar: calendar)
            append(TranscriptRow(id: id, kind: .user(text: text, date: entry.date, showsTime: showsTime)))
        }
        lastUserDate = entry.date
        for step in action.steps {
            let call = step.call
            toolFacts[call.callID, default: ToolCallFacts()].call = call
            toolFacts[call.callID]?.calledAt = step.details?.started ?? entry.date
            toolFacts[call.callID]?.details = step.details
            if let started = step.details?.started, let seconds = step.details?.seconds {
                toolFacts[call.callID]?.finishedAt = started.addingTimeInterval(seconds)
            }
            let command = summaries.summary(of: call)
            if indexByID[call.callID] == nil {
                append(TranscriptRow(id: call.callID, kind: .tool(command: command, status: .finished, output: step.output)))
            } else {
                updateTool(call.callID) { existing, status, output in
                    existing = command
                    status = .finished
                    output = step.output
                }
            }
        }
        if let notice = action.outcomeNotice {
            let noticeID = "\(id)-outcome"
            if indexByID[noticeID] == nil { append(TranscriptRow(id: noticeID, kind: .error(notice))) }
        }
    }

    /// The model began a call whose arguments have not arrived yet.
    public mutating func toolStarted(_ callID: String) {
        guard indexByID[callID] == nil else { return }
        // A running quick action's steps have no rows when it is drawn as one line.
        if let runningActionID, callID.hasPrefix(runningActionID.uuidString) { return }
        append(TranscriptRow(id: callID, kind: .tool(command: "", status: .preparing, output: nil)))
    }

    /// A tool began running with this summary of what it does. The loop's summary uses literal
    /// names, so a call to an MCP tool keeps the row's reading by display names when the rows
    /// show them.
    public mutating func toolRunning(_ callID: String, command: String, at date: Date = Date()) {
        if indexByID[callID] != nil, toolFacts[callID]?.runningSince == nil {
            toolFacts[callID, default: ToolCallFacts()].runningSince = date
        }
        let command = toolFacts[callID]?.call.flatMap { summaries.displaySummary(of: $0) } ?? command
        updateTool(callID) { existing, status, _ in
            existing = command
            if status == .preparing { status = .running }
        }
    }

    /// After a stopped task: a call row that is still preparing, running, or waiting, such as
    /// one the model began writing when its reply was cut off, reads as stopped. The loop
    /// answers every call that reached the thread, so this only touches rows it never wrote.
    public mutating func stopUnfinishedTools() {
        for index in rows.indices {
            if case .tool(let command, let status, let output) = rows[index].kind, status != .finished {
                rows[index].kind = .tool(
                    command: command, status: .finished, output: output ?? AgentLoop.stoppedBeforeRunningOutput)
            }
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

    /// The words a call's row leads with when they are more than its first word, such as an MCP
    /// tool's display name. Nil for most calls, whose first word leads.
    public func summaryLead(_ callID: String) -> String? {
        toolFacts[callID]?.call.flatMap { summaries.displayLead(of: $0) }
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

/// A line in the conversation for something the owner did without a message, with the panel
/// with bars experiment on: "Ran", a quick action's icon, and its name; "Opened", an app's own
/// icon, and its name; or a quick action's icon, its name, and why it failed. It is drawn
/// centered and faint, like a time stamp, and a failure in red.
public struct TranscriptLine: Equatable, Sendable {
    public enum Icon: Equatable, Sendable {
        /// A quick action's symbol.
        case quickAction
        /// The app's own icon, read from its bundle.
        case application(path: String)
    }

    public static let ran = "Ran"
    public static let opened = "Opened"
    /// While a quick action runs. The panel is hidden then, so it is rarely seen.
    public static let running = "Running"

    public var verb: String
    public var name: String
    public var icon: Icon
    /// Why a quick action failed. Nil when it finished, and for an opening.
    public var failure: String?
    /// What the owner typed for a quick action, which Up Arrow still recalls.
    public var typed: String?
    public var date: Date

    public init(verb: String, name: String, icon: Icon, failure: String? = nil, typed: String? = nil, date: Date) {
        self.verb = verb
        self.name = name
        self.icon = icon
        self.failure = failure
        self.typed = typed
        self.date = date
    }

    public var isFailure: Bool { failure != nil }

    /// The words after the icon: the name, and for a failure "failed:" and why.
    public var trailingText: String {
        guard let failure else { return name }
        return "\(name) failed: \(failure)"
    }

    /// The words before the icon. A failure has none.
    public var leadingText: String? { isFailure ? nil : verb }

    /// The whole line in words, for VoiceOver.
    public var spokenText: String {
        [leadingText, trailingText].compactMap { $0 }.joined(separator: " ")
    }
}
