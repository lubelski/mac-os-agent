import Foundation

/// What the transcript knows about a tool call beyond its row: the call as the model wrote it,
/// when things happened, and the details stored with its result.
public struct ToolCallFacts: Equatable, Sendable {
    public var call: ThreadItem.ToolCall?
    /// When the model's call was written to the thread.
    public var calledAt: Date?
    /// When the tool began running, seen live in this run of the app.
    public var runningSince: Date?
    /// When the call began waiting for a go-ahead, seen live in this run of the app.
    public var waitingSince: Date?
    /// When the result was written to the thread.
    public var finishedAt: Date?
    public var details: ToolRunDetails?

    public init(
        call: ThreadItem.ToolCall? = nil, calledAt: Date? = nil, runningSince: Date? = nil, waitingSince: Date? = nil,
        finishedAt: Date? = nil, details: ToolRunDetails? = nil
    ) {
        self.call = call
        self.calledAt = calledAt
        self.runningSince = runningSince
        self.waitingSince = waitingSince
        self.finishedAt = finishedAt
        self.details = details
    }
}

/// A tool call as the inspector shows it, put together from its row and its facts.
public struct InspectedToolCall: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case preparing
        case running
        case waitingForGoAhead
        case succeeded
        case failed
        case declined
        case stopped
        case timedOut

        public var text: String {
            switch self {
            case .preparing: "Preparing"
            case .running: "Running"
            case .waitingForGoAhead: "Waiting for your go-ahead"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .declined: "Declined"
            case .stopped: "Stopped"
            case .timedOut: "Timed out"
            }
        }

        public var isFinished: Bool {
            switch self {
            case .preparing, .running, .waitingForGoAhead: false
            default: true
            }
        }
    }

    public var callID: String
    /// The one-line summary the row shows, such as the command.
    public var summary: String
    public var rowStatus: TranscriptRow.ToolStatus
    /// Exactly what was stored as the result. Nil while the call has no result.
    public var output: String?
    public var facts: ToolCallFacts

    public init(callID: String, summary: String, rowStatus: TranscriptRow.ToolStatus, output: String?, facts: ToolCallFacts) {
        self.callID = callID
        self.summary = summary
        self.rowStatus = rowStatus
        self.output = output
        self.facts = facts
    }

    init(callID: String, summary: String, status: TranscriptRow.ToolStatus, output: String?, facts: ToolCallFacts) {
        self.init(callID: callID, summary: summary, rowStatus: status, output: output, facts: facts)
    }

    public var name: String? { facts.call?.name }
    public var arguments: String? { facts.call?.arguments }
    public var isShellCommand: Bool { name == ShellCommandTool.name }

    /// The shell command in full, for a shell call.
    public var command: String? {
        guard isShellCommand, let arguments else { return nil }
        return JSONValue.parse(arguments)?["command"]?.stringValue
    }

    /// The output split from the notes the shell tool appends.
    public var trailer: ToolOutputTrailer {
        ToolOutputTrailer(output ?? "")
    }

    public var status: Status {
        switch rowStatus {
        case .preparing: return .preparing
        case .running: return .running
        case .waitingForConfirmation: return .waitingForGoAhead
        case .finished: break
        }
        let details = facts.details
        guard let output else { return .stopped }
        let trailer = ToolOutputTrailer(output)
        if details?.timedOut == true || trailer.timeLimitSeconds != nil { return .timedOut }
        if details?.stopped == true || trailer.stoppedWhileRunning { return .stopped }
        if details?.goAhead == .declined { return .declined }
        switch TranscriptRow.outcome(ofOutput: output) {
        case .declined: return .declined
        case .stopped: return .stopped
        case .succeeded: return .succeeded
        case .failed: return .failed
        case .unknown: break
        }
        if Self.declinedOutputs.contains(output) { return .declined }
        if Self.stoppedOutputs.contains(output) { return .stopped }
        if let status = details?.exitStatus { return status == 0 ? .succeeded : .failed }
        return output.hasPrefix("Error") ? .failed : .succeeded
    }

    /// Outputs the native tools give when the owner declines, beside the shell tool's own.
    static let declinedOutputs: Set<String> = [
        ShellCommandTool.declinedOutput,
        "The owner declined. Nothing was changed.",
    ]
    static let stoppedOutputs: Set<String> = [
        ShellCommandTool.stoppedBeforeRunningOutput,
        "The task was stopped before anything was changed.",
        "This command did not finish. The app quit or the task was stopped while it ran.",
    ]

    /// When the call started: when the tool began, or when the model wrote the call.
    public var started: Date? {
        facts.details?.started ?? facts.runningSince ?? facts.calledAt
    }

    /// How long the call took, or has taken so far while it runs.
    public func seconds(now: Date) -> Double? {
        if let seconds = facts.details?.seconds { return seconds }
        guard let started else { return nil }
        if let finished = facts.finishedAt { return max(0, finished.timeIntervalSince(started)) }
        return status.isFinished ? nil : max(0, now.timeIntervalSince(started))
    }

    /// The go-ahead, in words, or nil when the call did not ask or it is not known.
    public var goAheadText: String? {
        if rowStatus == .waitingForConfirmation { return "Asked, waiting for an answer" }
        switch facts.details?.goAhead {
        case .approved?:
            if let waited = facts.details?.waitedSeconds { return "Asked, approved after \(ToolCallText.duration(waited))" }
            return "Asked, approved"
        case .declined?: return "Asked, declined"
        case nil: return status == .declined ? "Asked, declined" : nil
        }
    }

    /// The exit status of a shell command, stored or read from the line the tool appends.
    public var exitStatus: Int32? {
        facts.details?.exitStatus ?? trailer.exitStatus
    }

    /// The source group: the stored one, or the one the app's tools give for the name now.
    public func source(lookup: (String) -> String?) -> String? {
        facts.details?.source ?? name.flatMap(lookup)
    }

    /// The labeled facts at the top of the inspector, in order. Facts that are not known for
    /// this call, such as a duration for one stored before durations were, are left out.
    public func metadata(now: Date, sourceLookup: (String) -> String? = { _ in nil }, timeText: (Date) -> String) -> [ToolCallMetadata] {
        var items: [ToolCallMetadata] = []
        let toolName = name ?? (summary.isEmpty ? "Unknown tool" : summary)
        if let source = source(lookup: sourceLookup) {
            items.append(.init("Tool", "\(toolName), \(source)"))
        } else {
            items.append(.init("Tool", toolName))
        }
        items.append(.init("Status", status.text))
        if let started { items.append(.init("Started", timeText(started))) }
        if let seconds = seconds(now: now) {
            items.append(.init(status.isFinished ? "Took" : "Running for", ToolCallText.duration(seconds)))
        }
        if let exitStatus { items.append(.init("Exit status", String(exitStatus))) }
        if let goAhead = goAheadText { items.append(.init("Go-ahead", goAhead)) }
        if let output {
            let body = trailer.body
            var size = ToolCallText.size(of: body)
            if let full = facts.details?.fullCharacters {
                size += ", shortened from \(ToolCallText.count(full, "character")) before the model saw it"
            } else if let omitted = trailer.omittedCharacters {
                size += ", shortened by \(ToolCallText.count(omitted, "character")) before the model saw it"
            }
            items.append(.init("Output", size))
            if output != body, let note = trailer.noteText { items.append(.init("Note", note)) }
        }
        items.append(.init("Call ID", callID))
        return items
    }
}

/// One labeled fact in the inspector's header.
public struct ToolCallMetadata: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// The shell tool's output split from the notes it adds at the end: the exit status line, the
/// time limit note, and the stopped note. A `(no output)` placeholder becomes an empty body.
/// Anything that does not match exactly stays in the body.
public struct ToolOutputTrailer: Equatable, Sendable {
    public var body: String
    public var exitStatus: Int32?
    public var timeLimitSeconds: Int?
    public var stoppedWhileRunning = false
    /// From the `[… N characters omitted …]` line the tool puts in the middle of long output.
    public var omittedCharacters: Int?

    public init(_ output: String) {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        var found = true
        while found, let last = lines.last {
            found = false
            let line = last.trimmingCharacters(in: .whitespaces)
            if exitStatus == nil, let status = Self.number(in: line, prefix: "[exit status ", suffix: "]") {
                exitStatus = Int32(clamping: status)
                found = true
            } else if timeLimitSeconds == nil, let seconds = Self.number(in: line, prefix: "[Stopped after the ", suffix: " second limit.]") {
                timeLimitSeconds = seconds
                found = true
            } else if !stoppedWhileRunning, line == ShellCommandTool.stoppedWhileRunningNote {
                stoppedWhileRunning = true
                found = true
            }
            if found { lines.removeLast() }
        }
        var body = lines.joined(separator: "\n")
        if exitStatus != nil, body == "(no output)" { body = "" }
        self.body = body
        if let match = body.firstMatch(of: /\n\[… (\d+) characters omitted …\]\n/) {
            omittedCharacters = Int(match.1)
        }
    }

    /// The notes in words, for the inspector's header.
    public var noteText: String? {
        var notes: [String] = []
        if let timeLimitSeconds { notes.append("Stopped at the \(timeLimitSeconds) second limit") }
        if stoppedWhileRunning { notes.append("The task was stopped while it ran") }
        return notes.isEmpty ? nil : notes.joined(separator: ". ")
    }

    private static func number(in line: String, prefix: String, suffix: String) -> Int? {
        guard line.hasPrefix(prefix), line.hasSuffix(suffix), line.count > prefix.count + suffix.count else { return nil }
        let digits = line.dropFirst(prefix.count).dropLast(suffix.count)
        let unsigned = digits.hasPrefix("-") ? digits.dropFirst() : digits
        guard !unsigned.isEmpty, unsigned.allSatisfy(\.isASCII), unsigned.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }
}

/// Small pieces of text the inspector shows.
public enum ToolCallText {
    /// `420 ms`, `3.2 s`, `2 min 5 s`, `1 h 4 min`.
    public static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded())) ms" }
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        if whole < 3600 { return whole % 60 == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(whole % 60) s" }
        return "\(whole / 3600) h \(whole % 3600 / 60) min"
    }

    /// `1 line, 12 characters`. Empty text is `empty`.
    public static func size(of text: String) -> String {
        if text.isEmpty { return "empty" }
        let lines = lineCount(text)
        return "\(count(lines, "line")), \(count(text.count, "character"))"
    }

    /// Lines as an editor numbers them: a final newline does not start another line.
    public static func lineCount(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        var lines = 1
        for byte in text.utf8 where byte == 0x0A { lines += 1 }
        if text.utf8.last == 0x0A { lines -= 1 }
        return lines
    }

    public static func count(_ value: Int, _ noun: String) -> String {
        let number = value.formatted(.number.locale(Locale(identifier: "en_US")))
        return value == 1 ? "1 \(noun)" : "\(number) \(noun)s"
    }
}
