import Foundation

/// How a tool call reads on its one-line row in the panel, and what a failed call's second
/// line says. Presentation only: nothing here runs a call or judges whether it is safe.
///
/// This follows the tool rows of the owner's Pi customizations (`lib/ui/tool-signal.ts` in
/// agent-customizations). Every row is its tool's summary, which starts with what the call
/// does or the tool's name, such as `Open Safari`, `Search history for "dark mode"`, or
/// `Bash du -sh ~/Movies`. That first word draws in the text color and the rest stays dim.
public enum ToolSignal {
    /// The two levels of a row's text.
    public enum Tone: Equatable, Sendable {
        /// The part a reader scans for: the word that names what the call does.
        case text
        /// What it does it to, such as a command line, an app, or a search.
        case dim
    }

    public struct Segment: Equatable, Sendable {
        public var tone: Tone
        public var text: String

        public init(_ tone: Tone, _ text: String) {
            self.tone = tone
            self.text = text
        }
    }

    /// Text on one line: control characters become spaces and runs of whitespace collapse.
    public static func cleanSummary(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            (scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)) ? " " : Character(scalar)
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A tool call's summary as segments, on one line: its first word, which names what the
    /// call does, as `.text`, and the rest as `.dim`. Whole literal paths under the home folder
    /// in the rest shorten to `~`.
    public static func summary(_ summary: String, home: String = NSHomeDirectory()) -> [Segment] {
        let line = cleanSummary(summary)
        guard !line.isEmpty else { return [] }
        guard let space = line.firstIndex(of: " ") else { return [Segment(.text, line)] }
        let rest = String(line[space...])
        return [Segment(.text, String(line[..<space])), Segment(.dim, compactPaths(in: rest, home: home))]
    }

    /// Every whole word, bare or quoted, that is a path under the home folder, with `~` in
    /// place of the home folder. A path inside a word, such as in a web address, is left alone.
    static func compactPaths(in text: String, home: String) -> String {
        var root = home
        while root.hasSuffix("/") { root.removeLast() }
        guard !root.isEmpty, text.contains(root) else { return text }
        let pattern = #"(?<=^|[\s"'=])"# + NSRegularExpression.escapedPattern(for: root) + #"(?=/|$|[\s"'])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        return expression.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
    }

    private static let diagnosticPattern = try! NSRegularExpression(
        pattern: #"\b(?:ENOENT|EACCES|EPERM|ECONNREFUSED|ETIMEDOUT)\b|(?:^|\s)(?:\w*Error:|error:|fatal:)|permission denied|not found|no such file|timed out|aborted|could not find|can.t|cannot|couldn.t"#,
        options: [.caseInsensitive])

    /// The one line that says why a command failed. An explicit error line wins over progress
    /// output and stack frames. Otherwise it is the last line of text that is not a stack frame.
    /// The app's own bracketed notes, such as the exit status line, are left out, and the exit
    /// status stands in when nothing else is left.
    public static func failureSummary(_ output: String?) -> String {
        let all = (output ?? "").components(separatedBy: .newlines)
            .map { cleanSummary($0) }
            .filter { !$0.isEmpty }
        let lines = all.filter { !($0.hasPrefix("[") && $0.hasSuffix("]")) && $0 != "(no output)" }
        let explicit = lines.first { line in
            diagnosticPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        if let line = explicit ?? lines.last(where: { !$0.hasPrefix("at ") }) { return line }
        if let status = all.last(where: { $0.hasPrefix("[exit status ") }) {
            return String(status.dropFirst().dropLast())
        }
        return "failed with no output"
    }
}

/// What a tool call row shows, from its status and its output.
public enum ToolCallState: Equatable, Sendable {
    /// The model is still writing the call.
    case preparing
    case running
    case waitingForConfirmation
    case succeeded
    /// It ran and failed, with the line that says why.
    case failed(String)
    /// The owner said not to run it.
    case declined
    /// The task was stopped before or while it ran.
    case stopped

    public init(status: TranscriptRow.ToolStatus, output: String?) {
        switch status {
        case .preparing: self = .preparing
        case .running: self = .running
        case .waitingForConfirmation: self = .waitingForConfirmation
        case .finished:
            switch TranscriptRow.outcome(ofOutput: output) {
            case .succeeded, .unknown: self = .succeeded
            case .failed: self = .failed(ToolSignal.failureSummary(output))
            case .declined: self = .declined
            case .stopped: self = .stopped
            }
        }
    }

    /// The words on the branch line under the row, or nil for a row that is one line.
    public var branchText: String? {
        switch self {
        case .preparing, .succeeded: nil
        case .running: "running"
        case .waitingForConfirmation: "waiting for your go-ahead"
        case .failed(let reason): reason
        case .declined: "not run, you declined"
        case .stopped: "stopped"
        }
    }

    /// The words on the branch line, worded by the go-ahead the call is waiting on when it is
    /// this row's. The shell tool's reads "waiting for your go-ahead", and a reminder change
    /// reads "waiting for your go-ahead to delete a reminder".
    public func branchText(pendingGoAhead: ConfirmationRequest?, callID: String) -> String? {
        if self == .waitingForConfirmation, let pendingGoAhead, pendingGoAhead.callID == callID {
            return pendingGoAhead.waitingText
        }
        return branchText
    }

    /// How VoiceOver names the state, worded by the go-ahead the call waits on like the branch line.
    public func accessibilityText(pendingGoAhead: ConfirmationRequest?, callID: String) -> String {
        if self == .waitingForConfirmation, let pendingGoAhead, pendingGoAhead.callID == callID {
            let text = pendingGoAhead.waitingText
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        return accessibilityText
    }

    /// How VoiceOver names the state.
    public var accessibilityText: String {
        switch self {
        case .preparing: "Preparing"
        case .running: "Running"
        case .waitingForConfirmation: "Waiting for your go-ahead"
        case .succeeded: "Finished"
        case .failed(let reason): "Failed: \(reason)"
        case .declined: "Not run, you declined"
        case .stopped: "Stopped"
        }
    }
}
