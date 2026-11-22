import Foundation

/// How a command reads on its one-line row in the panel, and what a failed command's second
/// line says. Presentation only: nothing here runs a command or judges whether it is safe.
///
/// This follows the tool rows of the owner's Pi customizations (`lib/ui/tool-signal.ts` in
/// agent-customizations). Program names draw in the text color and everything else stays dim,
/// and anything the simple lexer cannot read with confidence falls back to dim text instead
/// of a guessed parse.
public enum ToolSignal {
    /// The two levels of a row's text.
    public enum Tone: Equatable, Sendable {
        /// The part a reader scans for, such as the program a command runs.
        case text
        /// Arguments, operators, and everything else.
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

    /// A path under the home folder shown with `~` in place of the home folder.
    public static func compactPath(_ path: String, home: String) -> String {
        var root = home
        while root.hasSuffix("/") { root.removeLast() }
        guard !root.isEmpty, path == root || path.hasPrefix(root + "/") else { return path }
        return "~" + path.dropFirst(root.count)
    }

    private static let wrappers: Set<String> = ["sudo", "env", "time", "exec", "nohup", "xargs"]
    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "function", "select", "!",
    ]
    private static let unsupported = CharacterSet(charactersIn: "\n\r$`\\#<>(){}")
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"\s+|&&|\|\||[|;]|(?:[^\s'"|;&]+|'[^']*'|"[^"]*")+|."#)

    /// A shell command as segments. Only simple literal pipelines and lists are styled: the
    /// program of each part draws as `.text`, and its arguments, assignments, wrappers such as
    /// `sudo`, and the operators between parts stay `.dim`. Expansions, redirections,
    /// comments, escapes, compound syntax, unfinished quotes, and options on a wrapper fall
    /// back to one dim segment. Whole literal paths under the home folder shorten to `~`.
    public static func command(_ command: String, home: String = NSHomeDirectory()) -> [Segment] {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = [Segment(.dim, cleanSummary(command))]
        if command.unicodeScalars.contains(where: unsupported.contains) { return fallback }
        let range = NSRange(command.startIndex..., in: command)
        let tokens = tokenPattern.matches(in: command, range: range).compactMap { Range($0.range, in: command).map { String(command[$0]) } }
        if tokens.contains(where: { $0 == "&" || $0 == "'" || $0 == "\"" || keywords.contains($0) }) { return fallback }

        var expectsProgram = true
        var segments: [Segment] = []
        for token in tokens {
            if token.allSatisfy(\.isWhitespace) {
                segments.append(Segment(.dim, " "))
                continue
            }
            if ["&&", "||", "|", ";"].contains(token) {
                expectsProgram = true
                segments.append(Segment(.dim, token))
                continue
            }
            let isAssignment = token.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
            let isWrapper = wrappers.contains(token)
            if expectsProgram && token.hasPrefix("-") { return fallback }
            let isProgram = expectsProgram && !isAssignment && !isWrapper
            if isProgram { expectsProgram = false }
            let tone: Tone = isProgram ? .text : .dim
            // Only a whole literal path word shortens, never a URL, an option, or part of a word.
            let quote = token.first == "\"" || token.first == "'" ? String(token.first!) : ""
            let literal = !quote.isEmpty && token.count >= 2 && token.hasSuffix(quote) ? String(token.dropFirst().dropLast()) : token
            if !literal.contains("'"), !literal.contains("\""), literal.hasPrefix("/") {
                segments.append(Segment(tone, quote + compactPath(cleanSummary(literal), home: home) + quote))
            } else {
                segments.append(Segment(tone, cleanSummary(token)))
            }
        }
        return merged(trimmed(segments))
    }

    /// Joins neighbors of the same tone, so the view builds as few text runs as it can.
    static func merged(_ segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        for segment in segments where !segment.text.isEmpty {
            if let last = result.last, last.tone == segment.tone {
                result[result.count - 1].text += segment.text
            } else {
                result.append(segment)
            }
        }
        return result
    }

    private static func trimmed(_ segments: [Segment]) -> [Segment] {
        var segments = segments
        while let first = segments.first, first.text.allSatisfy(\.isWhitespace) { segments.removeFirst() }
        while let last = segments.last, last.text.allSatisfy(\.isWhitespace) { segments.removeLast() }
        return segments
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
